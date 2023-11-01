//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOCore
import NIOEmbedded
import NIOHPACK
@testable import NIOHTTP2


class SimpleClientServerInlineStreamMultiplexerTests: XCTestCase {
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

    static let defaultMultiplexerCallback: (@Sendable (Channel) -> EventLoopFuture<Void>) = { channel in
        channel.pipeline.eventLoop.makeSucceededVoidFuture()
    }

    /// Establish a basic HTTP/2 connection.
    func basicHTTP2Connection(clientSettings: HTTP2Settings = nioDefaultSettings,
                              serverSettings: HTTP2Settings = nioDefaultSettings,
                              maximumBufferedControlFrames: Int = 10000,
                              withMultiplexerCallback multiplexerCallback: @escaping (@Sendable (Channel) -> EventLoopFuture<Void>) = defaultMultiplexerCallback) throws {

        var clientConnectionConfiguration = NIOHTTP2Handler.ConnectionConfiguration()
        clientConnectionConfiguration.initialSettings = clientSettings
        clientConnectionConfiguration.maximumBufferedControlFrames = maximumBufferedControlFrames
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .client,
                                                                                    eventLoop: self.clientChannel.eventLoop,
                                                                                    connectionConfiguration: clientConnectionConfiguration,
                                                                                    inboundStreamInitializer: multiplexerCallback)).wait())
        var serverConnectionConfiguration = NIOHTTP2Handler.ConnectionConfiguration()
        serverConnectionConfiguration.initialSettings = serverSettings
        serverConnectionConfiguration.maximumBufferedControlFrames = maximumBufferedControlFrames
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .server,
                                                                                    eventLoop: self.serverChannel.eventLoop,
                                                                                    connectionConfiguration: serverConnectionConfiguration,
                                                                                    inboundStreamInitializer: multiplexerCallback)).wait())

        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel,
                                   clientSettings: clientSettings, serverSettings: serverSettings)
    }

    func testSendingDataFrameWithLargeFile() throws {
        // Begin by getting the connection up.
        // We add the stream multiplexer because it'll emit WINDOW_UPDATE frames, which we need.
        let serverHandler = InboundFramePayloadRecorder()
        try self.basicHTTP2Connection() { channel in
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

            let clientHandler = InboundFramePayloadRecorder()
            let childChannelPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
            let multiplexer = try (self.clientChannel.pipeline.context(handlerType: NIOHTTP2Handler.self).wait().handler as! NIOHTTP2Handler).multiplexer.wait()
            multiplexer.createStreamChannel(promise: childChannelPromise) { channel in
                return channel.pipeline.addHandler(clientHandler)
            }
            (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()
            let childChannel = try childChannelPromise.futureResult.wait()

            // Start by sending the headers.
            let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers))
            childChannel.writeAndFlush(reqFrame) .whenComplete {
                print("Headers: \($0)")
            }
            self.interactInMemory(self.clientChannel, self.serverChannel)

            serverHandler.receivedFrames.assertFramePayloadsMatch([reqFrame])
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()

            // Ok, we're gonna send the body here.
            let reqBodyFrame = HTTP2Frame.FramePayload.data(.init(data: .fileRegion(region), endStream: true))
            childChannel.writeAndFlush(reqBodyFrame) .whenComplete {
                print("Data: \($0)")
            }
            self.interactInMemory(self.clientChannel, self.serverChannel)

            // We now expect 3 frames.
            let dataFrames = (0..<3).map { idx in HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: idx == 2)) }
            serverHandler.receivedFrames.assertFramePayloadsMatch([reqFrame] + dataFrames)

            // The client will have seen a pair of window updates: one on the connection, one on the stream.
            try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
            clientHandler.receivedFrames.assertFramePayloadsMatch([HTTP2Frame.FramePayload.windowUpdate(windowSizeIncrement: 32768)])

            // No frames left.
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testAutomaticFlowControl() throws {
        // Begin by getting the connection up.
        // We add the stream multiplexer here because it manages automatic flow control.
        try self.basicHTTP2Connection() { channel in
            return channel.eventLoop.makeSucceededFuture(())
        }

        // Now we're going to send a request, including a very large body: 65536 bytes in size. To avoid spending too much
        // time initializing buffers, we're going to send the same 1kB data frame 64 times.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let requestBody = ByteBuffer(repeating: 0x04, count: 1024)

        // We're going to open a stream and queue up the frames for that stream.
        let handler = try self.clientChannel.pipeline.context(handlerType: NIOHTTP2Handler.self).wait().handler as! NIOHTTP2Handler
        let childHandler = InboundFramePayloadRecorder()
        let multiplexer = try handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            let reqFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers))
            channel.write(reqFramePayload, promise: nil)

            // Now prepare the large body.
            var reqBodyFramePayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(requestBody)))
            for _ in 0..<63 {
                channel.write(reqBodyFramePayload, promise: nil)
            }
            reqBodyFramePayload = .data(.init(data: .byteBuffer(requestBody), endStream: true))
            channel.writeAndFlush(reqBodyFramePayload, promise: nil)

            return channel.pipeline.addHandler(childHandler)
        }
        (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()

        // Ok, we now want to send this data to the server.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // We should also see 4 window update frames on the client side: two for the stream, two for the connection.
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)

        let expectedChildFrames = [HTTP2Frame.FramePayload.windowUpdate(windowSizeIncrement: 32768)]
        childHandler.receivedFrames.assertFramePayloadsMatch(expectedChildFrames)

        // No other frames should be emitted, though the server may have many.
        self.clientChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testNoStreamWindowUpdateOnEndStreamFrameFromServer() throws {
        let maxFrameSize = (1 << 24) - 1  // Max value of SETTINGS_MAX_FRAME_SIZE is 2^24-1.
        let clientSettings = nioDefaultSettings + [HTTP2Setting(parameter: .maxFrameSize, value: maxFrameSize)]

        // Begin by getting the connection up.
        // We add the stream multiplexer here because it manages automatic flow control, and because we want the server
        // to correctly confirm we don't receive a frame for the child stream.
        let childHandler = InboundFramePayloadRecorder()
        try self.basicHTTP2Connection(clientSettings: clientSettings) { channel in

            // Here we send a large response: 65535 bytes in size.
            let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "65535")])

            var responseBody = channel.allocator.buffer(capacity: 65535)
            responseBody.writeBytes(Array(repeating: UInt8(0x04), count: 65535))

            let respFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: responseHeaders))
            channel.write(respFramePayload, promise: nil)

            // Now prepare the large body.
            let respBodyFramePayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(responseBody), endStream: true))
            channel.writeAndFlush(respBodyFramePayload, promise: nil)
            return channel.pipeline.addHandler(childHandler)
        }

        // Now we're going to send a small request.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])

        // We're going to open a stream and queue up the frames for that stream.
        let handler = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).wait()
        // We need END_STREAM set here, because that will force the stream to be closed on the response.
        let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))
        let multiplexer = try handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            channel.writeAndFlush(reqFrame, promise: nil)
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()

        // Ok, we now want to send this data to the server.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The server should have seen 1 window update frame for the connection only.
        try self.serverChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 65535)

        // And only the request frame frame for the child stream, as there was no need to open its stream window.
        childHandler.receivedFrames.assertFramePayloadsMatch([reqFrame])

        // No other frames should be emitted, though the client may have many in a child stream.
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(XCTAssertTrue(try self.clientChannel.finish().isClean))
        XCTAssertNoThrow(XCTAssertTrue(try self.serverChannel.finish().isClean))
    }

    func testNoStreamWindowUpdateOnEndStreamFrameFromClient() throws {
        let maxFrameSize = (1 << 24) - 1  // Max value of SETTINGS_MAX_FRAME_SIZE is 2^24-1.
        let serverSettings = nioDefaultSettings + [HTTP2Setting(parameter: .maxFrameSize, value: maxFrameSize)]

        // Begin by getting the connection up.
        // We add the stream multiplexer here because it manages automatic flow control, and because we want the server
        // to correctly confirm we don't receive a frame for the child stream.
        let childHandler = FrameRecorderHandler()
        try self.basicHTTP2Connection(serverSettings: serverSettings) { channel in
            return channel.eventLoop.makeSucceededFuture(())
        }

        // Now we're going to send a large request: 65535 bytes in size
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])

        // We're going to open a stream and queue up the frames for that stream.
        let handler = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).wait()
        let multiplexer = try handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers))
            channel.write(reqFrame, promise: nil)

            var requestBody = channel.allocator.buffer(capacity: 65535)
            requestBody.writeBytes(Array(repeating: UInt8(0x04), count: 65535))

            // Now prepare the large body. We need END_STREAM set.
            let reqBodyFrame = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(requestBody), endStream: true))
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

    func testStreamCreationOrder() throws {
        try self.basicHTTP2Connection()
        let handler = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).wait()
        let multiplexer = try handler.multiplexer.wait()

        let streamAPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamAPromise) { channel in
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamA = try assertNoThrowWithValue(try streamAPromise.futureResult.wait())

        let streamBPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamBPromise) { channel in
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamB = try assertNoThrowWithValue(try streamBPromise.futureResult.wait())

        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        let headersFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))

        // Write on 'B' first.
        XCTAssertNoThrow(try streamB.writeAndFlush(headersFramePayload).wait())
        XCTAssertEqual(try streamB.getOption(HTTP2StreamChannelOptions.streamID).wait(), HTTP2StreamID(1))

        // Now write on stream 'A'. This would fail on frame-based stream channel.
        XCTAssertNoThrow(try streamA.writeAndFlush(headersFramePayload).wait())
        XCTAssertEqual(try streamA.getOption(HTTP2StreamChannelOptions.streamID).wait(), HTTP2StreamID(3))
    }

    func testWriteWithAlreadyCompletedPromise() throws {
        try self.basicHTTP2Connection()
        let handler = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).wait()
        let multiplexer = try handler.multiplexer.wait()

        let streamPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamPromise) { channel in
            return channel.eventLoop.makeSucceededFuture(())
        }

        self.clientChannel.embeddedEventLoop.run()
        let stream = try assertNoThrowWithValue(try streamPromise.futureResult.wait())

        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let headerPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers))
        let promise = self.clientChannel.eventLoop.makePromise(of: Void.self)
        promise.succeed(())
        stream.writeAndFlush(headerPayload, promise: promise)
    }
}
