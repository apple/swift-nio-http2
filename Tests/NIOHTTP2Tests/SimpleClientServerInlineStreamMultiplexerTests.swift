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

import NIOCore
import NIOEmbedded
import NIOHPACK
import XCTest

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
    func basicHTTP2Connection(
        clientSettings: HTTP2Settings = nioDefaultSettings,
        serverSettings: HTTP2Settings = nioDefaultSettings,
        clientHeaderBlockValidation: NIOHTTP2Handler.ValidationState = .enabled,
        maximumBufferedControlFrames: Int = 10000,
        withMultiplexerCallback multiplexerCallback: @escaping (@Sendable (Channel) -> EventLoopFuture<Void>) =
            defaultMultiplexerCallback
    ) throws {
        var clientConnectionConfiguration = NIOHTTP2Handler.ConnectionConfiguration()
        clientConnectionConfiguration.initialSettings = clientSettings
        clientConnectionConfiguration.maximumBufferedControlFrames = maximumBufferedControlFrames
        clientConnectionConfiguration.headerBlockValidation = clientHeaderBlockValidation
        XCTAssertNoThrow(
            try self.clientChannel.pipeline.syncOperations.addHandler(
                NIOHTTP2Handler(
                    mode: .client,
                    eventLoop: self.clientChannel.eventLoop,
                    connectionConfiguration: clientConnectionConfiguration,
                    inboundStreamInitializer: multiplexerCallback
                )
            )
        )
        var serverConnectionConfiguration = NIOHTTP2Handler.ConnectionConfiguration()
        serverConnectionConfiguration.initialSettings = serverSettings
        serverConnectionConfiguration.maximumBufferedControlFrames = maximumBufferedControlFrames
        XCTAssertNoThrow(
            try self.serverChannel.pipeline.syncOperations.addHandler(
                NIOHTTP2Handler(
                    mode: .server,
                    eventLoop: self.serverChannel.eventLoop,
                    connectionConfiguration: serverConnectionConfiguration,
                    inboundStreamInitializer: multiplexerCallback
                )
            )
        )

        try self.assertDoHandshake(
            client: self.clientChannel,
            server: self.serverChannel,
            clientSettings: clientSettings,
            serverSettings: serverSettings
        )
    }

    func testSendingDataFrameWithLargeFile() throws {
        // Begin by getting the connection up.
        // We add the stream multiplexer because it'll emit WINDOW_UPDATE frames, which we need.
        let serverHandler = InboundFramePayloadRecorder()
        try self.basicHTTP2Connection { channel in
            channel.pipeline.addHandler(serverHandler)
        }

        // We're going to create a largish temp file: 3 data frames in size.
        var bodyData = self.clientChannel.allocator.buffer(capacity: 1 << 14)
        for val in (0..<((1 << 14) / MemoryLayout<Int>.size)) {
            bodyData.writeInteger(val)
        }

        try withTemporaryFile { (handle, path) in
            for _ in (0..<3) {
                handle.appendBuffer(bodyData)
            }

            let region = try FileRegion(fileHandle: handle)

            let clientHandler = InboundFramePayloadRecorder()
            let childChannelPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
            let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap {
                $0.multiplexer
            }.wait()
            multiplexer.createStreamChannel(promise: childChannelPromise) { channel in
                channel.pipeline.addHandler(clientHandler)
            }
            (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()
            let childChannel = try childChannelPromise.futureResult.wait()

            // Start by sending the headers.
            let headers = HPACKHeaders([
                (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
            ])
            let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers))
            childChannel.writeAndFlush(reqFrame).whenComplete {
                print("Headers: \($0)")
            }
            self.interactInMemory(self.clientChannel, self.serverChannel)

            serverHandler.receivedFrames.assertFramePayloadsMatch([reqFrame])
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()

            // Ok, we're gonna send the body here.
            let reqBodyFrame = HTTP2Frame.FramePayload.data(.init(data: .fileRegion(region), endStream: true))
            childChannel.writeAndFlush(reqBodyFrame).whenComplete {
                print("Data: \($0)")
            }
            self.interactInMemory(self.clientChannel, self.serverChannel)

            // We now expect 3 frames.
            let dataFrames = (0..<3).map { idx in
                HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: idx == 2))
            }
            serverHandler.receivedFrames.assertFramePayloadsMatch([reqFrame] + dataFrames)

            // The client will have seen a pair of window updates: one on the connection, one on the stream.
            try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
            clientHandler.receivedFrames.assertFramePayloadsMatch([
                HTTP2Frame.FramePayload.windowUpdate(windowSizeIncrement: 32768)
            ])

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
        try self.basicHTTP2Connection { channel in
            channel.eventLoop.makeSucceededFuture(())
        }

        // Now we're going to send a request, including a very large body: 65536 bytes in size. To avoid spending too much
        // time initializing buffers, we're going to send the same 1kB data frame 64 times.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])
        let requestBody = ByteBuffer(repeating: 0x04, count: 1024)

        // We're going to open a stream and queue up the frames for that stream.
        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap {
            $0.multiplexer
        }.wait()
        let childHandler = InboundFramePayloadRecorder()
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
            let respBodyFramePayload = HTTP2Frame.FramePayload.data(
                .init(data: .byteBuffer(responseBody), endStream: true)
            )
            channel.writeAndFlush(respBodyFramePayload, promise: nil)
            return channel.pipeline.addHandler(childHandler)
        }

        // Now we're going to send a small request.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])

        // We're going to open a stream and queue up the frames for that stream.
        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap {
            $0.multiplexer
        }.wait()

        // We need END_STREAM set here, because that will force the stream to be closed on the response.
        let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))
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
            channel.eventLoop.makeSucceededFuture(())
        }

        // Now we're going to send a large request: 65535 bytes in size
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])

        // We're going to open a stream and queue up the frames for that stream.
        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap {
            $0.multiplexer
        }.wait()
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
        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap {
            $0.multiplexer
        }.wait()

        let streamAPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamAPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamA = try assertNoThrowWithValue(try streamAPromise.futureResult.wait())

        let streamBPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamBPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamB = try assertNoThrowWithValue(try streamBPromise.futureResult.wait())

        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
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
        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap {
            $0.multiplexer
        }.wait()

        let streamPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }

        self.clientChannel.embeddedEventLoop.run()
        let stream = try assertNoThrowWithValue(try streamPromise.futureResult.wait())

        let headers = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])
        let headerPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers))
        let promise = self.clientChannel.eventLoop.makePromise(of: Void.self)
        promise.succeed(())
        stream.writeAndFlush(headerPayload, promise: promise)
    }

    func testOpenStreamBeforeReceivingAlreadySentGoAway() throws {
        let serverHandler = InboundFramePayloadRecorder()
        try self.basicHTTP2Connection { channel in
            channel.pipeline.addHandler(serverHandler)
        }

        let errorEncounteredHandler = ErrorEncounteredHandler()
        let loopBoundErrorHandler = NIOLoopBound(
            errorEncounteredHandler,
            eventLoop: self.clientChannel.embeddedEventLoop
        )
        let clientHandler = InboundFramePayloadRecorder()

        let childChannelPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap {
            $0.multiplexer
        }.wait()

        multiplexer.createStreamChannel(promise: childChannelPromise) { channel in
            channel.eventLoop.makeCompletedFuture {
                let errorHandler = loopBoundErrorHandler.value
                try channel.pipeline.syncOperations.addHandler(errorHandler)
                try channel.pipeline.syncOperations.addHandler(clientHandler)
            }
        }
        self.clientChannel.embeddedEventLoop.run()
        let childChannel = try childChannelPromise.futureResult.wait()

        // Server sends GOAWAY frame.
        let goAwayFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)
        )
        serverChannel.writeAndFlush(goAwayFrame, promise: nil)

        // Client sends headers.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])
        let reqFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers))
        childChannel.writeAndFlush(reqFramePayload, promise: nil)

        self.interactInMemory(self.clientChannel, self.serverChannel, expectError: true) { error in
            if let error = error as? NIOHTTP2Errors.StreamError {
                XCTAssert(error.baseError is NIOHTTP2Errors.CreatedStreamAfterGoaway)
            } else {
                XCTFail("Expected error to be of type StreamError, got error of type \(type(of: error)).")
            }
        }

        // Client receives GOAWAY and RST_STREAM frames.
        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(
            lastStreamID: .maxID,
            errorCode: 0,
            opaqueData: nil
        )
        clientHandler.receivedFrames.assertFramePayloadsMatch([HTTP2Frame.FramePayload.rstStream(.refusedStream)])

        // No frames left.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // The stream closes successfully and an error is fired down the pipeline.
        self.clientChannel.embeddedEventLoop.run()
        XCTAssertNoThrow(try childChannel.closeFuture.wait())
        XCTAssertTrue(errorEncounteredHandler.encounteredError is NIOHTTP2Errors.StreamClosed)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testOpenStreamBeforeReceivingGoAwayWhenServerLocallyQuiesced() throws {
        let serverFrameRecorder = InboundFramePayloadRecorder()
        try self.basicHTTP2Connection { channel in
            channel.pipeline.addHandler(serverFrameRecorder)
        }

        let http2Handler = self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self)
        let multiplexer = try http2Handler.flatMap { $0.multiplexer }.wait()

        let clientFrameRecorder = InboundFramePayloadRecorder()
        let streamOneFuture = multiplexer.createStreamChannel { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(clientFrameRecorder)
            }
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamOne = try streamOneFuture.wait()

        let headers: HPACKHeaders = [
            ":path": "/",
            ":method": "GET",
            ":scheme": "http",
            ":authority": "localhost",
        ]
        try streamOne.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: headers))).wait()
        self.interactInMemory(self.clientChannel, self.serverChannel)
        serverFrameRecorder.receivedFrames.assertFramePayloadsMatch([.headers(.init(headers: headers))])

        // Create stream two, but don't write on it (yet).
        let streamTwoFuture = multiplexer.createStreamChannel { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(clientFrameRecorder)
            }
        }
        self.clientChannel.embeddedEventLoop.run()
        let streamTwo = try streamTwoFuture.wait()

        // Send the GOAWAY from the server.
        let goAway = HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)
        )
        try self.serverChannel.writeAndFlush(goAway).wait()
        // Send HEADERS on the second client stream.
        try streamTwo.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: headers))).wait()

        // Interacting in memory to exchange frames.
        self.interactInMemory(self.clientChannel, self.serverChannel, expectError: true) { error in
            if let error = error as? NIOHTTP2Errors.StreamError {
                XCTAssert(error.baseError is NIOHTTP2Errors.CreatedStreamAfterGoaway)
            } else {
                XCTFail("Expected error to be of type StreamError, got error of type \(type(of: error)).")
            }
        }

        // Client receives GOAWAY and RST_STREAM frames.
        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(
            lastStreamID: .maxID,
            errorCode: 0,
            opaqueData: nil
        )
        clientFrameRecorder.receivedFrames.assertFramePayloadsMatch([.rstStream(.refusedStream)])
    }

    func testSuccessfullyReceiveAndSendPingEvenWhenConnectionIsFullyQuiesced() throws {
        let serverHandler = InboundFramePayloadRecorder()
        try self.basicHTTP2Connection { channel in
            channel.pipeline.addHandler(serverHandler)
        }
        // Fully quiesce the connection on the server.
        let goAwayFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: .rootStream, errorCode: .noError, opaqueData: nil)
        )
        serverChannel.writeAndFlush(goAwayFrame, promise: nil)

        // Send PING frame to the server.
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(), ack: false))
        clientChannel.writeAndFlush(pingFrame, promise: nil)

        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The client receives the GOAWAY frame and fully quiesces the connection.
        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(
            lastStreamID: .rootStream,
            errorCode: 0,
            opaqueData: nil
        )

        // The server receives and responds to the PING.
        try self.serverChannel.assertReceivedFrame().assertPingFrame(ack: false, opaqueData: HTTP2PingData())

        // The client receives the PING response.
        try self.clientChannel.assertReceivedFrame().assertPingFrame(ack: true, opaqueData: HTTP2PingData())

        // No frames left.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testChannelShouldQuiesceIsPropagated() throws {
        // Setup the connection.
        let receivedShouldQuiesceEvent = self.clientChannel.eventLoop.makePromise(of: Void.self)
        try self.basicHTTP2Connection { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandler(
                    ShouldQuiesceEventWaiter(promise: receivedShouldQuiesceEvent)
                )
            }
        }

        let connectionReceivedShouldQuiesceEvent = self.clientChannel.eventLoop.makePromise(of: Void.self)
        try self.serverChannel.pipeline.syncOperations.addHandler(
            ShouldQuiesceEventWaiter(promise: connectionReceivedShouldQuiesceEvent)
        )

        // Create the stream channel.
        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap { $0.multiplexer }
            .wait()
        let streamPromise = self.clientChannel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamPromise) {
            $0.eventLoop.makeSucceededVoidFuture()
        }
        self.clientChannel.embeddedEventLoop.run()
        let stream = try streamPromise.futureResult.wait()

        // Initiate request to open the stream on the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "http")])
        let frame: HTTP2Frame.FramePayload = .headers(.init(headers: headers))
        stream.writeAndFlush(frame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // Fire the event on the server pipeline, this should propagate to the stream channel and
        // the connection channel.
        self.serverChannel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertNoThrow(try receivedShouldQuiesceEvent.futureResult.wait())
        XCTAssertNoThrow(try connectionReceivedShouldQuiesceEvent.futureResult.wait())

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testChannelInactiveFinishesAsyncStreamMultiplexerInboundStream() async throws {
        let asyncClientChannel = NIOAsyncTestingChannel()
        let asyncServerChannel = NIOAsyncTestingChannel()

        // Setup the connection.
        let clientMultiplexer = try await asyncClientChannel.configureAsyncHTTP2Pipeline(mode: .client) { _ in
            asyncClientChannel.eventLoop.makeSucceededVoidFuture()
        }.get()

        let serverMultiplexer = try await asyncServerChannel.configureAsyncHTTP2Pipeline(mode: .server) { _ in
            asyncServerChannel.eventLoop.makeSucceededVoidFuture()
        }.get()

        // Create the stream channel
        let stream = try await clientMultiplexer.openStream { $0.eventLoop.makeSucceededFuture($0) }

        // Initiate request to open the stream on the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "http")])
        let frame: HTTP2Frame.FramePayload = .headers(.init(headers: headers))
        stream.writeAndFlush(frame, promise: nil)
        try await self.interactInMemory(asyncClientChannel, asyncServerChannel)

        // Close server to fire channel inactive down the pipeline: it should be propagated.
        try await asyncServerChannel.close()
        for try await _ in serverMultiplexer.inbound {}
    }

    enum ErrorCaughtPropagated: Error, Equatable {
        case error
    }

    func testErrorCaughtFinishesAsyncStreamMultiplexerInboundStream() async throws {
        let asyncClientChannel = NIOAsyncTestingChannel()
        let asyncServerChannel = NIOAsyncTestingChannel()

        // Setup the connection.
        let clientMultiplexer = try await asyncClientChannel.configureAsyncHTTP2Pipeline(mode: .client) { _ in
            asyncClientChannel.eventLoop.makeSucceededVoidFuture()
        }.get()

        let serverMultiplexer = try await asyncServerChannel.configureAsyncHTTP2Pipeline(mode: .server) { _ in
            asyncServerChannel.eventLoop.makeSucceededVoidFuture()
        }.get()

        // Create the stream channel
        let stream = try await clientMultiplexer.openStream { $0.eventLoop.makeSucceededFuture($0) }

        // Initiate request to open the stream on the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "http")])
        let frame: HTTP2Frame.FramePayload = .headers(.init(headers: headers))
        stream.writeAndFlush(frame, promise: nil)
        try await self.interactInMemory(asyncClientChannel, asyncServerChannel)

        // Fire an error down the server pipeline: it should cause the inbound stream to finish with error
        asyncServerChannel.pipeline.fireErrorCaught(ErrorCaughtPropagated.error)
        do {
            for try await _ in serverMultiplexer.inbound {}
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssert(error is ErrorCaughtPropagated)
        }
    }

    func testStreamErrorRateLimiting() throws {
        // Client will purposefully send invalid headers ("te: chunked") to cause a stream error on
        // the server. Disable client side validation so that the client doesn't fail to send the
        // headers.
        try self.basicHTTP2Connection(clientHeaderBlockValidation: .disabled)

        final class CloseOnExcessiveStreamErrors: ChannelInboundHandler, Sendable {
            typealias InboundIn = Any
            func errorCaught(context: ChannelHandlerContext, error: any Error) {
                if error is NIOHTTP2Errors.ExcessiveStreamErrors {
                    context.close(mode: .all, promise: nil)
                } else if error is NIOHTTP2Errors.ForbiddenHeaderField {
                    // Ignore. Expected in this test; the server will still reset the stream.
                    ()
                } else {
                    context.fireErrorCaught(error)
                }
            }
        }
        try self.serverChannel.pipeline.addHandler(CloseOnExcessiveStreamErrors()).wait()

        let clientFrameRecorder = InboundFrameRecorder()
        try self.clientChannel.pipeline.addHandler(clientFrameRecorder).wait()

        let multiplexer = try self.clientChannel.pipeline.handler(type: NIOHTTP2Handler.self).flatMap { $0.multiplexer }
            .wait()

        // Default number of stream errors allowed within the time window (30s by default).
        let permittedStreamErrors = 200
        for streamNumber in 1...(permittedStreamErrors + 1) {
            let recorder = InboundFramePayloadRecorder()
            let streamFuture = multiplexer.createStreamChannel { channel in
                channel.pipeline.addHandler(recorder)
            }

            self.clientChannel.embeddedEventLoop.run()
            let stream = try assertNoThrowWithValue(try streamFuture.wait())
            let headers: HPACKHeaders = [
                ":path": "/",
                ":method": "POST",
                ":scheme": "https",
                ":authority": "localhost",
                "te": "chunked",  // not allowed and will result in a stream error on the server.
            ]

            let headerPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers))
            stream.writeAndFlush(headerPayload, promise: nil)
            self.interactInMemory(self.clientChannel, self.serverChannel)

            if streamNumber <= permittedStreamErrors {
                // The first N streams are reset.
                XCTAssert(clientFrameRecorder.receivedFrames.isEmpty)
                XCTAssertEqual(recorder.receivedFrames.count, 1)
                recorder.receivedFrames.first?.assertRstStreamFramePayload(errorCode: .protocolError)
            } else {
                // The N+1th stream hits the DoS rate limit and results in a GOAWAY and the
                // connection being closed.
                XCTAssertFalse(clientFrameRecorder.receivedFrames.isEmpty)
                XCTAssertEqual(recorder.receivedFrames.count, 0)
                recorder.receivedFrames.first?.assertGoAwayFramePayloadMatches(
                    this: .goAway(
                        lastStreamID: .maxID,
                        errorCode: .enhanceYourCalm,
                        opaqueData: nil
                    )
                )
            }
        }
    }
}
