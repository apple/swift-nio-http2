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
import NIOCore
import NIOEmbedded
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

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.type {
        case .halfClose:
            context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        case .fullClose:
            context.fireChannelInactive()
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

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if !self.written {
            self.written = true
            context.channel.write(self.frame, promise: self.writePromise)
        }
        context.write(data, promise: promise)
    }
}

/// A channel handler that verifies that we never send flushes
/// for no reason.
final class NoEmptyFlushesHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var writeCount = 0

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.writeCount += 1
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        XCTAssertGreaterThan(self.writeCount, 0)
        self.writeCount = 0
    }
}

/// A channel handler that forcibly resets all inbound HEADERS frames it receives.
final class InstaResetHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        if case .headers = frame.payload {
            let kaboomFrame = HTTP2Frame(streamID: frame.streamID, payload: .rstStream(.refusedStream))
            context.writeAndFlush(self.wrapOutboundOut(kaboomFrame), promise: nil)
        }
    }
}

/// A channel handler that forcibly sends GOAWAY when it receives the first HEADERS frame.
final class InstaGoawayHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        if case .headers = frame.payload {
            let kaboomFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .inadequateSecurity, opaqueData: nil))
            context.writeAndFlush(self.wrapOutboundOut(kaboomFrame), promise: nil)
        }
    }
}

/// A simple channel handler that records all user events.
final class UserEventRecorder: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    var events: [Any] = []

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
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

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let evt = event as? StreamClosedEvent, evt.streamID == self.targetStreamID else {
            return
        }

        XCTAssertTrue(self.seenFrame)
        XCTAssertFalse(self.seenEvent)
        self.seenEvent = true
    }
}

/// A simple channel handler that adds the NIOHTTP2Handler handler dynamically
/// after a read event has been triggered.
class HTTP2ParserProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTAssertNoThrow(try context.pipeline.addHandler(
            NIOHTTP2Handler(mode: .server)).wait())
        context.fireChannelRead(data)
        _ = context.pipeline.removeHandler(context: context)
    }
}

class SimpleClientServerFramePayloadStreamTests: XCTestCase {
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
    func basicHTTP2Connection(clientSettings: HTTP2Settings = nioDefaultSettings,
                              serverSettings: HTTP2Settings = nioDefaultSettings,
                              maximumBufferedControlFrames: Int = 10000,
                              withMultiplexerCallback multiplexerCallback: ((Channel) -> EventLoopFuture<Void>)? = nil) throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .client,
                                                                                    initialSettings: clientSettings,
                                                                                    maximumBufferedControlFrames: maximumBufferedControlFrames)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .server,
                                                                                    initialSettings: serverSettings,
                                                                                    maximumBufferedControlFrames: maximumBufferedControlFrames)).wait())

        if let multiplexerCallback = multiplexerCallback {
            XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(HTTP2StreamMultiplexer(mode: .client,
                                                                                               channel: self.clientChannel,
                                                                                               inboundStreamInitializer: multiplexerCallback)).wait())
            XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(HTTP2StreamMultiplexer(mode: .server,
                                                                                               channel: self.serverChannel,
                                                                                               inboundStreamInitializer: multiplexerCallback)).wait())
        }

        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel,
                                   clientSettings: clientSettings, serverSettings: serverSettings)
    }

    /// Establish a basic HTTP/2 connection where the HTTP2Parser handler is added after the channel has been activated.
    func basicHTTP2DynamicPipelineConnection() throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .client)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(HTTP2ParserProxyHandler()).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)
    }

    func testBasicRequestResponse() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Let's send a quick response back.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testBasicRequestResponseWithDynamicPipeline() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2DynamicPipelineConnection()

        // We're now going to try to send a request from the client to the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Let's send a quick response back.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testManyRequestsAtOnce() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")

        // We're going to send three requests before we flush.
        var clientStreamIDs = [HTTP2StreamID]()
        var headersFrames = [HTTP2Frame]()
        var bodyFrames = [HTTP2Frame]()

        for id in [1, 3, 5] {
            let streamID = HTTP2StreamID(id)
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            let reqBodyFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))

            self.clientChannel.write(reqFrame, promise: nil)
            self.clientChannel.write(reqBodyFrame, promise: nil)

            clientStreamIDs.append(streamID)
            headersFrames.append(reqFrame)
            bodyFrames.append(reqBodyFrame)
        }
        self.clientChannel.flush()
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // We receive the headers frames first, and then the body frames. Additionally, the
        // body frames come in no particular order, so we need to guard against that.
        for frame in headersFrames {
            let receivedFrame = try self.serverChannel.assertReceivedFrame()
            receivedFrame.assertFrameMatches(this: frame)
        }
        var receivedBodyFrames: [HTTP2Frame] = try assertNoThrowWithValue((0..<bodyFrames.count).map { _ in try self.serverChannel.assertReceivedFrame() })
        receivedBodyFrames.sort(by: { $0.streamID < $1.streamID })
        receivedBodyFrames.assertFramesMatch(bodyFrames)

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

        // In some nghttp2 versions the client will receive a GOAWAY, in others
        // it will not. There is no meaningful assertion to apply here.
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
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Now the server is going to send a GOAWAY frame with the maximum stream ID. This should quiesce the connection:
        // futher frames on stream 1 are allowed, but nothing else.
        let serverGoaway = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil))
        try self.assertFramesRoundTrip(frames: [serverGoaway], sender: self.serverChannel, receiver: self.clientChannel)

        // We should still be able to send DATA frames on stream 1 now.
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))
        try self.assertFramesRoundTrip(frames: [reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // The server will respond, closing this stream.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // The server can now GOAWAY down to stream 1. We evaluate the bytes here ourselves becuase the client won't see this frame.
        let secondServerGoaway = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: serverStreamID, errorCode: .noError, opaqueData: nil))
        self.serverChannel.writeAndFlush(secondServerGoaway, promise: nil)
        guard case .some(.byteBuffer(let bytes)) = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: IOData.self)) else {
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
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Confirm there's no bonus frame sitting around.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now we're going to send in a frame that's just a bit larger than the max frame size of 1<<14.
        let frameSize = (1<<14) + 8
        var buffer = self.clientChannel.allocator.buffer(capacity: frameSize)

        /// To write this in as fast as possible, we're going to fill the buffer one int at a time.
        for val in (0..<(frameSize / MemoryLayout<Int>.size)) {
            buffer.writeInteger(val)
        }

        // Now we'll try to send this in a DATA frame.
        let dataFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(buffer), endStream: true)))
        self.clientChannel.writeAndFlush(dataFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // This should have produced two frames in the server. Both are DATA, one is max frame size and the other
        // is not.
        let firstFrame = try self.serverChannel.assertReceivedFrame()
        firstFrame.assertDataFrame(endStream: false, streamID: serverStreamID, payload: buffer.getSlice(at: 0, length: 1<<14)!)
        let secondFrame = try self.serverChannel.assertReceivedFrame()
        secondFrame.assertDataFrame(endStream: true, streamID: serverStreamID, payload: buffer.getSlice(at: 1<<14, length: 8)!)

        // The client should have got nothing.
        self.clientChannel.assertNoFramesReceived()

        // Now send a response from the server and shut things down.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
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
            let clientStreamID = HTTP2StreamID(1)
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
            let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .fileRegion(region), endStream: true)))

            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Let's send a quick response back.
            let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
            let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
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
            try (self.clientChannel.pipeline.context(handlerType: HTTP2StreamMultiplexer.self).wait().handler as! HTTP2StreamMultiplexer).createStreamChannel(promise: childChannelPromise) { channel in
                return channel.pipeline.addHandler(clientHandler)
            }
            (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()
            let childChannel = try childChannelPromise.futureResult.wait()

            // Start by sending the headers.
            let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers))
            childChannel.writeAndFlush(reqFrame, promise: nil)
            self.interactInMemory(self.clientChannel, self.serverChannel)

            serverHandler.receivedFrames.assertFramePayloadsMatch([reqFrame])
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()

            // Ok, we're gonna send the body here.
            let reqBodyFrame = HTTP2Frame.FramePayload.data(.init(data: .fileRegion(region), endStream: true))
            childChannel.writeAndFlush(reqBodyFrame, promise: nil)
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

    func testMoreRequestsThanMaxConcurrentStreamsAtOnce() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])

        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")

        // We're going to send 101 requests before we flush.
        var clientStreamIDs = [HTTP2StreamID]()
        var serverStreamIDs = [HTTP2StreamID]()
        var headersFrames = [HTTP2Frame]()

        for id in stride(from: 1, through: 201, by: 2) {
            let streamID = HTTP2StreamID(id)
            let reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))

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
        let dataFrame = HTTP2Frame(streamID: clientStreamIDs.first!, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))
        self.clientChannel.writeAndFlush(dataFrame, promise: nil)

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamIDs.first!, payload: .headers(.init(headers :responseHeaders, endStream: true)))
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
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .client, initialSettings: initialSettings)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .server)).wait())
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
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: false))
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

    func testAutomaticFlowControl() throws {
        // Begin by getting the connection up.
        // We add the stream multiplexer here because it manages automatic flow control.
        try self.basicHTTP2Connection() { channel in
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
        let childHandler = InboundFramePayloadRecorder()
        handler.createStreamChannel(promise: nil) { channel in
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

    func testPartialFrame() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We want to test whether partial frames are well-handled. We do that by just faking up a PING frame and sending it in two halves.
        var pingBuffer = self.serverChannel.allocator.buffer(capacity: 17)
        pingBuffer.writeInteger(UInt16(0))
        pingBuffer.writeInteger(UInt8(8))
        pingBuffer.writeInteger(UInt8(6))
        pingBuffer.writeInteger(UInt8(0))
        pingBuffer.writeInteger(UInt32(0))
        pingBuffer.writeInteger(UInt64(0))

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

    func testSendingTrailers() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server. This request will be one headers frame, one
        // data frame, and then another headers frame for trailers.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let trailers = HPACKHeaders([("x-trailers-field", "true")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(requestBody))))
        let trailerFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: trailers, endStream: true)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame, trailerFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Let's send a quick response back. This response should also contain trailers.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders)))
        let respTrailersFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: trailers, endStream: true)))

        let expectedFrames = [respFrame, respTrailersFrame]

        try self.assertFramesRoundTrip(frames: expectedFrames, sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func test1XXResponseHeaderFields() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a simple request from the client.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers, endStream: true)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // We're going to send 3 150 responses back.
        let earlyHeaders = HPACKHeaders([(":status", "150"), ("x-some-data", "is here")])
        let earlyFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: earlyHeaders)))
        try self.assertFramesRoundTrip(frames: [earlyFrame, earlyFrame, earlyFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now we send the final response back.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testPriorityFrames() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let frame = HTTP2Frame(streamID: 1, payload: .priority(.init(exclusive: false, dependency: 0, weight: 30)))
        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: [frame], sender: self.clientChannel, receiver: self.serverChannel))

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamClosedWithNoError() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now add handlers to record user events.
        let clientHandler = UserEventRecorder()
        let serverHandler = UserEventRecorder()
        try self.clientChannel.pipeline.addHandler(clientHandler).wait()
        try self.serverChannel.pipeline.addHandler(serverHandler).wait()

        // We're now going to try to send a request from the client to the server and send a server response back. This
        // stream will terminate cleanly.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
        let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // At this stage the stream is still open, both handlers should have seen stream creation events.
        XCTAssertEqual(clientHandler.events.count, 3)
        XCTAssertEqual(serverHandler.events.count, 3)
        XCTAssertEqual(clientHandler.events[0] as? NIOHTTP2StreamCreatedEvent, NIOHTTP2StreamCreatedEvent(streamID: clientStreamID, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535))
        XCTAssertEqual(serverHandler.events[0] as? NIOHTTP2StreamCreatedEvent, NIOHTTP2StreamCreatedEvent(streamID: serverStreamID, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535))

        // Let's send a quick response back.
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the streams are closed, they should have seen user events.
        XCTAssertEqual(clientHandler.events.count, 5)
        XCTAssertEqual(serverHandler.events.count, 5)
        XCTAssertEqual(clientHandler.events[3] as? StreamClosedEvent, StreamClosedEvent(streamID: clientStreamID, reason: nil))
        XCTAssertEqual(serverHandler.events[3] as? StreamClosedEvent, StreamClosedEvent(streamID: serverStreamID, reason: nil))

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamClosedViaRstStream() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now add handlers to record user events.
        let clientHandler = UserEventRecorder()
        let serverHandler = UserEventRecorder()
        try self.clientChannel.pipeline.addHandler(clientHandler).wait()
        try self.serverChannel.pipeline.addHandler(serverHandler).wait()

        // Initiate a stream from the client. No need to send body data, we don't need it.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // At this stage the stream is still open, both handlers should have seen stream creation events.
        XCTAssertEqual(clientHandler.events.count, 1)
        XCTAssertEqual(serverHandler.events.count, 1)
        XCTAssertEqual(clientHandler.events[0] as? NIOHTTP2StreamCreatedEvent, NIOHTTP2StreamCreatedEvent(streamID: clientStreamID, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535))
        XCTAssertEqual(serverHandler.events[0] as? NIOHTTP2StreamCreatedEvent, NIOHTTP2StreamCreatedEvent(streamID: serverStreamID, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535))

        // The server will reset the stream.
        let rstStreamFrame = HTTP2Frame(streamID: serverStreamID, payload: .rstStream(.cancel))
        try self.assertFramesRoundTrip(frames: [rstStreamFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the streams are closed, they should have seen user events.
        XCTAssertEqual(clientHandler.events.count, 3)
        XCTAssertEqual(serverHandler.events.count, 3)
        XCTAssertEqual(clientHandler.events[1] as? StreamClosedEvent, StreamClosedEvent(streamID: clientStreamID, reason: .cancel))
        XCTAssertEqual(serverHandler.events[1] as? StreamClosedEvent, StreamClosedEvent(streamID: serverStreamID, reason: .cancel))

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamClosedViaGoaway() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now add handlers to record user events.
        let clientHandler = UserEventRecorder()
        let serverHandler = UserEventRecorder()
        try self.clientChannel.pipeline.addHandler(clientHandler).wait()
        try self.serverChannel.pipeline.addHandler(serverHandler).wait()

        // Initiate a stream from the client. No need to send body data, we don't need it.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // At this stage the stream is still open, both handlers should have seen stream creation events.
        XCTAssertEqual(clientHandler.events.count, 1)
        XCTAssertEqual(serverHandler.events.count, 1)
        XCTAssertEqual(clientHandler.events[0] as? NIOHTTP2StreamCreatedEvent, NIOHTTP2StreamCreatedEvent(streamID: clientStreamID, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535))
        XCTAssertEqual(serverHandler.events[0] as? NIOHTTP2StreamCreatedEvent, NIOHTTP2StreamCreatedEvent(streamID: serverStreamID, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535))

        // The server will send a GOAWAY.
        let goawayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))
        try self.assertFramesRoundTrip(frames: [goawayFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the streams are closed, they should have seen user events.
        XCTAssertEqual(clientHandler.events.count, 2)
        XCTAssertEqual(serverHandler.events.count, 2)
        XCTAssertEqual((clientHandler.events[1] as? StreamClosedEvent)?.streamID, clientStreamID)
        XCTAssertEqual((serverHandler.events[1] as? StreamClosedEvent)?.streamID, serverStreamID)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamCloseEventForRstStreamFiresAfterFrame() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Initiate a stream from the client. No need to send body data, we don't need it.
        let clientStreamID = HTTP2StreamID(1)
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Add handler to record stream closed event.
        let handler = ClosedEventVsFrameOrderingHandler(targetStreamID: serverStreamID)
        try self.serverChannel.pipeline.addHandler(handler).wait()

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
        let clientStreamID = HTTP2StreamID(1)
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))

        try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Add handler to record stream closed event.
        let handler = ClosedEventVsFrameOrderingHandler(targetStreamID: clientStreamID)
        try self.clientChannel.pipeline.addHandler(handler).wait()

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
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Obtain some request data.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])

        // We're going to initiate and then close lots of streams.
        // Nothing bad should happen here.
        for id in stride(from: 1, through: 256, by: 2) {
            // We're now going to try to send a request from the client to the server.
            let clientStreamID = HTTP2StreamID(id)
            let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: requestHeaders)))
            let reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(requestBody), endStream: true)))

            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Let's send a quick response back.
            let respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)
        }

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

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTFail("shouldnt' have received \(data)")
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                if let errorSeenPromise = self.errorSeenPromise {
                    errorSeenPromise.succeed(error)
                } else {
                    XCTFail("extra error \(error) received")
                }
            }
        }

        let errorSeenPromise: EventLoopPromise<Error> = self.clientChannel.eventLoop.makePromise()
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .server)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(WaitForErrorHandler(errorSeenPromise: errorSeenPromise)).wait())

        XCTAssertNoThrow(try self.clientChannel?.connect(to: SocketAddress(unixDomainSocketPath: "ignored")).wait())
        XCTAssertNoThrow(try self.serverChannel?.connect(to: SocketAddress(unixDomainSocketPath: "ignored")).wait())

        var buffer = self.clientChannel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("GET / HTTP/1.1\r\nHost: apple.com\r\n\r\n")
        XCTAssertNoThrow(try self.clientChannel.writeAndFlush(buffer).wait())

        self.interactInMemory(self.clientChannel, self.serverChannel)

        XCTAssertNoThrow(try XCTAssertEqual(NIOHTTP2Errors.badClientMagic(),
                                            errorSeenPromise.futureResult.wait() as? NIOHTTP2Errors.BadClientMagic))

        // The client will get two frames: a SETTINGS frame, and a GOAWAY frame. We don't want to decode these, so we
        // just check their bytes match the expected payloads.
        if var settingsFrame: ByteBuffer = try assertNoThrowWithValue(self.clientChannel.readInbound()) {
            let settingsBytes: [UInt8] = [0, 0, 12, 4, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 100, 0, 6, 0, 0, 64, 0]
            XCTAssertEqual(settingsFrame.readBytes(length: settingsFrame.readableBytes), settingsBytes)
        } else {
            XCTFail("No settings frame")
        }

        if var goawayFrame: ByteBuffer = try assertNoThrowWithValue(self.clientChannel.readInbound()) {
            let goawayBytes: [UInt8] = [0, 0, 8, 7, 0, 0, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff, 0, 0, 0, 1]
            XCTAssertEqual(goawayFrame.readBytes(length: goawayFrame.readableBytes), goawayBytes)
        } else {
            XCTFail("No Goaway frame")
        }

        XCTAssertNoThrow(try XCTAssertTrue(self.clientChannel.finish().isClean))
        XCTAssertNoThrow(try XCTAssertTrue(self.serverChannel.finish().isClean))
    }

    func testOpeningWindowsViaSettingsInitialWindowSize() throws {
        try self.basicHTTP2Connection()

        // Start by having the client shrink the server's initial window size to 0. We should get an ACK as well.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .initialWindowSize, value: 0)], sender: self.clientChannel, receiver: self.serverChannel)
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now open a stream.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers, endStream: true)))
        try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Confirm there's no bonus frame sitting around.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // The server can respond with a headers frame and a DATA frame.
        let serverHeaders = HPACKHeaders([(":status", "200")])
        let respFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: serverHeaders)))
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // Confirm there's no bonus frame sitting around.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now we're going to send in a DATA frame. This will not be sent, as the window size is 0.
        var buffer = self.clientChannel.allocator.buffer(capacity: 5)
        buffer.writeStaticString("hello")
        let dataFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(buffer), endStream: true)))
        self.serverChannel.writeAndFlush(dataFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // No frames should be produced.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now the client will send a new SETTINGS frame. This will produce a SETTINGS ACK, and widen the flow control window a bit.
        // We make this one a bit tricky to confirm that we do the math properly: we set the window size to 5, then to 3. The new value
        // should be 3.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .initialWindowSize, value: 5), HTTP2Setting(parameter: .initialWindowSize, value: 3)], sender: self.clientChannel, receiver: self.serverChannel)
        try self.clientChannel.assertReceivedFrame().assertFrameMatches(this: HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(buffer.readSlice(length: 3)!)))))
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Sending the same SETTINGS frame again does not produce more data.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .initialWindowSize, value: 3)], sender: self.clientChannel, receiver: self.serverChannel)
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now we can widen the window again, and get the rest of the frame.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .initialWindowSize, value: 6)], sender: self.clientChannel, receiver: self.serverChannel)
        try self.clientChannel.assertReceivedFrame().assertFrameMatches(this: HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(buffer.readSlice(length: 2)!), endStream: true))))
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testSettingsAckNotifiesAboutChangedFlowControl() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()
        let recorder = UserEventRecorder()
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(recorder).wait())

        // Let's open a few streams.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")])
        let frames = [HTTP2StreamID(1), HTTP2StreamID(3), HTTP2StreamID(5)].map { HTTP2Frame(streamID: $0, payload: .headers(.init(headers: headers))) }
        try self.assertFramesRoundTrip(frames: frames, sender: self.clientChannel, receiver: self.serverChannel)

        // We will have some user events here, none should be a SETTINGS_INITIAL_WINDOW_SIZE change.
        XCTAssertFalse(recorder.events.contains(where: { $0 is NIOHTTP2BulkStreamWindowChangeEvent }))

        // Now the client will send, and get acknowledged, a new settings with a different stream window size.
        // For fanciness, we change it twice.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .initialWindowSize, value: 60000), HTTP2Setting(parameter: .initialWindowSize, value: 50000)], sender: self.clientChannel, receiver: self.serverChannel)
        let events = recorder.events.compactMap { $0 as? NIOHTTP2BulkStreamWindowChangeEvent }
        XCTAssertEqual(events, [NIOHTTP2BulkStreamWindowChangeEvent(delta: -15535)])

        // Let's do it again, just to prove it isn't a fluke.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .initialWindowSize, value: 65535)], sender: self.clientChannel, receiver: self.serverChannel)
        let newEvents = recorder.events.compactMap { $0 as? NIOHTTP2BulkStreamWindowChangeEvent }
        XCTAssertEqual(newEvents, [NIOHTTP2BulkStreamWindowChangeEvent(delta: -15535), NIOHTTP2BulkStreamWindowChangeEvent(delta: 15535)])

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamMultiplexerAcknowledgesSettingsBasedFlowControlChanges() throws {
        // This test verifies that the stream multiplexer pays attention to notifications about settings changes to flow
        // control windows. It can't do that by *raising* the flow control window, as that information is duplicated in the
        // stream flow control change notifications sent by receiving data frames. So it must do it by *shrinking* the window.

        // Begin by getting the connection up and add a stream multiplexer.
        try self.basicHTTP2Connection()
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(HTTP2StreamMultiplexer(mode: .server, channel: self.serverChannel, inboundStreamInitializer: nil)).wait())

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

    func testChangingMaxFrameSize() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))
        try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Now the server is going to change SETTINGS_MAX_FRAME_SIZE. We set this twice to confirm we do this properly.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .maxFrameSize, value: 1<<15), HTTP2Setting(parameter: .maxFrameSize, value: 1<<16)], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the client will send a very large DATA frame. It must be passed through as a single entity, and accepted by the remote peer.
        var buffer = self.clientChannel.allocator.buffer(capacity: 65535)
        buffer.writeBytes(repeatElement(UInt8(0xFF), count: 65535))
        let bodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(buffer))))
        try self.assertFramesRoundTrip(frames: [bodyFrame], sender: self.clientChannel, receiver: self.serverChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testStreamErrorOnSelfDependentPriorityFrames() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Send a PRIORITY frame that has a self-dependency. Note that we aren't policing these outbound:
        // as we can't detect cycles generally without maintaining a bunch of state, we simply don't. That
        // allows us to emit this.
        let frame = HTTP2Frame(streamID: 1, payload: .priority(.init(exclusive: false, dependency: 1, weight: 32)))
        self.clientChannel.writeAndFlush(frame, promise: nil)

        // We treat this as a connection error.
        guard let frameData = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive frame")
            return
        }
        XCTAssertThrowsError(try self.serverChannel.writeInbound(frameData)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.priorityCycle(streamID: 1))
        }

        guard let responseFrame = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive response frame")
            return
        }
        XCTAssertNoThrow(try self.clientChannel.writeInbound(responseFrame))

        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(lastStreamID: .maxID, errorCode: UInt32(http2ErrorCode: .protocolError), opaqueData: nil)

        XCTAssertNoThrow(XCTAssertTrue(try self.clientChannel.finish().isClean))
        _ = try? self.serverChannel.finish()
    }

    func testStreamErrorOnSelfDependentHeadersFrames() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Send a HEADERS frame that has a self-dependency. Note that we aren't policing these outbound:
        // as we can't detect cycles generally without maintaining a bunch of state, we simply don't. That
        // allows us to emit this.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let frame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers, priorityData: .init(exclusive: true, dependency: 1, weight: 64))))
        self.clientChannel.writeAndFlush(frame, promise: nil)

        // We treat this as a connection error.
        guard let frameData = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive frame")
            return
        }
        XCTAssertThrowsError(try self.serverChannel.writeInbound(frameData)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.priorityCycle(streamID: 1))
        }

        guard let responseFrame = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive response frame")
            return
        }
        XCTAssertNoThrow(try self.clientChannel.writeInbound(responseFrame))

        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(lastStreamID: .maxID, errorCode: UInt32(http2ErrorCode: .protocolError), opaqueData: nil)

        XCTAssertNoThrow(XCTAssertTrue(try self.clientChannel.finish().isClean))
        _ = try? self.serverChannel.finish()
    }

    func testInvalidRequestHeaderBlockAllowsRstStream() throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .client, headerBlockValidation: .disabled)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .server)).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)

        // We're going to send some invalid HTTP/2 request headers. The client has validation disabled, and will allow it, but the server will not.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"), ("UPPERCASE", "not allowed")])
        let frame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers)))
        self.clientChannel.writeAndFlush(frame, promise: nil)

        // We treat this as a stream error.
        guard let frameData = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive frame")
            return
        }
        XCTAssertThrowsError(try self.serverChannel.writeInbound(frameData)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.InvalidHTTP2HeaderFieldName, NIOHTTP2Errors.invalidHTTP2HeaderFieldName("UPPERCASE"))
        }

        guard let responseFrame = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive response frame")
            return
        }
        XCTAssertNoThrow(try self.clientChannel.writeInbound(responseFrame))

        try self.clientChannel.assertReceivedFrame().assertRstStreamFrame(streamID: 1, errorCode: .protocolError)

        XCTAssertNoThrow(XCTAssertTrue(try self.clientChannel.finish().isClean))
        _ = try? self.serverChannel.finish()
    }

    func testClientConnectionErrorCorrectlyReported() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // Now we're going to try to trigger a connection error in the client. We'll do it by sending a weird SETTINGS frame that isn't valid.
        let weirdSettingsFrame: [UInt8] = [
            0x00, 0x00, 0x06,           // 3-byte payload length (6 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x02,                 // SETTINGS_ENABLE_PUSH
            0x00, 0x00, 0x00, 0x03,     //      = 3, an invalid value
        ]
        var settingsBuffer = self.clientChannel.allocator.buffer(capacity: 128)
        settingsBuffer.writeBytes(weirdSettingsFrame)

        XCTAssertThrowsError(try self.clientChannel.writeInbound(settingsBuffer)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.InvalidSetting, NIOHTTP2Errors.invalidSetting(setting: HTTP2Setting(parameter: .enablePush, value: 3)))
        }

        guard let goAwayFrame = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive GOAWAY frame")
            return
        }
        XCTAssertNoThrow(try self.serverChannel.writeInbound(goAwayFrame))
        try self.serverChannel.assertReceivedFrame().assertGoAwayFrame(lastStreamID: .maxID, errorCode: 0x01, opaqueData: nil)

        XCTAssertNoThrow(XCTAssertTrue(try self.serverChannel.finish().isClean))
        _ = try? self.clientChannel.finish()
    }

    func testChangingMaxConcurrentStreams() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers, endStream: true)))
        try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Now the server is going to change SETTINGS_MAX_CONCURRENT_STREAMS. We set this twice to confirm we do this properly.
        try self.assertSettingsUpdateWithAck([HTTP2Setting(parameter: .maxConcurrentStreams, value: 50), HTTP2Setting(parameter: .maxConcurrentStreams, value: 1)], sender: self.serverChannel, receiver: self.clientChannel)

        // Now the client will attempt to open another stream. This should buffer.
        let reqFrame2 = HTTP2Frame(streamID: 3, payload: .headers(.init(headers: headers, endStream: true)))
        self.clientChannel.writeAndFlush(reqFrame2, promise: nil)
        XCTAssertNoThrow(try XCTAssertNil(self.clientChannel.readOutbound(as: ByteBuffer.self)))

        // The server will now complete the first stream, which should lead to the second stream being emitted.
        let responseHeaders = HPACKHeaders([(":status", "200")])
        let respFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        self.serverChannel.writeAndFlush(respFrame, promise: nil)
        self.interactInMemory(self.serverChannel, self.clientChannel)

        // The client should have seen the server response.
        guard let response = try assertNoThrowWithValue(self.clientChannel.readInbound(as: HTTP2Frame.self)) else {
            XCTFail("Did not receive server HEADERS frame")
            return
        }
        response.assertFrameMatches(this: respFrame)

        // The server should have seen the new client request.
        guard let request = try assertNoThrowWithValue(self.serverChannel.readInbound(as: HTTP2Frame.self)) else {
            XCTFail("Did not receive client HEADERS frame")
            return
        }
        request.assertFrameMatches(this: reqFrame2)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testFailsPromisesForBufferedWrites() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're going to queue some frames in the client, but not flush them. The HEADERS frame will pass
        // right through, but the DATA ones won't.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers, endStream: false)))

        var promiseResults: [Bool?] = Array(repeatElement(nil as Bool?, count: 5))
        self.clientChannel.write(reqFrame, promise: nil)

        let bodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        for index in promiseResults.indices {
            self.clientChannel.write(bodyFrame).map {
                promiseResults[index] = true
            }.whenFailure {
                XCTAssertEqual($0 as? ChannelError, ChannelError.ioOnClosedChannel)
                promiseResults[index] = false
            }
        }

        XCTAssertEqual(promiseResults, [nil, nil, nil, nil, nil])

        // Close the channel.
        self.clientChannel.close(promise: nil)
        self.clientChannel.embeddedEventLoop.run()

        // The promises should be succeeded.
        XCTAssertEqual(promiseResults, [false, false, false, false, false])
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testAllowPushPromiseBeforeReceivingHeadersNoBody() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")])

        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers, endStream: true)))

        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel))

        // The server will push.
        let pushFrame = HTTP2Frame(streamID: clientStreamID, payload: .pushPromise(.init(pushedStreamID: 2, headers: headers)))
        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: [pushFrame], sender: self.serverChannel, receiver: self.clientChannel))

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testAllowPushPromiseBeforeReceivingHeadersWithPossibleBody() throws {
        // This is the same as the test above but we don't set END_STREAM on our initial HEADERS, leading to a different stream state.
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")])

        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers, endStream: false)))

        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel))

        // The server will push.
        let pushFrame = HTTP2Frame(streamID: clientStreamID, payload: .pushPromise(.init(pushedStreamID: 2, headers: headers)))
        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: [pushFrame], sender: self.serverChannel, receiver: self.clientChannel))

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testSequentialEmptyDataFramesIsForbidden() throws {
        try self.basicHTTP2Connection()

        // We're going to open a few streams.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let streamIDs = [HTTP2StreamID(1), HTTP2StreamID(3)]
        let headersFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .headers(.init(headers: headers, endStream: false))) }

        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: headersFrames, sender: self.clientChannel, receiver: self.serverChannel))

        // Now we're going to send 2 empty data frames.
        let emptyBuffer = self.clientChannel.allocator.buffer(capacity: 2)
        let dataFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .data(.init(data: .byteBuffer(emptyBuffer), endStream: false))) }

        // First we send 1 without drama.
        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: [dataFrames.first!], sender: self.clientChannel, receiver: self.serverChannel))

        // Now we try to send the second.
        self.clientChannel.writeAndFlush(dataFrames.last!, promise: nil)
        guard let bytes = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not write client bytes")
            return
        }

        // The server should have errored.
        XCTAssertThrowsError(try self.serverChannel.writeInbound(bytes)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.ExcessiveEmptyDataFrames, NIOHTTP2Errors.excessiveEmptyDataFrames())
        }

        guard let serverBytes = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not write server bytes")
            return
        }
        XCTAssertNoThrow(XCTAssertNil(try self.serverChannel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(try self.clientChannel.writeInbound(serverBytes))

        // The client should have seen a GOAWAY.
        guard let goaway = try assertNoThrowWithValue(self.clientChannel.readInbound(as: HTTP2Frame.self)) else {
            XCTFail("Did not receive server GOAWAY frame")
            return
        }
        goaway.assertGoAwayFrame(lastStreamID: .maxID, errorCode: UInt32(HTTP2ErrorCode.enhanceYourCalm.networkCode), opaqueData: nil)

        XCTAssertNoThrow(try self.clientChannel.finish())
    }

    func testSequentialEmptyDataFramesLimitIsConfigurable() throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .client)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(NIOHTTP2Handler(mode: .server, maximumSequentialEmptyDataFrames: 5)).wait())
        XCTAssertNoThrow(try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))

        // We're going to open a few streams.
        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let streamIDs = [HTTP2StreamID(1), HTTP2StreamID(3)]
        let headersFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .headers(.init(headers: headers, endStream: false))) }

        XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: headersFrames, sender: self.clientChannel, receiver: self.serverChannel))

        // Now we're going to send 6 empty data frames.
        let emptyBuffer = self.clientChannel.allocator.buffer(capacity: 2)
        let twoDataFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .data(.init(data: .byteBuffer(emptyBuffer), endStream: false))) }
        let dataFrames = repeatElement(twoDataFrames, count: 3).flatMap { $0 }
        XCTAssertEqual(dataFrames.count, 6)

        // First we send 5 without drama.
        for frame in dataFrames.prefix(5) {
            XCTAssertNoThrow(try self.assertFramesRoundTrip(frames: [frame], sender: self.clientChannel, receiver: self.serverChannel))
        }

        // Now we try to send the sixth.
        self.clientChannel.writeAndFlush(dataFrames.last!, promise: nil)
        guard let bytes = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not write client bytes")
            return
        }

        // The server should have errored.
        XCTAssertThrowsError(try self.serverChannel.writeInbound(bytes)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.ExcessiveEmptyDataFrames, NIOHTTP2Errors.excessiveEmptyDataFrames())
        }

        guard let serverBytes = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not write server bytes")
            return
        }
        XCTAssertNoThrow(XCTAssertNil(try self.serverChannel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(try self.clientChannel.writeInbound(serverBytes))

        // The client should have seen a GOAWAY.
        guard let goaway = try assertNoThrowWithValue(self.clientChannel.readInbound(as: HTTP2Frame.self)) else {
            XCTFail("Did not receive server GOAWAY frame")
            return
        }
        goaway.assertGoAwayFrame(lastStreamID: .maxID, errorCode: UInt32(HTTP2ErrorCode.enhanceYourCalm.networkCode), opaqueData: nil)

        XCTAssertNoThrow(try self.clientChannel.finish())
    }

    func testDenialOfServiceViaPing() throws {
        let maximimBufferedControlFrames = 50

        // Begin by getting the connection up.
        try self.basicHTTP2Connection(maximumBufferedControlFrames: maximimBufferedControlFrames)

        // Now mark the server's channel as non-writable.
        self.serverChannel.isWritable = false
        self.serverChannel.pipeline.fireChannelWritabilityChanged()

        // Now we want to send many PING frames. The server should not be writing any out,
        // as the channel isn't writable.
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 0), ack: false))
        let frames = Array(repeatElement(pingFrame, count: maximimBufferedControlFrames))
        try self.assertFramesRoundTrip(frames: frames, sender: self.clientChannel, receiver: self.serverChannel)

        // Ok, now send one more ping frame. This should cause an error
        XCTAssertNoThrow(try XCTAssertTrue(self.clientChannel.writeOutbound(pingFrame).isFull))
        guard let pingBytes = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive PING frame bytes")
            return
        }
        XCTAssertThrowsError(try self.serverChannel.writeInbound(pingBytes)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.ExcessiveOutboundFrameBuffering, NIOHTTP2Errors.excessiveOutboundFrameBuffering())
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
    }

    func testDenialOfServiceViaSettings() throws {
        let maximimBufferedControlFrames = 50

        // Begin by getting the connection up.
        try self.basicHTTP2Connection(maximumBufferedControlFrames: maximimBufferedControlFrames)

        // Now mark the server's channel as non-writable.
        self.serverChannel.isWritable = false
        self.serverChannel.pipeline.fireChannelWritabilityChanged()

        // Now we want to send many empty SETTINGS frames. The server should not be writing any out,
        // as the channel isn't writable.
        let settingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings([])))
        let frames = Array(repeatElement(settingsFrame, count: maximimBufferedControlFrames))
        try self.assertFramesRoundTrip(frames: frames, sender: self.clientChannel, receiver: self.serverChannel)

        // Ok, now send one more settings frame. This should cause connection teardown.
        XCTAssertNoThrow(try XCTAssertTrue(self.clientChannel.writeOutbound(settingsFrame).isFull))
        guard let settingsBytes = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive SETTINGS frame bytes")
            return
        }
        XCTAssertThrowsError(try self.serverChannel.writeInbound(settingsBytes)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.ExcessiveOutboundFrameBuffering, NIOHTTP2Errors.excessiveOutboundFrameBuffering())
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
    }

    func testFramesArentWrittenWhenChannelIsntWritable() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let headers = HPACKHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.writeStaticString("A simple HTTP/2 request.")

        // The client opens a streeam
        try self.assertFramesRoundTrip(frames: [HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers, endStream: false)))], sender: self.clientChannel, receiver: self.serverChannel)

        // Now the client loses writability.
        self.clientChannel.isWritable = false
        self.clientChannel.pipeline.fireChannelWritabilityChanged()

        // Now the client is going to try to write a bunch of data on stream 1.
        let dataFrames = Array(repeatElement(HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(requestBody), endStream: false))), count: 100))
        for frame in dataFrames {
            self.clientChannel.writeAndFlush(frame, promise: nil)
        }
        XCTAssertNoThrow(try self.clientChannel.throwIfErrorCaught())

        // Also the client is going to try to initiate 100 more streams. This would normally violate SETTINGS_MAX_CONCURRENT_STREAMS, but in this case they should all
        // be buffered locally.
        let bonusStreams = stride(from: HTTP2StreamID(3), to: HTTP2StreamID(203), by: 2).map { HTTP2Frame(streamID: $0, payload: .headers(.init(headers: headers, endStream: true))) }
        for frame in bonusStreams {
            self.clientChannel.writeAndFlush(frame, promise: nil)
        }
        XCTAssertNoThrow(try self.clientChannel.throwIfErrorCaught())

        // The client shouldn't have written any of these.
        XCTAssertNoThrow(try XCTAssertNil(self.clientChannel.readOutbound(as: ByteBuffer.self)))

        // Now make the channel readable.
        self.clientChannel.isWritable = true
        self.clientChannel.pipeline.fireChannelWritabilityChanged()

        // All but 1 of the HEADERS frames should now come out, followed by the DATA frames.
        self.interactInMemory(self.clientChannel, self.serverChannel)

        var receivedFrames = Array<HTTP2Frame>()
        while let frame = try assertNoThrowWithValue(self.serverChannel.readInbound(as: HTTP2Frame.self)) {
            receivedFrames.append(frame)
        }
        receivedFrames.assertFramesMatch(Array(bonusStreams.dropLast()) + dataFrames)

        // Now we close stream a stream on the server side.
        let responseHeaders = HPACKHeaders([(":status", "200")])
        let responseFrame = HTTP2Frame(streamID: 3, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        XCTAssertNoThrow(try self.serverChannel.writeOutbound(responseFrame))
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // This should get the last HEADERS frame out.
        try self.clientChannel.readInbound(as: HTTP2Frame.self)!.assertFrameMatches(this: responseFrame)
        try self.serverChannel.readInbound(as: HTTP2Frame.self)!.assertFrameMatches(this: bonusStreams.last!)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testEnforcingMaxHeaderListSize() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // The server is going to shrink its value for max header list size.
        let newSettings = [HTTP2Setting(parameter: .maxHeaderListSize, value: 225)]
        try self.assertSettingsUpdateWithAck(newSettings, sender: self.serverChannel, receiver: self.clientChannel)

        // Ok, first let's send something safe. This size is calculated as 32 bytes per entry, plus the octet length
        // of the name and value. The below block is 225 bytes, as shown below.
        let goodHeaders = HPACKHeaders([
            (":path", "/"),               // 32 byte overhead + 5 byte name + one byte value == 38 bytes, total is 38
            (":method", "GET"),           // 32 byte overhead + 7 byte name + 3 byte value == 42 bytes, total is 80
            (":authority", "localhost"),  // 32 byte overhead + 10 byte name + 9 byte value == 51 bytes, total is 131
            (":scheme", "https"),         // 32 byte overhead + 7 byte name + 5 byte value == 44 bytes, total is 175
            ("user-agent", "swiftnio"),   // 32 byte overhead + 10 byte name + 8 byte value == 50 bytes, total is 225
        ])
        let firstRequestFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: goodHeaders)))
        try self.assertFramesRoundTrip(frames: [firstRequestFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // Ok, we'll create some new headers that are bad by adding one byte to the last header field.
        let badHeaders = HPACKHeaders([
            (":path", "/"),               // 32 byte overhead + 5 byte name + one byte value == 38 bytes, total is 38
            (":method", "GET"),           // 32 byte overhead + 7 byte name + 3 byte value == 42 bytes, total is 80
            (":authority", "localhost"),  // 32 byte overhead + 10 byte name + 9 byte value == 51 bytes, total is 131
            (":scheme", "https"),         // 32 byte overhead + 7 byte name + 5 byte value == 44 bytes, total is 175
            ("user-agent", "swiftnio2"),  // 32 byte overhead + 10 byte name + 9 byte value == 51 bytes, total is 226
        ])

        // These should be forbidden. This is a connection error, as we do not promise to have decoded all the headers.
        let secondRequestFrame = HTTP2Frame(streamID: 3, payload: .headers(.init(headers: badHeaders)))
        self.clientChannel.writeAndFlush(secondRequestFrame, promise: nil)

        guard let frameData = try assertNoThrowWithValue(self.clientChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive frame")
            return
        }
        XCTAssertThrowsError(try self.serverChannel.writeInbound(frameData)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.UnableToParseFrame, NIOHTTP2Errors.unableToParseFrame())
        }

        guard let responseFrame = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive response frame")
            return
        }
        XCTAssertNoThrow(try self.clientChannel.writeInbound(responseFrame))

        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(lastStreamID: .maxID, errorCode: UInt32(HTTP2ErrorCode.compressionError.networkCode), opaqueData: nil)
    }

    func testForbidsExceedingMaxHeaderListSizeBeforeDecoding() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // The server is going to shrink its value for max header list size.
        let newSettings = [HTTP2Setting(parameter: .maxHeaderListSize, value: 225)]
        try self.assertSettingsUpdateWithAck(newSettings, sender: self.serverChannel, receiver: self.clientChannel)

        // This test will validate that the server will not allow the HPACK block to exceed the set max header list size
        // even before the header block is complete. To do that, we're going to send a HEADERS frame and then a sequence of
        // CONTINUATION frames. These will never decompress to a valid block, but we don't expect them to get that far.
        let weirdHeadersFrame: [UInt8] = [
            0x00, 0x00, 0x01,           // 3-byte payload length (1 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x82,                       // payload
        ]
        let weirdContinuationFrame: [UInt8] = [
            0x00, 0x00, 0x01,           // 3-byte payload length (1 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x82,                       // payload
        ]

        // Each byte of payload is accompanied by 9 bytes of overhead, so we need to allocate enough space to send 255 bytes of payload.
        var firstBuffer = self.serverChannel.allocator.buffer(capacity: 10 * 225)
        firstBuffer.writeBytes(weirdHeadersFrame)
        for _ in 0..<224 {
            firstBuffer.writeBytes(weirdContinuationFrame)
        }

        // Sending this should not result in an error.
        XCTAssertNoThrow(try self.serverChannel.writeInbound(firstBuffer))
        XCTAssertNoThrow(XCTAssertNil(try self.serverChannel.readOutbound(as: ByteBuffer.self)))

        // But if we send one more frame, that will be treated as a violation of SETTINGS_MAX_HEADER_LIST_SIZE.
        XCTAssertThrowsError(try self.serverChannel.writeInbound(firstBuffer.getSlice(at: firstBuffer.writerIndex - 10, length: 10)!)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.ExcessivelyLargeHeaderBlock, NIOHTTP2Errors.excessivelyLargeHeaderBlock())
        }
        guard let responseFrame = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive response frame")
            return
        }
        XCTAssertNoThrow(try self.clientChannel.writeInbound(responseFrame))

        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(lastStreamID: .maxID, errorCode: UInt32(HTTP2ErrorCode.protocolError.networkCode), opaqueData: nil)
    }

    func testForbidsExceedingMaxHeaderListSizeBeforeDecodingSingleFrame() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // The server is going to shrink its value for max header list size.
        let newSettings = [HTTP2Setting(parameter: .maxHeaderListSize, value: 225)]
        try self.assertSettingsUpdateWithAck(newSettings, sender: self.serverChannel, receiver: self.clientChannel)

        // This test will validate that the server will not allow the HPACK block to exceed the set max header list size
        // even before the header block is complete. To do that, we're going to send a HEADERS frame that is itself too long to expect
        // to decode.
        let weirdHeadersFrame: [UInt8] = [
            0x00, 0x00, 0xE2,           // 3-byte payload length (226 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]

        // We don't even need the body, we shouldn't get that far.
        var buffer = self.serverChannel.allocator.buffer(capacity: 9)
        buffer.writeBytes(weirdHeadersFrame)

        // This frame will be treated as a violation of SETTINGS_MAX_HEADER_LIST_SIZE.
        XCTAssertThrowsError(try self.serverChannel.writeInbound(buffer)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.ExcessivelyLargeHeaderBlock, NIOHTTP2Errors.excessivelyLargeHeaderBlock())
        }
        guard let responseFrame = try assertNoThrowWithValue(self.serverChannel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("Did not receive response frame")
            return
        }
        XCTAssertNoThrow(try self.clientChannel.writeInbound(responseFrame))

        try self.clientChannel.assertReceivedFrame().assertGoAwayFrame(lastStreamID: .maxID, errorCode: UInt32(HTTP2ErrorCode.protocolError.networkCode), opaqueData: nil)
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
        let handler = try self.clientChannel.pipeline.handler(type: HTTP2StreamMultiplexer.self).wait()
        let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))

        handler.createStreamChannel(promise: nil) { channel in
            // We need END_STREAM set here, because that will force the stream to be closed on the response.
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
        let handler = try self.clientChannel.pipeline.handler(type: HTTP2StreamMultiplexer.self).wait()

        handler.createStreamChannel(promise: nil) { channel in
            let reqFrame = HTTP2Frame.FramePayload.headers(.init(headers: headers))
            channel.write(reqFrame, promise: nil)

            var requestBody = self.clientChannel.allocator.buffer(capacity: 65535)
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

    func testGreasedSettingsAreTolerated() throws {
        let settings = nioDefaultSettings + [HTTP2Setting(parameter: .init(extensionSetting: 0xfafa), value: 0xf0f0f0f0)]
        XCTAssertNoThrow(try self.basicHTTP2Connection(clientSettings: settings))
    }

    func testStreamCreationOrder() throws {
        try self.basicHTTP2Connection()
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.clientChannel, inboundStreamInitializer: nil)
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(multiplexer).wait())

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

    func testStreamClosedInvalidRequestHeaders() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server. This request
        // contains an invalid header ("transfer-encoding", "chunked"), which will trigger an error.
        // We'll confirm that the error notifies that this stream was created and then closed.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"), ("transfer-encoding", "chunked")
        ])

        let clientStreamID = HTTP2StreamID(1)
        let reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.init(headers: headers)))

        XCTAssertThrowsError(try self.clientChannel.writeAndFlush(reqFrame).wait()) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.ForbiddenHeaderField,
                NIOHTTP2Errors.forbiddenHeaderField(name: "transfer-encoding", value: "chunked")
            )
        }

        XCTAssertThrowsError(try self.clientChannel.throwIfErrorCaught()) { error in
            guard let streamError = error as? NIOHTTP2Errors.StreamError else {
                XCTFail("Unexpected error kind: \(error)")
                return
            }

            XCTAssertEqual(streamError.streamID, 1)
            XCTAssertEqual(
                streamError.baseError as? NIOHTTP2Errors.ForbiddenHeaderField,
                NIOHTTP2Errors.forbiddenHeaderField(name: "transfer-encoding", value: "chunked")
            )
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testHTTP2HandlerDoesNotFlushExcessively() throws {
        try self.basicHTTP2Connection()

        class FlushCounter: ChannelOutboundHandler {
            typealias OutboundIn = Never
            var flushCount = 0

            func flush(context: ChannelHandlerContext) {
                self.flushCount += 1
                context.flush()
            }
        }

        let counter = FlushCounter()
        XCTAssertNoThrow(try self.clientChannel.pipeline.syncOperations.addHandler(counter, position: .first))

        // 'channelReadComplete' should cause the HTTP2Handler to emit a flush if any frames have
        // been written. No frames have been written, so no flush should be emitted.
        self.clientChannel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(counter.flushCount, 0)
    }

    func testHTTPHandlerIgnoresInboundAltServiceFrames() throws {
        try self.basicHTTP2Connection()

        let h2ClientHandler = try self.clientChannel.pipeline.syncOperations.handler(type: NIOHTTP2Handler.self)
        let h2FrameRecorder = FrameRecorderHandler()
        try self.clientChannel.pipeline.syncOperations.addHandler(h2FrameRecorder, position: .after(h2ClientHandler))

        let altServiceFrameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x0a,                       // 1-byte frame type (ALTSVC)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x09,                 // 2-byte origin size ("apple.com"; 9 bytes)
        ]

        var buffer = self.clientChannel.allocator.buffer(bytes: altServiceFrameBytes)
        buffer.writeString("apple.com")
        buffer.writeString("h2=\":8000\"")
        XCTAssertEqual(buffer.readableBytes, 30) // 9 (header) + 21 (origin, field)
        XCTAssertNoThrow(try self.clientChannel.writeInbound(buffer))

        // Frame should be dropped.
        XCTAssert(h2FrameRecorder.receivedFrames.isEmpty)
    }

    func testHTTPHandlerIgnoresInboundOriginFrames() throws {
        try self.basicHTTP2Connection()

        let h2ClientHandler = try self.clientChannel.pipeline.syncOperations.handler(type: NIOHTTP2Handler.self)
        let h2FrameRecorder = FrameRecorderHandler()
        try self.clientChannel.pipeline.syncOperations.addHandler(h2FrameRecorder, position: .after(h2ClientHandler))

        let originFrameBytes: [UInt8] = [
            0x00, 0x00, 0x2a,           // 3-byte payload length (42 bytes)
            0x0c,                       // 1-byte frame type (ORIGIN)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00      // 4-byte stream identifier,
        ]

        var buffer = self.clientChannel.allocator.buffer(bytes: originFrameBytes)
        var originBytesWritten = 0

        for origin in ["apple.com", "www.apple.com", "www2.apple.com"] {
            originBytesWritten += try buffer.writeLengthPrefixed(as: UInt16.self) {
                $0.writeString(origin)
            }
        }

        XCTAssertEqual(originBytesWritten, 42)
        XCTAssertEqual(buffer.readableBytes, 51)

        XCTAssertNoThrow(try self.clientChannel.writeInbound(buffer))

        // Frame should be dropped.
        XCTAssert(h2FrameRecorder.receivedFrames.isEmpty)
    }

    func testWriteWithAlreadyCompletedPromise() throws {
        try self.basicHTTP2Connection()

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.clientChannel, inboundStreamInitializer: nil)
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(multiplexer).wait())

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
