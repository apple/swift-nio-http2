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
import NIOHTTP1
import NIOHTTP2

/// A channel handler that passes writes through but fires EOF once the first one hits.
final class EOFOnWriteHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    enum InactiveType {
        case halfClose
        case fullClose
        case doNothing
    }

    private var type: InactiveType

    init(type: InactiveType) {
        assert(type != .doNothing)
        self.type = type
    }

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.type {
        case .halfClose:
            ctx.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        case .fullClose:
            ctx.fireChannelInactive()
        case .doNothing:
            break
        }

        self.type = .doNothing
    }
}

/// A channel handler that verifies that we never send flushes
/// for no reason.
final class NoEmptyFlushesHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var writeCount = 0

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.writeCount += 1
        ctx.write(data, promise: promise)
    }

    func flush(ctx: ChannelHandlerContext) {
        XCTAssertGreaterThan(self.writeCount, 0)
        self.writeCount = 0
    }
}

/// A channel handler that forcibly resets all inbound frames it receives.
final class InstaResetHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        if case .headers = frame.payload {
            let kaboomFrame = HTTP2Frame(streamID: frame.streamID, payload: .rstStream(.refusedStream))
            ctx.writeAndFlush(self.wrapOutboundOut(kaboomFrame), promise: nil)
        }
    }
}

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
    func basicHTTP2Connection() throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.add(handler: HTTP2Parser(mode: .client)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server)).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)
    }

    func testBasicRequestResponse() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Let's send a quick response back.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
        respFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testManyRequestsAtOnce() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let requestHeaders = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        // We're going to send three requests before we flush.
        var clientStreamIDs = [HTTP2StreamID]()
        var headersFrames = [HTTP2Frame]()
        var dataFrames = [HTTP2Frame]()

        for _ in 0..<3 {
            let streamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(requestHeaders))
            var reqBodyFrame = HTTP2Frame(streamID: streamID, payload: .data(.byteBuffer(requestBody)))
            reqBodyFrame.endStream = true

            self.clientChannel.write(reqFrame, promise: nil)
            self.clientChannel.write(reqBodyFrame, promise: nil)

            clientStreamIDs.append(streamID)
            headersFrames.append(reqFrame)
            dataFrames.append(reqBodyFrame)
        }
        self.clientChannel.flush()
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // We expect to see all 3 headers frames emitted first, and then the data frames. This is an artefact of nghttp2,
        // but it's how it'll go.
        let frames = [headersFrames, dataFrames].flatMap { $0 }
        for frame in frames {
            let receivedFrame = try self.serverChannel.assertReceivedFrame()
            receivedFrame.assertFrameMatches(this: frame)
        }

        // There should be no frames here.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testNothingButGoaway() throws {
        // A simple connection with a goaway should be no big deal.
        try self.basicHTTP2Connection()
        let goAwayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .noError, opaqueData: nil))
        self.clientChannel.writeAndFlush(goAwayFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The server should have received a GOAWAY. Nothing else should have happened.
        let receivedGoawayFrame = try self.serverChannel.assertReceivedFrame()
        receivedGoawayFrame.assertFrameMatches(this: goAwayFrame)

        // Send the GOAWAY back to the client. Should be safe.
        self.serverChannel.writeAndFlush(goAwayFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The client should not receive this GOAWAY frame, as it has shut down.
        self.clientChannel.assertNoFramesReceived()

        // All should be good.
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testGoAwayWithStreamsUpQuiescing() throws {
        // A simple connection with a goaway should be no big deal.
        try self.basicHTTP2Connection()

        // We're going to send a HEADERS frame from the client to the server.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Now the server is going to send a GOAWAY frame with the maximum stream ID. This should quiesce the connection:
        // futher frames on stream 1 are allowed, but nothing else.
        let serverGoaway = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil))
        try self.assertFramesRoundTrip(frames: [serverGoaway], sender: self.serverChannel, receiver: self.clientChannel)

        // We should still be able to send DATA frames on stream 1 now.
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // The server will respond, closing this stream.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
        respFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // The server can now GOAWAY down to stream 1. We evaluate the bytes here ourselves becuase the client won't see this frame.
        let secondServerGoaway = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: serverStreamID, errorCode: .noError, opaqueData: nil))
        self.serverChannel.writeAndFlush(secondServerGoaway, promise: nil)
        guard case .some(.byteBuffer(let bytes)) = self.serverChannel.readOutbound() else {
            XCTFail("No data sent from server")
            return
        }
        // A GOAWAY frame (type 7, 8 bytes long, no flags, on stream 0), with error code 0 and last stream ID 1.
        let expectedFrameBytes: [UInt8] = [0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        XCTAssertEqual(bytes.getBytes(at: bytes.readerIndex, length: bytes.readableBytes)!, expectedFrameBytes)

        // At this stage, everything is shut down.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testLargeDataFramesAreSplit() throws {
        // Big DATA frames get split up.
        try self.basicHTTP2Connection()

        // Start by opening the stream.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Confirm there's no bonus frame sitting around.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now we're going to send in a frame that's just a bit larger than the max frame size of 1<<14.
        let frameSize = (1<<14) + 8
        var buffer = self.clientChannel.allocator.buffer(capacity: frameSize)

        /// To write this in as fast as possible, we're going to fill the buffer one int at a time.
        for val in (0..<(frameSize / MemoryLayout<Int>.size)) {
            buffer.write(integer: val)
        }

        // Now we'll try to send this in a DATA frame.
        var dataFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(buffer)))
        dataFrame.endStream = true
        self.clientChannel.writeAndFlush(dataFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // This should have produced two frames in the server. Both are DATA, one is max frame size and the other
        // is not.
        let firstFrame = try self.serverChannel.assertReceivedFrame()
        firstFrame.assertDataFrame(endStream: false, streamID: serverStreamID.networkStreamID!, payload: buffer.getSlice(at: 0, length: 1<<14)!)
        let secondFrame = try self.serverChannel.assertReceivedFrame()
        secondFrame.assertDataFrame(endStream: true, streamID: serverStreamID.networkStreamID!, payload: buffer.getSlice(at: 1<<14, length: 8)!)

        // The client should have got nothing.
        self.clientChannel.assertNoFramesReceived()

        // Now send a response from the server and shut things down.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
        respFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testSendingDataFrameWithSmallFile() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server with a file region for the body.
        let bodyContent = "Hello world, this is data from a file!"

        try withTemporaryFile(content: bodyContent) { (handle, path) in
            let region = try FileRegion(fileHandle: handle)
            let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let clientStreamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.fileRegion(region)))
            reqBodyFrame.endStream = true

            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Let's send a quick response back.
            let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
            respFrame.endStream = true
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testSendingDataFrameWithLargeFile() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're going to create a largish temp file: 3 data frames in size.
        var bodyData = self.clientChannel.allocator.buffer(capacity: 1<<14)
        for val in (0..<((1<<14) / MemoryLayout<Int>.size)) {
            bodyData.write(integer: val)
        }

        try withTemporaryFile { (handle, path) in
            for _ in (0..<3) {
                handle.appendBuffer(bodyData)
            }

            let region = try FileRegion(fileHandle: handle)

            // Start by sending the headers.
            let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let clientStreamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Ok, we're gonna send the body here. This should create 4 streams.
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.fileRegion(region)))
            reqBodyFrame.endStream = true
            self.clientChannel.writeAndFlush(reqBodyFrame, promise: nil)
            self.interactInMemory(self.clientChannel, self.serverChannel)

            // We now expect 3 frames.
            for idx in (0..<3) {
                let frame = try self.serverChannel.assertReceivedFrame()
                frame.assertDataFrame(endStream: idx == 2, streamID: serverStreamID.networkStreamID!, payload: bodyData)
            }

            // The client will have seen a pair of window updates.
            try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
            try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: clientStreamID.networkStreamID!, windowIncrement: 32768)

            // Let's send a quick response back.
            let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
            respFrame.endStream = true
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

            // No frames left.
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testMoreRequestsThanMaxConcurrentStreamsAtOnce() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let requestHeaders = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])

        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        // We're going to send 101 requests before we flush.
        var clientStreamIDs = [HTTP2StreamID]()
        var serverStreamIDs = [HTTP2StreamID]()
        var headersFrames = [HTTP2Frame]()

        for _ in 0..<101 {
            let streamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(requestHeaders))

            self.clientChannel.write(reqFrame, promise: nil)

            clientStreamIDs.append(streamID)
            headersFrames.append(reqFrame)
        }
        self.clientChannel.flush()
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // We expect to see the first 100 headers frames, but nothing more.
        for frame in headersFrames.dropLast() {
            let receivedFrame = try self.serverChannel.assertReceivedFrame()
            receivedFrame.assertFrameMatches(this: frame)
            serverStreamIDs.append(receivedFrame.streamID)
        }

        // There should be no frames here.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Let's complete one of the streams by sending data for the first stream on the client, and responding on the server.
        var dataFrame = HTTP2Frame(streamID: clientStreamIDs.first!, payload: .data(.byteBuffer(requestBody)))
        dataFrame.endStream = true
        self.clientChannel.writeAndFlush(dataFrame, promise: nil)

        let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamIDs.first!, payload: .headers(responseHeaders))
        respFrame.endStream = true
        self.serverChannel.writeAndFlush(respFrame, promise: nil)

        // Now we expect the following things to have happened: 1) the client will have seen the server's response,
        // 2) the server will have seen the END_STREAM, and 3) the server will have seen another request, making
        // 101.
        self.interactInMemory(self.clientChannel, self.serverChannel)
        try self.clientChannel.assertReceivedFrame().assertFrameMatches(this: respFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: dataFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: headersFrames.last!)

        // There should be no frames here.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // No need to bother cleaning this up.
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testOverridingDefaultSettings() throws {
        let initialSettings = [
            HTTP2Setting(parameter: .maxHeaderListSize, value: 1000),
            HTTP2Setting(parameter: .initialWindowSize, value: 100),
            HTTP2Setting(parameter: .enablePush, value: 0)
        ]
        XCTAssertNoThrow(try self.clientChannel.pipeline.add(handler: HTTP2Parser(mode: .client, initialSettings: initialSettings)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server)).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel, clientSettings: initialSettings)

        // There should be no frames here.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // No need to bother cleaning this up.
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testBasicPingFrames() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Let's try sending a ping frame.
        let pingData = HTTP2PingData(withInteger: 6000)
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData))
        self.clientChannel.writeAndFlush(pingFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        let receivedPingFrame = try self.serverChannel.assertReceivedFrame()
        receivedPingFrame.assertFrameMatches(this: pingFrame)

        // The client should also see an automatic response without server action.
        let receivedFrame = try self.clientChannel.assertReceivedFrame()
        receivedFrame.assertPingFrame(ack: true, opaqueData: pingData)

        // Clean up
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testUnflushedWritesAreFailedOnChannelInactive() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to send a request, including a body, but not flush it.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        self.clientChannel.write(reqFrame, promise: nil)

        var receivedError: Error? = nil
        let clientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        clientWritePromise.futureResult.whenFailure { error in receivedError = error }
        self.clientChannel.write(reqBodyFrame, promise: clientWritePromise)
        XCTAssertNil(receivedError)

        // Ok, now we're going to send EOF to the client.
        self.clientChannel.pipeline.fireChannelInactive()
        XCTAssertNotNil(receivedError)
        XCTAssertEqual(receivedError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testUnflushedWritesAreFailedOnHalfClosure() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to send a request, including a body, but not flush it.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        self.clientChannel.write(reqFrame, promise: nil)

        var receivedError: Error? = nil
        let clientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        clientWritePromise.futureResult.whenFailure { error in receivedError = error }
        self.clientChannel.write(reqBodyFrame, promise: clientWritePromise)
        XCTAssertNil(receivedError)

        // Ok, now we're going to send half closure to the client.
        self.clientChannel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertNotNil(receivedError)
        XCTAssertEqual(receivedError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testUnflushedWritesAreFailedOnChannelInactiveRentrant() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we'll add a shutdown handler to the client.
        try self.clientChannel.pipeline.add(handler: EOFOnWriteHandler(type: .fullClose), first: true).wait()

        // Now we're going to send a request, including a body, but not flush it.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        self.clientChannel.write(reqFrame, promise: nil)

        var receivedError: Error? = nil
        let clientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        clientWritePromise.futureResult.whenFailure { error in receivedError = error }
        self.clientChannel.write(reqBodyFrame, promise: clientWritePromise)
        XCTAssertNil(receivedError)

        // Ok, now we're going to flush. This will trigger the writes, but they should immediately fail.
        self.clientChannel.flush()
        XCTAssertNotNil(receivedError)
        XCTAssertEqual(receivedError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testUnflushedWritesAreFailedOnHalfClosureReentrant() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we'll add a shutdown handler to the client.
        try self.clientChannel.pipeline.add(handler: EOFOnWriteHandler(type: .halfClose), first: true).wait()

        // Now we're going to send a request, including a body, but not flush it.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        self.clientChannel.write(reqFrame, promise: nil)

        var receivedError: Error? = nil
        let clientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        clientWritePromise.futureResult.whenFailure { error in receivedError = error }
        self.clientChannel.write(reqBodyFrame, promise: clientWritePromise)
        XCTAssertNil(receivedError)

        // Ok, now we're going to flush. This will trigger the writes, but they should immediately fail.
        self.clientChannel.flush()
        XCTAssertNotNil(receivedError)
        XCTAssertEqual(receivedError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testFrameReceivesDoNotTriggerFlushes() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to send a request, including a body, but not flush it.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        self.clientChannel.write(reqFrame, promise: nil)
        self.clientChannel.write(reqBodyFrame, promise: nil)

        // Now the server is going to transmit a PING frame.
        let pingFrame = HTTP2Frame(streamID: HTTP2StreamID(), payload: .ping(HTTP2PingData(withInteger: 52)))
        self.serverChannel.writeAndFlush(pingFrame, promise: nil)

        // The frames will spin in memory.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The client should have received the ping frame, and the server a ping ACK.
        try self.clientChannel.assertReceivedFrame().assertFrameMatches(this: pingFrame)
        try self.serverChannel.assertReceivedFrame().assertPingFrame(ack: true, opaqueData: HTTP2PingData(withInteger: 52))

        // No other frames should be emitted.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testAutomaticFlowControl() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to send a request, including a very large body: 65536 bytes in size. To avoid spending too much
        // time initializing buffers, we're going to send the same 1kB data frame 64 times.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 1024)
        requestBody.write(bytes: Array(repeating: UInt8(0x04), count: 1024))

        // Quickly open a stream before the main test begins.
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        let serverStreamId = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Now prepare the large body.
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        for _ in 0..<63 {
            self.clientChannel.write(reqBodyFrame, promise: nil)
        }
        reqBodyFrame.endStream = true
        self.clientChannel.writeAndFlush(reqBodyFrame, promise: nil)

        // Ok, we now want to send this data to the server.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // We should also see 4 window update frames on the client side: two for the stream, two for the connection.
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: serverStreamId.networkStreamID!, windowIncrement: 32768)
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32767)
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: serverStreamId.networkStreamID!, windowIncrement: 32767)

        // No other frames should be emitted, though the server may have many.
        self.clientChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testPartialFrame() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We want to test whether partial frames are well-handled. We do that by just faking up a PING frame and sending it in two halves.
        var pingBuffer = self.serverChannel.allocator.buffer(capacity: 17)
        pingBuffer.write(integer: UInt16(0))
        pingBuffer.write(integer: UInt8(8))
        pingBuffer.write(integer: UInt8(6))
        pingBuffer.write(integer: UInt8(0))
        pingBuffer.write(integer: UInt32(0))
        pingBuffer.write(integer: UInt64(0))

        XCTAssertNoThrow(try self.serverChannel.writeInbound(pingBuffer.getSlice(at: pingBuffer.readerIndex, length: 8)))
        XCTAssertNoThrow(try self.serverChannel.writeInbound(pingBuffer.getSlice(at: pingBuffer.readerIndex + 8, length: 9)))
        try self.serverChannel.assertReceivedFrame().assertPingFrame(ack: false, opaqueData: HTTP2PingData(withInteger: 0))

        // We should have a PING response. Let's check it.
        self.interactInMemory(self.serverChannel, self.clientChannel)
        try self.clientChannel.assertReceivedFrame().assertPingFrame(ack: true, opaqueData: HTTP2PingData(withInteger: 0))

        // No other frames should be emitted.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testFailingUnflushedWritesForResetStream() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Let's set up a stream.
        let clientStreamID = HTTP2StreamID()
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        let serverStreamId = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Now we're going to queue up a DATA frame.
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(bytes: Array(repeating: UInt8(0x04), count: 128))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))

        var writeError: Error?
        self.clientChannel.write(reqBodyFrame).whenFailure {
            writeError = $0
        }
        XCTAssertNil(writeError)

        // From the server side, we're going to send and deliver a RST_STREAM frame. The client should receive this
        // frame. The pending write will not be failed because it has not yet been flushed.
        let frame = HTTP2Frame(streamID: serverStreamId, payload: .rstStream(.refusedStream))
        try self.assertFramesRoundTrip(frames: [frame], sender: self.serverChannel, receiver: self.clientChannel)
        XCTAssertNil(writeError)

        // When we now flush the write, that write should fail immediately.
        self.clientChannel.flush()
        XCTAssertEqual(writeError as? NIOHTTP2Errors.NoSuchStream, NIOHTTP2Errors.NoSuchStream(streamID: clientStreamID))

        // No other frames should be emitted.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testFailingFlushedWritesForResetStream() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Install a reset handler.
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: InstaResetHandler()).wait())

        // Let's set up a stream.
        let clientStreamID = HTTP2StreamID()
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        var requestBody = self.clientChannel.allocator.buffer(capacity: 1024)
        requestBody.write(bytes: Array(repeating: UInt8(0x04), count: 1024))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))

        // We'll send some frames: specifically, a headers and 80kB of DATA.
        // We do this to ensure that the DATA does not all go out to the network in one go, such that there is still
        // some sitting in the pipeline when the RST_STREAM frame arrives. The last write will have a promise attached.
        var writeError: Error?
        self.clientChannel.write(reqFrame, promise: nil)
        for _ in 0..<79 {
            self.clientChannel.write(reqBodyFrame, promise: nil)
        }

        self.clientChannel.writeAndFlush(reqBodyFrame).whenFailure {
            writeError = $0
        }
        XCTAssertNil(writeError)

        // Let the channels dance. The RST_STREAM should come through.
        self.interactInMemory(self.clientChannel, self.serverChannel)
        try self.clientChannel.assertReceivedFrame().assertRstStreamFrame(streamID: clientStreamID.networkStreamID!, errorCode: .refusedStream)

        // The data frame write should have exploded.
        XCTAssertEqual(writeError as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: clientStreamID, errorCode: .refusedStream))

        // There will also be two window update frames on the connection covering all sent data.
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32768)
        try self.clientChannel.assertReceivedFrame().assertWindowUpdateFrame(streamID: 0, windowIncrement: 32767)

        // No other frames should be emitted.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
