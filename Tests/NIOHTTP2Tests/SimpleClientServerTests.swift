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
import NIOHPACK
@testable import NIOHTTP2

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

/// Emits a write to the channel the first time a write is received at this point of the pipeline.
final class WriteOnWriteHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private var written = false
    private let frame: HTTP2Frame
    private let writePromise: EventLoopPromise<Void>

    init(frame: HTTP2Frame, promise: EventLoopPromise<Void>) {
        self.frame = frame
        self.writePromise = promise
    }

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if !self.written {
            self.written = true
            ctx.channel.write(self.frame, promise: self.writePromise)
        }
        ctx.write(data, promise: promise)
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

/// A channel handler that forcibly resets all inbound HEADERS frames it receives.
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

/// A channel handler that forcibly sends GOAWAY when it receives the first HEADERS frame.
final class InstaGoawayHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        if case .headers = frame.payload {
            let kaboomFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .inadequateSecurity, opaqueData: nil))
            ctx.writeAndFlush(self.wrapOutboundOut(kaboomFrame), promise: nil)
        }
    }
}

/// A simple channel handler that records all user events.
final class UserEventRecorder: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    var events: [Any] = []

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        events.append(event)
    }
}

/// A simple channel handler that enforces that stream closed events fire after the
/// frame is dispatched, not before.
final class ClosedEventVsFrameOrderingHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    var seenFrame = false
    var seenEvent = false
    let targetStreamID: HTTP2StreamID

    init(targetStreamID: HTTP2StreamID) {
        self.targetStreamID = targetStreamID
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch (frame.payload, frame.streamID) {
        case (.rstStream, self.targetStreamID),
             (.goAway(_, _, _), .rootStream):
            XCTAssertFalse(self.seenFrame)
            XCTAssertFalse(self.seenEvent)
            self.seenFrame = true
        default:
            break
        }
        ctx.fireChannelRead(data)
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        guard let evt = event as? StreamClosedEvent, evt.streamID == self.targetStreamID else {
            return
        }

        XCTAssertTrue(self.seenFrame)
        XCTAssertFalse(self.seenEvent)
        self.seenEvent = true
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
    func basicHTTP2Connection(maxCachedClosedStreams: Int = 1024) throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.add(handler: HTTP2Parser(mode: .client, maxCachedClosedStreams: maxCachedClosedStreams)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server, maxCachedClosedStreams: maxCachedClosedStreams)).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)
    }

    func testBasicRequestResponse() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.flags.insert(.endStream)

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Let's send a quick response back.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
        respFrame.flags.insert(.endStream)
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testManyRequestsAtOnce() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        // We're going to send three requests before we flush.
        var clientStreamIDs = [HTTP2StreamID]()
        var headersFrames = [HTTP2Frame]()
        var dataFrames = [HTTP2Frame]()

        for _ in 0..<3 {
            let streamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(requestHeaders, nil))
            var reqBodyFrame = HTTP2Frame(streamID: streamID, payload: .data(.byteBuffer(requestBody)))
            reqBodyFrame.flags.insert(.endStream)

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
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Now the server is going to send a GOAWAY frame with the maximum stream ID. This should quiesce the connection:
        // futher frames on stream 1 are allowed, but nothing else.
        let serverGoaway = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil))
        try self.assertFramesRoundTrip(frames: [serverGoaway], sender: self.serverChannel, receiver: self.clientChannel)

        // We should still be able to send DATA frames on stream 1 now.
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.flags.insert(.endStream)
        try self.assertFramesRoundTrip(frames: [reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // The server will respond, closing this stream.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
        respFrame.flags.insert(.endStream)
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
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
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
        dataFrame.flags.insert(.endStream)
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
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
        respFrame.flags.insert(.endStream)
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
            let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let clientStreamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.fileRegion(region)))
            reqBodyFrame.flags.insert(.endStream)

            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Let's send a quick response back.
            let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
            respFrame.flags.insert(.endStream)
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
            let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let clientStreamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Ok, we're gonna send the body here. This should create 4 streams.
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.fileRegion(region)))
            reqBodyFrame.flags.insert(.endStream)
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
            let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
            respFrame.flags.insert(.endStream)
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

        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])

        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        // We're going to send 101 requests before we flush.
        var clientStreamIDs = [HTTP2StreamID]()
        var serverStreamIDs = [HTTP2StreamID]()
        var headersFrames = [HTTP2Frame]()

        for _ in 0..<101 {
            let streamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(requestHeaders, nil))

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
        dataFrame.flags.insert(.endStream)
        self.clientChannel.writeAndFlush(dataFrame, promise: nil)

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamIDs.first!, payload: .headers(responseHeaders, nil))
        respFrame.flags.insert(.endStream)
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
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.flags.insert(.endStream)
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
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.flags.insert(.endStream)
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

        // Now we're going to send a request, including a body.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))

        var firstWriteError: Error? = nil
        var secondWriteError: Error? = nil
        let clientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        clientWritePromise.futureResult.whenFailure { error in firstWriteError = error }
        let secondClientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        secondClientWritePromise.futureResult.whenFailure { error in secondWriteError = error }

        // Now we'll add a shutdown handler to the client. We'll also add a handler that will propagate a new write on the first one, without
        // flushing it. This write will fail: the other will not.
        try self.clientChannel.pipeline.add(handler: WriteOnWriteHandler(frame: reqBodyFrame, promise: secondClientWritePromise), first: true).wait()
        try self.clientChannel.pipeline.add(handler: EOFOnWriteHandler(type: .fullClose), first: true).wait()

        // Now we issue the two writes. Nothing has happened yet.
        self.clientChannel.write(reqFrame, promise: nil)
        self.clientChannel.write(reqBodyFrame, promise: clientWritePromise)
        XCTAssertNil(firstWriteError)
        XCTAssertNil(secondWriteError)

        // Ok, now we're going to flush. This will trigger the writes: the first will succeed, the ßecond will fail.
        self.clientChannel.flush()
        XCTAssertNil(firstWriteError)
        XCTAssertNotNil(secondWriteError)
        XCTAssertEqual(secondWriteError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testUnflushedWritesAreFailedOnHalfClosureReentrant() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to send a request, including a body.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))

        var firstWriteError: Error? = nil
        var secondWriteError: Error? = nil
        let clientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        clientWritePromise.futureResult.whenFailure { error in firstWriteError = error }
        let secondClientWritePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.newPromise()
        secondClientWritePromise.futureResult.whenFailure { error in secondWriteError = error }

        // Now we'll add a shutdown handler to the client. We'll also add a handler that will propagate a new write on the first one, without
        // flushing it. This write will fail: the other will not.
        try self.clientChannel.pipeline.add(handler: WriteOnWriteHandler(frame: reqBodyFrame, promise: secondClientWritePromise), first: true).wait()
        try self.clientChannel.pipeline.add(handler: EOFOnWriteHandler(type: .halfClose), first: true).wait()

        // Now we issue the two writes. Nothing has happened yet.
        self.clientChannel.write(reqFrame, promise: nil)
        self.clientChannel.write(reqBodyFrame, promise: clientWritePromise)
        XCTAssertNil(firstWriteError)
        XCTAssertNil(secondWriteError)

        // Ok, now we're going to flush. This will trigger the writes: the first will succeed, the ßecond will fail.
        self.clientChannel.flush()
        XCTAssertNil(firstWriteError)
        XCTAssertNotNil(secondWriteError)
        XCTAssertEqual(secondWriteError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testFrameReceivesDoNotTriggerFlushes() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to send a request, including a body, but not flush it.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.flags.insert(.endStream)
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
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 1024)
        requestBody.write(bytes: Array(repeating: UInt8(0x04), count: 1024))

        // Quickly open a stream before the main test begins.
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        let serverStreamId = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Now prepare the large body.
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        for _ in 0..<63 {
            self.clientChannel.write(reqBodyFrame, promise: nil)
        }
        reqBodyFrame.flags.insert(.endStream)
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
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
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
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
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

    func testFailingUnflushedWritesForGoaway() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Let's set up a stream.
        let clientStreamID = HTTP2StreamID()
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Now we're going to queue up a DATA frame.
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(bytes: Array(repeating: UInt8(0x04), count: 128))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))

        var writeError: Error?
        self.clientChannel.write(reqBodyFrame).whenFailure {
            writeError = $0
        }
        XCTAssertNil(writeError)

        // From the server side, we're going to send and deliver a GOAWAY frame. The client should receive this
        // frame. The pending write will not be failed because it has not yet been flushed.
        let frame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .inadequateSecurity, opaqueData: nil))
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

    func testFailingFlushedWritesForGoaway() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Install a reset handler.
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: InstaGoawayHandler()).wait())

        // Let's set up a stream.
        let clientStreamID = HTTP2StreamID()
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
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

        // Let the channels dance. The GOAWAY should come through.
        self.interactInMemory(self.clientChannel, self.serverChannel)
        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(lastStreamID: 0, errorCode: UInt32(http2ErrorCode: HTTP2ErrorCode.inadequateSecurity), opaqueData: nil)

        // The data frame write should have exploded. nghttp2 synthesises an error code for this.
        XCTAssertEqual((writeError as? NIOHTTP2Errors.StreamClosed)?.streamID, clientStreamID)

        // No other frames should be emitted.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testSendingTrailers() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server. This request will be one headers frame, one
        // data frame, and then another headers frame for trailers.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let trailers = HPACKHeaders([("x-trailers-field", "true")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        var trailerFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(trailers, nil))
        trailerFrame.flags.insert(.endStream)

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame, trailerFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Let's send a quick response back. This response should also contain trailers.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
        var respTrailersFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(trailers, nil))
        respTrailersFrame.flags.insert(.endStream)
        try self.assertFramesRoundTrip(frames: [respFrame, respTrailersFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func test1XXResponseHeaderFields() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a simple request from the client.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        var reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        reqFrame.flags.insert(.endStream)

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // We're going to send 3 150 responses back.
        let earlyHeaders = HPACKHeaders([(":status", "150"), ("x-some-data", "is here")])
        let earlyFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(earlyHeaders, nil))
        try self.assertFramesRoundTrip(frames: [earlyFrame, earlyFrame, earlyFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now we send the final response back.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
        respFrame.flags.insert(.endStream)
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testPriorityFramesAreNotEmitted() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to explicitly send in PRIORITY frame. This needs to be manually serialized as NIO currently
        // doesn't support sending PRIORITY frames directly.
        var buffer = self.clientChannel.allocator.buffer(capacity: 14)

        // Length is 5.
        buffer.write(integer: UInt8(0))
        buffer.write(integer: UInt16(5))

        // Frame type 2, no flags, stream ID 1.
        buffer.write(integer: UInt8(2))
        buffer.write(integer: UInt8(0))
        buffer.write(integer: UInt32(1))

        // Exclusive dependency on stream 0, weight 255.
        buffer.write(integer: UInt32(0x80000000))
        buffer.write(integer: UInt8(0xff))

        // Write the buffer in.
        XCTAssertNoThrow(try self.serverChannel.writeInbound(buffer))

        // No data should be received on the server channel.
        self.serverChannel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamClosedWithNoError() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now add handlers to record user events.
        let clientHandler = UserEventRecorder()
        let serverHandler = UserEventRecorder()
        try self.clientChannel.pipeline.add(handler: clientHandler).wait()
        try self.serverChannel.pipeline.add(handler: serverHandler).wait()

        // We're now going to try to send a request from the client to the server and send a server response back. This
        // stream will terminate cleanly.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.flags.insert(.endStream)

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // At this stage the stream is still open, neither handler will have seen events.
        XCTAssertEqual(clientHandler.events.count, 0)
        XCTAssertEqual(serverHandler.events.count, 0)

        // Let's send a quick response back.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
        respFrame.flags.insert(.endStream)
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the streams are closed, they should have seen user events.
        XCTAssertEqual(clientHandler.events.count, 1)
        XCTAssertEqual(serverHandler.events.count, 1)
        XCTAssertEqual(clientHandler.events[0] as? StreamClosedEvent, StreamClosedEvent(streamID: clientStreamID, reason: nil))
        XCTAssertEqual(serverHandler.events[0] as? StreamClosedEvent, StreamClosedEvent(streamID: serverStreamID, reason: nil))

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamClosedViaRstStream() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now add handlers to record user events.
        let clientHandler = UserEventRecorder()
        let serverHandler = UserEventRecorder()
        try self.clientChannel.pipeline.add(handler: clientHandler).wait()
        try self.serverChannel.pipeline.add(handler: serverHandler).wait()

        // Initiate a stream from the client. No need to send body data, we don't need it.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // At this stage the stream is still open, neither handler will have seen events.
        XCTAssertEqual(clientHandler.events.count, 0)
        XCTAssertEqual(serverHandler.events.count, 0)

        // The server will reset the stream.
        let rstStreamFrame = HTTP2Frame(streamID: serverStreamID, payload: .rstStream(.cancel))
        try self.assertFramesRoundTrip(frames: [rstStreamFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the streams are closed, they should have seen user events.
        XCTAssertEqual(clientHandler.events.count, 1)
        XCTAssertEqual(serverHandler.events.count, 1)
        XCTAssertEqual(clientHandler.events[0] as? StreamClosedEvent, StreamClosedEvent(streamID: clientStreamID, reason: .cancel))
        XCTAssertEqual(serverHandler.events[0] as? StreamClosedEvent, StreamClosedEvent(streamID: serverStreamID, reason: .cancel))

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamClosedViaGoaway() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now add handlers to record user events.
        let clientHandler = UserEventRecorder()
        let serverHandler = UserEventRecorder()
        try self.clientChannel.pipeline.add(handler: clientHandler).wait()
        try self.serverChannel.pipeline.add(handler: serverHandler).wait()

        // Initiate a stream from the client. No need to send body data, we don't need it.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // At this stage the stream is still open, neither handler will have seen events.
        XCTAssertEqual(clientHandler.events.count, 0)
        XCTAssertEqual(serverHandler.events.count, 0)

        // The server will send a GOAWAY.
        let goawayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))
        try self.assertFramesRoundTrip(frames: [goawayFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the streams are closed, they should have seen user events.
        XCTAssertEqual(clientHandler.events.count, 1)
        XCTAssertEqual(serverHandler.events.count, 1)
        XCTAssertEqual((clientHandler.events[0] as? StreamClosedEvent)?.streamID, clientStreamID)
        XCTAssertEqual((serverHandler.events[0] as? StreamClosedEvent)?.streamID, serverStreamID)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamCloseEventForRstStreamFiresAfterFrame() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Initiate a stream from the client. No need to send body data, we don't need it.
        let clientStreamID = HTTP2StreamID()
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Add handler to record stream closed event.
        let handler = ClosedEventVsFrameOrderingHandler(targetStreamID: serverStreamID)
        try self.serverChannel.pipeline.add(handler: handler).wait()

        // The client will reset the stream.
        let rstStreamFrame = HTTP2Frame(streamID: serverStreamID, payload: .rstStream(.cancel))
        try self.assertFramesRoundTrip(frames: [rstStreamFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Check we saw the frame and the event.
        XCTAssertTrue(handler.seenEvent)
        XCTAssertTrue(handler.seenFrame)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamCloseEventForGoawayFiresAfterFrame() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Initiate a stream from the client. No need to send body data, we don't need it.
        let clientStreamID = HTTP2StreamID()
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers, nil))

        try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Add handler to record stream closed event.
        let handler = ClosedEventVsFrameOrderingHandler(targetStreamID: clientStreamID)
        try self.clientChannel.pipeline.add(handler: handler).wait()

        // The server will send GOAWAY.
        let goawayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))
        try self.assertFramesRoundTrip(frames: [goawayFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Check we saw the frame and the event.
        XCTAssertTrue(handler.seenEvent)
        XCTAssertTrue(handler.seenFrame)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testManyConcurrentInactiveStreams() throws {
        let maxCachedClosedStreams = 128

        // Begin by getting the connection up.
        try self.basicHTTP2Connection(maxCachedClosedStreams: maxCachedClosedStreams)

        // Obtain some request data.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])

        // We're going to initiate and then close more than maxCachedClosedStreams streams.
        // Nothing bad should happen here.
        for _ in 0...maxCachedClosedStreams {
            // We're now going to try to send a request from the client to the server.
            let clientStreamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(requestHeaders, nil))
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
            reqBodyFrame.flags.insert(.endStream)

            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Let's send a quick response back.
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
            respFrame.flags.insert(.endStream)
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testDontRemoveActiveStreams() throws {
        // This is a bit of a regression test, not a generally useful one. See https://github.com/apple/swift-nio-http2/pull/11/
        // for more.
        let maxCachedClosedStreams = 128

        // Begin by getting the connection up.
        try self.basicHTTP2Connection(maxCachedClosedStreams: maxCachedClosedStreams)

        // Obtain some request data.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])

        // We're going to initiate and then close one fewer than maxCachedClosedStreams streams.
        // Nothing bad should happen here.
        for _ in 0..<(maxCachedClosedStreams - 2) {
            let clientStreamID = HTTP2StreamID()
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(requestHeaders, nil))
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
            reqBodyFrame.flags.insert(.endStream)

            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Let's send a quick response back.
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders, nil))
            respFrame.flags.insert(.endStream)
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)
        }

        // Ok, now we're going to open *two* streams. In the old, broken code, the opening of the second
        // stream would discard the first *open* stream, instead of one of the dead old ones.
        let clientStreamIDs = (0..<2).map { _ in HTTP2StreamID() }
        let clientFrames = clientStreamIDs.map { HTTP2Frame(streamID: $0, payload: .headers(requestHeaders, nil)) }
        let serverStreamIDs = try self.assertFramesRoundTrip(frames: clientFrames, sender: self.clientChannel, receiver: self.serverChannel).map { $0.streamID }

        // Now we're going to send the two data frames for these streams.
        // In the old broken version of this code, this will fail because we accidentally deleted one of our two *open*
        // stream states, instead of one of the 1024 closed ones. Booleans are hard.
        let clientDataFrames = clientStreamIDs.map { HTTP2Frame(streamID: $0, payload: .data(.byteBuffer(requestBody))) }
        try self.assertFramesRoundTrip(frames: clientDataFrames, sender: self.clientChannel, receiver: self.serverChannel)

        // Clean it up with the server now.
        let serverFrames = serverStreamIDs.map { streamID -> HTTP2Frame in
            var respFrame = HTTP2Frame(streamID: streamID, payload: .headers(responseHeaders, nil))
            respFrame.flags.insert(.endStream)
            return respFrame
        }
        try self.assertFramesRoundTrip(frames: serverFrames, sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testCachingInteractionWithMaxConcurrentStreams() throws {
        // Here we test that having MAX_CONCURRENT_STREAMS higher than the cached closed streams does nothing.
        // Also added for https://github.com/apple/swift-nio-http2/pull/11/
        let maxCachedClosedStreams = 64

        // Begin by getting the connection up.
        try self.basicHTTP2Connection(maxCachedClosedStreams: maxCachedClosedStreams)

        // Obtain some request data.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        // Here we're going to issue exactly the number of streams we're willing to cache.
        let clientStreamIDs = (0..<(maxCachedClosedStreams - 1)).map { _ in HTTP2StreamID() }
        let clientHeadersFrames = clientStreamIDs.map { HTTP2Frame(streamID: $0, payload: .headers(requestHeaders, nil)) }
        try self.assertFramesRoundTrip(frames: clientHeadersFrames, sender: self.clientChannel, receiver: self.serverChannel)

        // Now we send one more. In the bad code, this crashes.
        let finalStreamID = HTTP2StreamID()
        let explosionFrame = HTTP2Frame(streamID: finalStreamID, payload: .headers(requestHeaders, nil))
        try self.assertFramesRoundTrip(frames: [explosionFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // If we got here, all is well. We can tear down.
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testBadClientMagic() throws {
        class WaitForErrorHandler: ChannelInboundHandler {
            typealias InboundIn = Never

            private var errorSeenPromise: EventLoopPromise<Error>?

            init(errorSeenPromise: EventLoopPromise<Error>) {
                self.errorSeenPromise = errorSeenPromise
            }

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                XCTFail("shouldnt' have received \(data)")
            }

            func errorCaught(ctx: ChannelHandlerContext, error: Error) {
                if let errorSeenPromise = self.errorSeenPromise {
                    errorSeenPromise.succeed(result: error)
                } else {
                    XCTFail("extra error \(error) received")
                }
            }
        }

        let errorSeenPromise: EventLoopPromise<Error> = self.clientChannel.eventLoop.newPromise()
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: WaitForErrorHandler(errorSeenPromise: errorSeenPromise)).wait())

        self.clientChannel?.pipeline.fireChannelActive()
        self.serverChannel?.pipeline.fireChannelActive()

        var buffer = self.clientChannel.allocator.buffer(capacity: 16)
        buffer.write(staticString: "GET / HTTP/1.1\r\nHost: apple.com\r\n\r\n")
        XCTAssertNoThrow(try self.clientChannel.writeAndFlush(buffer).wait())

        self.interactInMemory(self.clientChannel, self.serverChannel)

        XCTAssertNoThrow(try XCTAssertEqual(NIOHTTP2Errors.BadClientMagic(),
                                            errorSeenPromise.futureResult.wait() as? NIOHTTP2Errors.BadClientMagic))
        let clientReceived: ByteBuffer? = self.clientChannel.readInbound()
        XCTAssertNotNil(clientReceived)

        XCTAssertNoThrow(try XCTAssertFalse(self.clientChannel.finish()))
        XCTAssertNoThrow(try XCTAssertFalse(self.serverChannel.finish()))
    }
}
