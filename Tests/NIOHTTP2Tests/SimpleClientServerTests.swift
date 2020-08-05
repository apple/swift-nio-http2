//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO
import NIOHPACK
@testable import NIOHTTP2

typealias FrameRecorderHandler = InboundFrameRecorder

class SimpleClientServerTests: XCTestCase {
    var clientChannel: EmbeddedChannel!
    var serverChannel: EmbeddedChannel!

    override func setUp() {
        self.clientChannel = EmbeddedChannel()
        self.serverChannel = EmbeddedChannel()
    }

    override func tearDown() {
        self.clientChannel = nil
        self.serverChannel = nil
    }

    /// Establish a basic HTTP/2 connection.
    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func basicHTTP2Connection(clientSettings: HTTP2Settings = nioDefaultSettings,
                              serverSettings: HTTP2Settings = nioDefaultSettings,
                              withMultiplexerCallback multiplexerCallback: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)? = nil) throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .client, initialSettings: clientSettings)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .server, initialSettings: serverSettings)).wait())

        if let multiplexerCallback = multiplexerCallback {
            XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(HTTP2StreamMultiplexer(mode: .client,
                                                                                               channel: self.clientChannel,
                                                                                               inboundStreamStateInitializer: multiplexerCallback)).wait())
            XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(HTTP2StreamMultiplexer(mode: .server,
                                                                                               channel: self.serverChannel,
                                                                                               inboundStreamStateInitializer: multiplexerCallback)).wait())
        }

        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel,
                                   clientSettings: clientSettings, serverSettings: serverSettings)
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testSendingDataFrameWithLargeFile() throws {
        // Begin by getting the connection up.
        // We add the stream multiplexer because it'll emit WINDOW_UPDATE frames, which we need.
        let serverHandler = FrameRecorderHandler()
        try self.basicHTTP2Connection() { channel, streamID in
            return channel.pipeline.addHandler(serverHandler)
        }

        // We're going to create a largish temp file: 3 data frames in size.
        var bodyData = self.clientChannel.allocator.buffer(capacity: 1<<14)
        for val in (0..<((1<<14) / MemoryLayout<Int>.size)) {
            bodyData.writeInteger(val)
        }

        try withTemporaryFile { (handle, path) in
            for _ in (0..<3) {
                handle.appendBuffer(bodyData)
            }

            let region = try FileRegion(fileHandle: handle)

            let clientHandler = FrameRecorderHandler()
            let childChannelPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
            try (self.clientChannel.pipeline.context(handlerType: HTTP2StreamMultiplexer.self).wait().handler as! HTTP2StreamMultiplexer).createStreamChannel(promise: childChannelPromise) { channel, streamID in
                return channel.pipeline.addHandler(clientHandler)
            }
            (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()
            let childChannel = try childChannelPromise.futureResult.wait()

            // Start by sending the headers.
            let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let clientStreamID = HTTP2StreamID(1)
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
            childChannel.writeAndFlush(reqFrame, promise: nil)
            self.interactInMemory(self.clientChannel, self.serverChannel)

            serverHandler.receivedFrames.assertFramesMatch([reqFrame])
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()

            // Ok, we're gonna send the body here.
            let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .fileRegion(region), endStream: true)))
            childChannel.writeAndFlush(reqBodyFrame, promise: nil)
            self.interactInMemory(self.clientChannel, self.serverChannel)

            // We now expect 3 frames.
            let dataFrames = (0..<3).map { idx in HTTP2Frame(streamID: clientStreamID,  payload: .data(.init(data: .byteBuffer(bodyData), endStream: idx == 2))) }
            serverHandler.receivedFrames.assertFramesMatch([reqFrame] + dataFrames)

            // The client will have seen a pair of window updates: one on the connection, one on the stream.
            try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
            clientHandler.receivedFrames.assertFramesMatch([HTTP2Frame(streamID: clientStreamID, payload: .windowUpdate(windowSizeIncrement: 32768))])

            // No frames left.
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testAutomaticFlowControl() throws {
        // Begin by getting the connection up.
        // We add the stream multiplexer here because it manages automatic flow control.
        try self.basicHTTP2Connection() { channel, streamID in
            return channel.eventLoop.makeSucceededFuture(())
        }

        // Now we're going to send a request, including a very large body: 65536 bytes in size. To avoid spending too much
        // time initializing buffers, we're going to send the same 1kB data frame 64 times.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 1024)
        requestBody.writeBytes(Array(repeating: UInt8(0x04), count: 1024))

        // We're going to open a stream and queue up the frames for that stream.
        let handler = try self.clientChannel.pipeline.context(handlerType: HTTP2StreamMultiplexer.self).wait().handler as! HTTP2StreamMultiplexer
        let childHandler = FrameRecorderHandler()
        handler.createStreamChannel(promise: nil) { channel, streamID in
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: headers)))
            channel.write(reqFrame, promise: nil)

            // Now prepare the large body.
            var reqBodyFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(requestBody))))
            for _ in 0..<63 {
                channel.write(reqBodyFrame, promise: nil)
            }
            reqBodyFrame.payload = .data(.init(data: .byteBuffer(requestBody), endStream: true))
            channel.writeAndFlush(reqBodyFrame, promise: nil)

            return channel.pipeline.addHandler(childHandler)
        }
        (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()

        // Ok, we now want to send this data to the server.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // We should also see 4 window update frames on the client side: two for the stream, two for the connection.
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)

        let expectedChildFrames = [HTTP2Frame(streamID: 1, payload: .windowUpdate(windowSizeIncrement: 32768))]
        childHandler.receivedFrames.assertFramesMatch(expectedChildFrames)

        // No other frames should be emitted, though the server may have many.
        self.clientChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testStreamMultiplexerAcknowledgesSettingsBasedFlowControlChanges() throws {
        // This test verifies that the stream multiplexer pays attention to notifications about settings changes to flow
        // control windows. It can't do that by *raising* the flow control window, as that information is duplicated in the
        // stream flow control change notifications sent by receiving data frames. So it must do it by *shrinking* the window.

        // Begin by getting the connection up and add a stream multiplexer.
        try self.basicHTTP2Connection()
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(HTTP2StreamMultiplexer(mode: .server, channel: self.serverChannel)).wait())

        var largeBuffer = self.clientChannel.allocator.buffer(capacity: 32767)
        largeBuffer.writeBytes(repeatElement(UInt8(0xFF), count: 32767))

        // Let's open a stream, and write a DATA frame that consumes slightly less than half the window.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")])
        let headersFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers)))
        let bodyFrame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(largeBuffer))))

        self.clientChannel.write(headersFrame, promise: nil)
        self.clientChannel.writeAndFlush(bodyFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // No window update frame should be emitted.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now have the server shrink the client's flow control window.
        // When it does this, the stream multiplexer will be told, and the stream will set its new expected maintained window size accordingly.
        // However, the new *actual* window size will now be small enough to emit a window update for. Note that the connection will not have a window
        // update frame sent as well maintain its size.
        try self.assertSettingsUpdateWithAck([(HTTP2Setting(parameter: .initialWindowSize, value: 32768))], sender: self.serverChannel, receiver: self.clientChannel)
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 1, windowIncrement: 32767)
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Shrink it further. We shouldn't emit another window update.
        try self.assertSettingsUpdateWithAck([(HTTP2Setting(parameter: .initialWindowSize, value: 16384))], sender: self.serverChannel, receiver: self.clientChannel)
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // And resize up. No window update either.
        try self.assertSettingsUpdateWithAck([(HTTP2Setting(parameter: .initialWindowSize, value: 65535))], sender: self.serverChannel, receiver: self.clientChannel)
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testNoStreamWindowUpdateOnEndStreamFrameFromServer() throws {
        let maxFrameSize = (1 << 24) - 1  // Max value of SETTINGS_MAX_FRAME_SIZE is 2^24-1.
        let clientSettings = nioDefaultSettings + [HTTP2Setting(parameter: .maxFrameSize, value: maxFrameSize)]

        // Begin by getting the connection up.
        // We add the stream multiplexer here because it manages automatic flow control, and because we want the server
        // to correctly confirm we don't receive a frame for the child stream.
        let childHandler = FrameRecorderHandler()
        try self.basicHTTP2Connection(clientSettings: clientSettings) { channel, streamID in
            // Here we send a large response: 65535 bytes in size.
            let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "65535")])

            var responseBody = self.clientChannel.allocator.buffer(capacity: 65535)
            responseBody.writeBytes(Array(repeating: UInt8(0x04), count: 65535))

            let respFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: responseHeaders)))
            channel.write(respFrame, promise: nil)

            // Now prepare the large body.
            let respBodyFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(responseBody), endStream: true)))
            channel.writeAndFlush(respBodyFrame, promise: nil)

            return channel.pipeline.addHandler(childHandler)
        }

        // Now we're going to send a small request.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])

        // We're going to open a stream and queue up the frames for that stream.
        let handler = try self.clientChannel.pipeline.handler(type: HTTP2StreamMultiplexer.self).wait()
        var reqFrame: HTTP2Frame? = nil

        handler.createStreamChannel(promise: nil) { channel, streamID in
            // We need END_STREAM set here, because that will force the stream to be closed on the response.
            reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: headers, endStream: true)))
            channel.writeAndFlush(reqFrame, promise: nil)
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()

        // Ok, we now want to send this data to the server.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The server should have seen 1 window update frame for the connection only.
        try self.serverChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 65535)

        // And only the request frame frame for the child stream, as there was no need to open its stream window.
        childHandler.receivedFrames.assertFramesMatch([reqFrame!])

        // No other frames should be emitted, though the client may have many in a child stream.
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(XCTAssertTrue(try self.clientChannel.finish().isClean))
        XCTAssertNoThrow(XCTAssertTrue(try self.serverChannel.finish().isClean))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testNoStreamWindowUpdateOnEndStreamFrameFromClient() throws {
        let maxFrameSize = (1 << 24) - 1  // Max value of SETTINGS_MAX_FRAME_SIZE is 2^24-1.
        let serverSettings = nioDefaultSettings + [HTTP2Setting(parameter: .maxFrameSize, value: maxFrameSize)]

        // Begin by getting the connection up.
        // We add the stream multiplexer here because it manages automatic flow control, and because we want the server
        // to correctly confirm we don't receive a frame for the child stream.
        let childHandler = FrameRecorderHandler()
        try self.basicHTTP2Connection(serverSettings: serverSettings) { channel, streamID in
            return channel.eventLoop.makeSucceededFuture(())
        }

        // Now we're going to send a large request: 65535 bytes in size
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])

        // We're going to open a stream and queue up the frames for that stream.
        let handler = try self.clientChannel.pipeline.handler(type: HTTP2StreamMultiplexer.self).wait()

        handler.createStreamChannel(promise: nil) { channel, streamID in
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: headers)))
            channel.write(reqFrame, promise: nil)

            var requestBody = self.clientChannel.allocator.buffer(capacity: 65535)
            requestBody.writeBytes(Array(repeating: UInt8(0x04), count: 65535))

            // Now prepare the large body. We need END_STREAM set.
            let reqBodyFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))
            channel.writeAndFlush(reqBodyFrame, promise: nil)

            return channel.pipeline.addHandler(childHandler)
        }
        self.clientChannel.embeddedEventLoop.run()

        // Ok, we now want to send this data to the server.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The client should have seen a window update on the connection.
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 65535)

        // And nothing for the child stream, as there was no need to open its stream window.
        childHandler.receivedFrames.assertFramesMatch([])

        // No other frames should be emitted, though the server may have many in a child stream.
        self.clientChannel.assertNoFramesReceived()
        XCTAssertNoThrow(XCTAssertTrue(try self.clientChannel.finish().isClean))
        XCTAssertNoThrow(XCTAssertTrue(try self.serverChannel.finish().isClean))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testStreamCreationOrder() throws {
        try self.basicHTTP2Connection()
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.clientChannel)
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(multiplexer).wait())

        let streamAPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamAPromise) { channel, _ in
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamA = try assertNoThrowWithValue(try streamAPromise.futureResult.wait())

        let streamBPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamBPromise) { channel, _ in
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamB = try assertNoThrowWithValue(try streamBPromise.futureResult.wait())

        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        let headersFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))

        // Write on 'B' first.
        let streamBHeadersWritten = streamB.getOption(HTTP2StreamChannelOptions.streamID).flatMap { streamID -> EventLoopFuture<Void> in
            let frame = HTTP2Frame(streamID: streamID, payload: headersFramePayload)
            return streamB.writeAndFlush(frame)
        }
        XCTAssertNoThrow(try streamBHeadersWritten.wait())

        // Now write on stream 'A', it will fail. (This failure motivated the frame-payload based stream channel.)
        let streamAHeadersWritten = streamA.getOption(HTTP2StreamChannelOptions.streamID).flatMap { streamID -> EventLoopFuture<Void> in
            let frame = HTTP2Frame(streamID: streamID, payload: headersFramePayload)
            return streamA.writeAndFlush(frame)
        }
        XCTAssertThrowsError(try streamAHeadersWritten.wait()) { error in
            XCTAssert(error is NIOHTTP2Errors.StreamIDTooSmall)
        }
    }
}
