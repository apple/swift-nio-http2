//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
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
                              withMultiplexerCallback multiplexerCallback: NIOChannelInitializerWithStreamID? = nil) throws {
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
        var _requestBody = self.clientChannel.allocator.buffer(capacity: 1024)
        _requestBody.writeBytes(Array(repeating: UInt8(0x04), count: 1024))
        let requestBody = _requestBody

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

            var responseBody = channel.allocator.buffer(capacity: 65535)
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
        let reqFrame = NIOLockedValueBox<HTTP2Frame?>(nil)

        handler.createStreamChannel(promise: nil) { channel, streamID in
            // We need END_STREAM set here, because that will force the stream to be closed on the response.
            reqFrame.withLockedValue { reqFrame in
                reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: headers, endStream: true)))
                channel.writeAndFlush(reqFrame, promise: nil)
            }
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()

        // Ok, we now want to send this data to the server.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The server should have seen 1 window update frame for the connection only.
        try self.serverChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 65535)

        // And only the request frame frame for the child stream, as there was no need to open its stream window.
        reqFrame.withLockedValue { reqFrame in
            childHandler.receivedFrames.assertFramesMatch([reqFrame!])
        }

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

            var requestBody = channel.allocator.buffer(capacity: 65535)
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

    func testHandlingChannelInactiveDuringActive() throws {
        let channel = EmbeddedChannel()
        let orderingHandler = ActiveInactiveOrderingHandler()
        try channel.pipeline.syncOperations.addHandlers(
            [
                ActionOnFlushHandler { $0.close(promise: nil) },
                NIOHTTP2Handler(mode: .client),
                orderingHandler,
            ]
        )

        try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/ignored"), promise: nil)
        XCTAssertEqual(orderingHandler.events, [.active, .inactive])
    }

    func testWritingFromChannelActiveIsntReordered() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers(
            [
                NIOHTTP2Handler(mode: .client),
                WriteOnChannelActiveHandler(),
            ]
        )

        try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/ignored"), promise: nil)

        var writes = [ByteBuffer]()
        while let nextWrite = try channel.readOutbound(as: ByteBuffer.self) {
            writes.append(nextWrite)
        }

        XCTAssertEqual(writes.count, 3)
        // This is a PING frame.
        XCTAssertEqual(
            writes.last,
            ByteBuffer(bytes: [
                0x00, 0x00, 0x08,  // length, 8 bytes
                0x06,  // frame type, ping
                0x00,  // flags, zeros
                0x00, 0x00, 0x00, 0x00,  // stream ID, 0
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 // 8 byte payload, all zeros
            ])
        )
    }

    func testChannelActiveAfterAddingToActivePipelineDoesntError() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/ignored"), promise: nil)

        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))

        try channel.pipeline.syncOperations.addHandler(
            NIOHTTP2Handler(mode: .client)
        )

        // Two non-nil writes issued when the handler is added to an active channel.
        XCTAssertNotNil(try channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNotNil(try channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))

        // Delayed channel active.
        channel.pipeline.fireChannelActive()

        // No further writes.
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
    }

    func testChannelInactiveThenChannelActiveErrorsButDoesntTrap() throws {
        let channel = EmbeddedChannel()
        let recorder = ErrorRecorder()
        try channel.pipeline.syncOperations.addHandlers(
            [
                NIOHTTP2Handler(mode: .client),
                recorder
            ]
        )

        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 0)
        }

        // Send channelInactive followed by channelActive. This can happen if a user calls close
        // from within a connect promise.
        channel.pipeline.fireChannelInactive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 0)
        }

        channel.pipeline.fireChannelActive()

        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 1)
        }
        recorder.errors.withLockedValue { errors in
            XCTAssertTrue(errors.allSatisfy { $0 is NIOHTTP2Errors.ActivationError })
        }
    }

    func testImpossibleStateTransitionsThrowErrors() throws {
        func setUpChannel() throws -> (EmbeddedChannel, ErrorRecorder) {
            let channel = EmbeddedChannel()
            let recorder = ErrorRecorder()
            try channel.pipeline.syncOperations.addHandlers(
                [
                    NIOHTTP2Handler(mode: .client, tolerateImpossibleStateTransitionsInDebugMode: true),
                    recorder
                ]
            )

            recorder.errors.withLockedValue { errors in
                XCTAssertEqual(errors.count, 0)
            }
            return (channel, recorder)
        }

        // First impossible state transition: channelActive on channelActive.
        var (channel, recorder) = try setUpChannel()
        try channel.pipeline.syncOperations.addHandler(ActionOnFlushHandler { $0.pipeline.fireChannelActive() }, position: .first)
        channel.pipeline.fireChannelActive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 1)
        }
        recorder.errors.withLockedValue { errors in
            XCTAssertTrue(errors.allSatisfy { $0 is NIOHTTP2Errors.ActivationError })
        }

        // Second impossible state transition. Synchronous active/inactive/active. The error causes a close,
        // so we error twice!
        (channel, recorder) = try setUpChannel()
        try channel.pipeline.syncOperations.addHandler(
            ActionOnFlushHandler {
                $0.pipeline.fireChannelInactive()
                $0.pipeline.fireChannelActive()
            },
            position: .first
        )
        channel.pipeline.fireChannelActive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 2)
        }
        recorder.errors.withLockedValue { errors in
            XCTAssertTrue(errors.allSatisfy { $0 is NIOHTTP2Errors.ActivationError })
        }

        // Third impossible state transition: active/inactive/active asynchronously. This error doesn't cause a
        // close because we don't distinguish it from the case tested in
        // testChannelInactiveThenChannelActiveErrorsButDoesntTrap.
        (channel, recorder) = try setUpChannel()
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireChannelInactive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 0)
        }
        channel.pipeline.fireChannelActive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 1)
        }
        recorder.errors.withLockedValue { errors in
            XCTAssertTrue(errors.allSatisfy { $0 is NIOHTTP2Errors.ActivationError })
        }

        // Fourth impossible state transition: active/inactive/inactive synchronously. The error causes a close,
        // so we error twice!
        (channel, recorder) = try setUpChannel()
        try channel.pipeline.syncOperations.addHandler(
            ActionOnFlushHandler {
                $0.pipeline.fireChannelInactive()
                $0.pipeline.fireChannelInactive()
            },
            position: .first
        )
        channel.pipeline.fireChannelActive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 2)
        }
        recorder.errors.withLockedValue { errors in
            XCTAssertTrue(errors.allSatisfy { $0 is NIOHTTP2Errors.ActivationError })
        }

        // Fifth impossible state transition: active/inactive/inactive asynchronously. The error causes a close,
        // so we error twice!
        (channel, recorder) = try setUpChannel()
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireChannelInactive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 0)
        }
        channel.pipeline.fireChannelInactive()
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 2)
        }
        recorder.errors.withLockedValue { errors in
            XCTAssertTrue(errors.allSatisfy { $0 is NIOHTTP2Errors.ActivationError })
        }

        // Sixth impossible state transition: adding the handler twice. The error causes a close, so we
        // error twice!
        (channel, recorder) = try setUpChannel()
        try channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/ignored"), promise: nil)
        let handler = try channel.pipeline.syncOperations.handler(type: NIOHTTP2Handler.self)
        try channel.pipeline.syncOperations.addHandler(handler, position: .after(handler))
        recorder.errors.withLockedValue { errors in
            XCTAssertEqual(errors.count, 2)
        }
        recorder.errors.withLockedValue { errors in
            XCTAssertTrue(errors.allSatisfy { $0 is NIOHTTP2Errors.ActivationError })
        }
    }

    func testDynamicHeaderFieldsArentEmittedWithZeroTableSize() throws {
        let handler = NIOHTTP2Handler(mode: .client)
        let channel = EmbeddedChannel(handler: handler)

        channel.pipeline.connect(to: try .init(unixDomainSocketPath: "/no/such/path"), promise: nil)

        // We'll receive the preamble from the peer, which advertises no header table size.
        let newSettings: HTTP2Settings = [.init(parameter: .headerTableSize, value: 0)]
        let settings = HTTP2Frame(streamID: 0, payload: .settings(.settings(newSettings)))

        // Let's send our preamble as well.
        var frameEncoder = HTTP2FrameEncoder(allocator: channel.allocator)
        var buffer = channel.allocator.buffer(capacity: 1024)
        XCTAssertNil(try frameEncoder.encode(frame: settings, to: &buffer))
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 0, payload: .settings(.ack)), to: &buffer))
        try channel.writeInbound(buffer)

        // Now we're going to write a header. This includes a new header eligible for dynamic table insertion.
        // It must not be inserted!
        let headers = HPACKHeaders([
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":method", "GET"),
            ("a-header-field", "is set"),
        ])
        let framePayload = HTTP2Frame.FramePayload.Headers(headers: headers, endStream: true)
        try channel.writeOutbound(HTTP2Frame(streamID: 1, payload: .headers(framePayload)))

        // Take the reads. We expect 4.
        var reads = try channel.readAllBuffers()
        XCTAssertEqual(reads.count, 4)

        // We only care about the last one, which we expect is headers.
        // We expect the following frame bytes. The use of incremental indexing here is fine,
        // as the value shouldn't actually be added to the dynamic table.
        var expectedBytes = ByteBuffer(bytes: [
            0x00, 0x00, 0x1f,       // Frame length: 31 bytes
            0x01,                   // Frame type: 1, HEADERS
            0x05,                   // Frame flags: END_HEADERS | END_STREAM
            0x00, 0x00, 0x00, 0x01, // Stream ID: 1
            0x20,                   // Max dynamic table size change, 0
            0x84,                   // Indexed field, index number 4, static table
            0x87,                   // Indexed field, index number 7, static table
            0x41,                   // Literal field with incremental indexing, index 1,
                0x88,             // Huffman-coded value with length 8,
                0x2f, 0x91, 0xd3,
                0x5d, 0x05, 0x5c,
                0x87, 0xa7,
            0x82,                   // Indexed field, index number 2, static table
            0x40,                   // Literal field with incremental indexing, new name,
                0x8a,             // Huffman-coded name with length 10
                0x1a, 0xd3, 0x94,
                0x72, 0x16, 0xc5,
                0xa5, 0x31, 0x68,
                0x93,
                0x84,             // Huffman-coded value with length 4
                0x32, 0x14, 0x41,
                0x53
        ])

        XCTAssertEqual(expectedBytes, reads.last)

        // Now we'll send a second query. This must not use a dynamic representation.
        try channel.writeOutbound(HTTP2Frame(streamID: 3, payload: .headers(framePayload)))

        // Take another read.
        reads = try channel.readAllBuffers()
        XCTAssertEqual(reads.count, 1)

        // This should be similar to the first, but without the dynamic table size change and a new stream ID.
        expectedBytes = ByteBuffer(bytes: [
            0x00, 0x00, 0x1e,       // Frame length: 30 bytes
            0x01,                   // Frame type: 1, HEADERS
            0x05,                   // Frame flags: END_HEADERS | END_STREAM
            0x00, 0x00, 0x00, 0x03, // Stream ID: 3
            0x84,                   // Indexed field, index number 4, static table
            0x87,                   // Indexed field, index number 7, static table
            0x41,                   // Literal field with incremental indexing, index 1,
                  0x88,             // Huffman-coded value with length 8,
                  0x2f, 0x91, 0xd3,
                  0x5d, 0x05, 0x5c,
                  0x87, 0xa7,
            0x82,                   // Indexed field, index number 2, static table
            0x40,                   // Literal field with incremental indexing, new name,
                  0x8a,             // Huffman-coded name with length 10
                  0x1a, 0xd3, 0x94,
                  0x72, 0x16, 0xc5,
                  0xa5, 0x31, 0x68,
                  0x93,
                  0x84,             // Huffman-coded value with length 4
                  0x32, 0x14, 0x41,
                  0x53
        ])
        XCTAssertEqual(expectedBytes, reads.first)
    }

    func testDynamicHeaderFieldsArentToleratedWithZeroTableSize() throws {
        // Set ourselves up to advertise zero header table size.
        let handler = NIOHTTP2Handler(mode: .server, initialSettings: [.init(parameter: .headerTableSize, value: 0)])
        let channel = EmbeddedChannel(handler: handler)

        channel.pipeline.connect(to: try .init(unixDomainSocketPath: "/no/such/path"), promise: nil)

        // We'll receive the preamble from the peer, which is normal.
        let newSettings: HTTP2Settings = []
        let settings = HTTP2Frame(streamID: 0, payload: .settings(.settings(newSettings)))

        var frameEncoder = HTTP2FrameEncoder(allocator: channel.allocator)
        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        XCTAssertNil(try frameEncoder.encode(frame: settings, to: &buffer))
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 0, payload: .settings(.ack)), to: &buffer))
        try channel.writeInbound(buffer)

        // Now we're going to receive a header. This includes a new header eligible for dynamic table insertion.
        // It isn't inherently rejected, this is ok. However, the _second_ frame will use the dynamic table,
        // and that must be rejected.
        let headers = HPACKHeaders([
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":method", "GET"),
            ("a-header-field", "is set"),
        ])
        let framePayload = HTTP2Frame.FramePayload.Headers(headers: headers, endStream: true)

        // Send the frame twice. This should error.
        buffer.clear()
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 1, payload: .headers(framePayload)), to: &buffer))
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 3, payload: .headers(framePayload)), to: &buffer))
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.UnableToParseFrame)
        }
    }

    func testSettingTableSizeToZeroAfterStartEvictsHeaders() throws {
        let handler = NIOHTTP2Handler(mode: .client)
        let channel = EmbeddedChannel(handler: handler)

        channel.pipeline.connect(to: try .init(unixDomainSocketPath: "/no/such/path"), promise: nil)

        // We'll receive the preamble from the peer, which advertises default settings
        var settings = HTTP2Frame(streamID: 0, payload: .settings(.settings([])))

        // Let's send our preamble as well.
        var frameEncoder = HTTP2FrameEncoder(allocator: channel.allocator)
        var buffer = channel.allocator.buffer(capacity: 1024)
        XCTAssertNil(try frameEncoder.encode(frame: settings, to: &buffer))
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 0, payload: .settings(.ack)), to: &buffer))
        try channel.writeInbound(buffer)

        // Now we're going to write a header. This includes a new header eligible for dynamic table insertion.
        // It actually will be inserted!
        let headers = HPACKHeaders([
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":method", "GET"),
            ("a-header-field", "is set"),
        ])
        let framePayload = HTTP2Frame.FramePayload.Headers(headers: headers, endStream: true)
        try channel.writeOutbound(HTTP2Frame(streamID: 1, payload: .headers(framePayload)))

        // Take the reads. We expect 4.
        var reads = try channel.readAllBuffers()
        XCTAssertEqual(reads.count, 4)

        // We only care about the last one, which we expect is headers.
        // We expect the following frame bytes. The use of incremental indexing here is expected,
        // as the value will be added to the dynamic table.
        var expectedBytes = ByteBuffer(bytes: [
            0x00, 0x00, 0x1e,       // Frame length: 30 bytes
            0x01,                   // Frame type: 1, HEADERS
            0x05,                   // Frame flags: END_HEADERS | END_STREAM
            0x00, 0x00, 0x00, 0x01, // Stream ID: 1
            0x84,                   // Indexed field, index number 4, static table
            0x87,                   // Indexed field, index number 7, static table
            0x41,                   // Literal field with incremental indexing, index 1,
                  0x88,             // Huffman-coded value with length 8,
                  0x2f, 0x91, 0xd3,
                  0x5d, 0x05, 0x5c,
                  0x87, 0xa7,
            0x82,                   // Indexed field, index number 2, static table
            0x40,                   // Literal field with incremental indexing, new name,
                  0x8a,             // Huffman-coded name with length 10
                  0x1a, 0xd3, 0x94,
                  0x72, 0x16, 0xc5,
                  0xa5, 0x31, 0x68,
                  0x93,
                  0x84,             // Huffman-coded value with length 4
                  0x32, 0x14, 0x41,
                  0x53
        ])

        XCTAssertEqual(expectedBytes, reads.last)

        // Now we'll have the peer send a new SETTINGS frame that sets the dynamic table size to zero.
        let newSettings: HTTP2Settings = [.init(parameter: .headerTableSize, value: 0)]
        settings = HTTP2Frame(streamID: 0, payload: .settings(.settings(newSettings)))
        buffer.clear()
        XCTAssertNil(try frameEncoder.encode(frame: settings, to: &buffer))
        try channel.writeInbound(buffer)

        // Now we'll send a second query. This must not use a dynamic representation.
        try channel.writeOutbound(HTTP2Frame(streamID: 3, payload: .headers(framePayload)))

        // Take another read. This time there are two writes, and the first is a SETTINGS ACK.
        reads = try channel.readAllBuffers()
        XCTAssertEqual(reads.count, 2)

        // This should be similar to the first, but without a dynamic table size change and a new stream ID.
        expectedBytes = ByteBuffer(bytes: [
            0x00, 0x00, 0x1f,       // Frame length: 31 bytes
            0x01,                   // Frame type: 1, HEADERS
            0x05,                   // Frame flags: END_HEADERS | END_STREAM
            0x00, 0x00, 0x00, 0x03, // Stream ID: 3
            0x20,                   // Max dynamic table size change, 0
            0x84,                   // Indexed field, index number 4, static table
            0x87,                   // Indexed field, index number 7, static table
            0x41,                   // Literal field with incremental indexing, index 1,
                  0x88,             // Huffman-coded value with length 8,
                  0x2f, 0x91, 0xd3,
                  0x5d, 0x05, 0x5c,
                  0x87, 0xa7,
            0x82,                   // Indexed field, index number 2, static table
            0x40,                   // Literal field with incremental indexing, new name,
                  0x8a,             // Huffman-coded name with length 10
                  0x1a, 0xd3, 0x94,
                  0x72, 0x16, 0xc5,
                  0xa5, 0x31, 0x68,
                  0x93,
                  0x84,             // Huffman-coded value with length 4
                  0x32, 0x14, 0x41,
                  0x53
        ])
        XCTAssertEqual(expectedBytes, reads.last)
    }

    func testSettingTableSizeToZeroEvictsHeadersAndRefusesToDecodeThem() throws {
        // Set ourselves up with default settings
        let handler = NIOHTTP2Handler(mode: .server)
        let channel = EmbeddedChannel(handler: handler)

        channel.pipeline.connect(to: try .init(unixDomainSocketPath: "/no/such/path"), promise: nil)

        // We'll receive the preamble from the peer, which is normal.
        let newSettings: HTTP2Settings = []
        let settings = HTTP2Frame(streamID: 0, payload: .settings(.settings(newSettings)))

        var frameEncoder = HTTP2FrameEncoder(allocator: channel.allocator)
        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        XCTAssertNil(try frameEncoder.encode(frame: settings, to: &buffer))
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 0, payload: .settings(.ack)), to: &buffer))
        try channel.writeInbound(buffer)

        // Now we're going to send a header. This includes a new header eligible for dynamic table insertion.
        // It isn't inherently rejected, this is ok. However, the _second_ frame will use the dynamic table,
        // and that must be rejected.
        let headers = HPACKHeaders([
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (":method", "GET"),
            ("a-header-field", "is set"),
        ])
        let framePayload = HTTP2Frame.FramePayload.Headers(headers: headers, endStream: true)

        // Send the first frame.
        buffer.clear()
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 1, payload: .headers(framePayload)), to: &buffer))
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        // Now, we send a settings frame that updates our settings.
        try channel.writeOutbound(
            HTTP2Frame(streamID: 0, payload: .settings(.settings([.init(parameter: .headerTableSize, value: 0)])))
        )

        // We receive a settings ACK and then another frame. This frame hasn't respected our settings change! It should
        // be rejected.
        buffer.clear()
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 0, payload: .settings(.ack)), to: &buffer))
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 3, payload: .headers(framePayload)), to: &buffer))
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.UnableToParseFrame)
        }
    }
}

final class ActionOnFlushHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private let action: (ChannelHandlerContext) -> Void

    init(_ action: @escaping (ChannelHandlerContext) -> Void) {
        self.action = action
    }

    func flush(context: ChannelHandlerContext) {
        self.action(context)
    }
}

final class ActiveInactiveOrderingHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    enum Event {
        case active
        case inactive
    }

    var events: [Event] = []

    func channelActive(context: ChannelHandlerContext) {
        self.events.append(.active)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.events.append(.inactive)
        context.fireChannelInactive()
    }
}

final class WriteOnChannelActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias OutboundOut = HTTP2Frame

    func channelActive(context: ChannelHandlerContext) {
        let frame = HTTP2Frame(streamID: 0, payload: .ping(HTTP2PingData(), ack: false))
        context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
        context.fireChannelActive()
    }
}

extension EmbeddedChannel {
    func readAllBuffers() throws -> [ByteBuffer] {
        var buffers = [ByteBuffer]()

        while let next = try self.readOutbound(as: ByteBuffer.self) {
            buffers.append(next)
        }

        return buffers
    }
}

extension HTTP2FrameDecoder {
    mutating func readAllFrames() throws -> [HTTP2Frame] {
        var frames = [HTTP2Frame]()

        while let next = try self.nextFrame() {
            frames.append(next.0)
        }

        return frames
    }
}
