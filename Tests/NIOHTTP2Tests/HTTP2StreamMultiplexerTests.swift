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
import NIOHTTP1
@testable import NIOHPACK       // for HPACKHeaders initializers
@testable import NIOHTTP2

private extension Channel {
    /// Adds a simple no-op `HTTP2StreamMultiplexer` to the pipeline.
    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func addNoOpMultiplexer(mode: NIOHTTP2Handler.ParserMode) {
        XCTAssertNoThrow(try self.pipeline.addHandler(HTTP2StreamMultiplexer(mode: mode, channel: self) { (channel, streamID) in
            self.eventLoop.makeSucceededFuture(())
        }).wait())
    }
}

private struct MyError: Error { }


/// A handler that asserts the frames received match the expected set.
private final class FrameExpecter: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    private let expectedFrames: [HTTP2Frame]
    private var actualFrames: [HTTP2Frame] = []
    private var inactive = false

    init(expectedFrames: [HTTP2Frame]) {
        self.expectedFrames = expectedFrames
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTAssertFalse(self.inactive)
        let frame = self.unwrapInboundIn(data)
        self.actualFrames.append(frame)
    }

    func channelInactive(context: ChannelHandlerContext) {
        XCTAssertFalse(self.inactive)
        self.inactive = true

        XCTAssertEqual(self.expectedFrames.count, self.actualFrames.count)

        for (idx, expectedFrame) in self.expectedFrames.enumerated() {
            let actualFrame = self.actualFrames[idx]
            expectedFrame.assertFrameMatches(this: actualFrame)
        }
    }
}


// A handler that keeps track of the writes made on a channel. Used to work around the limitations
// in `EmbeddedChannel`.
final class WriteRecorder<Write>: ChannelOutboundHandler {
    typealias OutboundIn = Write
    typealias OutboundOut = Write

    var flushedWrites: [Write] = []
    private var unflushedWrites: [Write] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.unflushedWrites.append(self.unwrapOutboundIn(data))
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        self.flushedWrites.append(contentsOf: self.unflushedWrites)
        self.unflushedWrites = []
        context.flush()
    }
}

typealias FrameWriteRecorder = WriteRecorder<HTTP2Frame>
typealias FramePayloadWriteRecorder = WriteRecorder<HTTP2Frame.FramePayload>


/// A handler that keeps track of all reads made on a channel.
final class InboundRecorder<Frame>: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Frame

    private let framesLock = NIOLock()
    private var _receivedFrames: [Frame] = []
    var receivedFrames: [Frame] {
        get {
            self.framesLock.withLock {
                self._receivedFrames
            }
        }
        set {
            self.framesLock.withLock {
                self._receivedFrames = newValue
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.receivedFrames.append(self.unwrapInboundIn(data))
    }
}

typealias InboundFrameRecorder = InboundRecorder<HTTP2Frame>
typealias InboundFramePayloadRecorder = InboundRecorder<HTTP2Frame.FramePayload>

/// A handler that tracks the number of times read() was called on the channel.
final class ReadCounter: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var readCount = 0

    func read(context: ChannelHandlerContext) {
        readCount += 1
        context.read()
    }
}


/// A handler that tracks the number of times flush() was called on the channel.
final class FlushCounter: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var flushCount = 0

    func flush(context: ChannelHandlerContext) {
        self.flushCount += 1
        context.flush()
    }
}


final class ReadCompleteCounter: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    var readCompleteCount = 0

    func channelReadComplete(context: ChannelHandlerContext) {
        self.readCompleteCount += 1
        context.fireChannelReadComplete()
    }
}


/// A channel handler that sends a response in response to a HEADERS frame.
final class QuickResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        guard case .headers = frame.payload else {
            context.fireChannelRead(data)
            return
        }

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let responseFrame = HTTP2Frame(streamID: frame.streamID, payload: .headers(.init(headers: responseHeaders, endStream: true)))
        context.writeAndFlush(self.wrapOutboundOut(responseFrame), promise: nil)
        context.fireChannelRead(data)
    }
}

final class QuickFramePayloadResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)

        guard case .headers = payload else {
            context.fireChannelRead(data)
            return
        }

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])
        let responseFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: responseHeaders, endStream: true))
        context.writeAndFlush(self.wrapOutboundOut(responseFramePayload), promise: nil)
        context.fireChannelRead(data)
    }
}

/// A channel handler that succeeds a promise when removed from
/// a pipeline.
final class HandlerRemovedHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    let removedPromise: EventLoopPromise<Void>

    init(removedPromise: EventLoopPromise<Void>) {
        self.removedPromise = removedPromise
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.removedPromise.succeed(())
    }
}


/// A channel handler that succeeds a promise when its channel becomes active.
final class ActiveHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    let activatedPromise: EventLoopPromise<Void>

    init(activatedPromise: EventLoopPromise<Void>) {
        self.activatedPromise = activatedPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.activatedPromise.succeed(())
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.activatedPromise.succeed(())
    }
}


final class HTTP2StreamMultiplexerTests: XCTestCase {
    var channel: EmbeddedChannel!

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        self.channel = nil
    }

    private func activateStream(_ streamID: HTTP2StreamID) {
        let activated = NIOHTTP2StreamCreatedEvent(streamID: streamID, localInitialWindowSize: 16384, remoteInitialWindowSize: 16384)
        self.channel.pipeline.fireUserInboundEventTriggered(activated)
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerIgnoresFramesOnStream0() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        let simplePingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testHeadersFramesCreateNewChannels() throws {
        var channelCount = 0
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelCount += 1
            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a bunch of headers frames.
        for streamID in stride(from: 1, to: 100, by: 2) {
            let frame = HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        XCTAssertEqual(channelCount, 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testChannelsCloseThemselvesWhenToldTo() throws {
        var completedChannelCount = 0
        var closeFutures: [EventLoopFuture<Void>] = []
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            closeFutures.append(channel.closeFuture)
            channel.closeFuture.whenSuccess { completedChannelCount += 1 }
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a bunch of headers frames with endStream on them. This should open some streams.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }
        XCTAssertEqual(completedChannelCount, 0)

        // Now we send them all a clean exit.
        for streamID in streamIDs {
            let event = StreamClosedEvent(streamID: streamID, reason: nil)
            self.channel.pipeline.fireUserInboundEventTriggered(event)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage all the promises should be completed.
        XCTAssertEqual(completedChannelCount, 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testChannelsCloseAfterResetStreamFrameFirstThenEvent() throws {
        var closeError: Error? = nil

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            return channel.pipeline.addHandler(FrameExpecter(expectedFrames: [frame, rstStreamFrame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)
        XCTAssertNil(closeError)

        // Now we can send a RST_STREAM frame.
        XCTAssertNoThrow(try self.channel.writeInbound(rstStreamFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed with the appropriate error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))
        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testChannelsCloseAfterGoawayFrameFirstThenEvent() throws {
        var closeError: Error? = nil

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        let goAwayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            // The channel won't see the goaway frame.
            return channel.pipeline.addHandler(FrameExpecter(expectedFrames: [frame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)
        XCTAssertNil(closeError)

        // Now we can send a GOAWAY frame. This will close the stream.
        XCTAssertNoThrow(try self.channel.writeInbound(goAwayFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .refusedStream)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed with the appropriate manufactured error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .refusedStream))
        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testFramesForUnknownStreamsAreReported() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let streamID = HTTP2StreamID(5)
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))

        XCTAssertThrowsError(try self.channel.writeInbound(dataFrame)) { error in
            XCTAssertEqual(streamID, (error as? NIOHTTP2Errors.NoSuchStream).map { $0.streamID })
        }
        
        self.channel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testFramesForClosedStreamsAreReported() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        // We need to open the stream, then close it. A headers frame will open it, and then the closed event will close it.
        let streamID = HTTP2StreamID(5)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // Ok, now we can send a DATA frame for the now-closed stream.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))

        XCTAssertThrowsError(try self.channel.writeInbound(dataFrame)) { error in
            XCTAssertEqual(streamID, (error as? NIOHTTP2Errors.NoSuchStream).map { $0.streamID })
        }

        self.channel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testClosingIdleChannels() throws {
        let frameReceiver = FrameWriteRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a bunch of headers frames. These will all be answered by RST_STREAM frames.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
            self.activateStream(streamID)
        }

        let expectedFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .rstStream(.cancel)) }
        XCTAssertEqual(expectedFrames.count, frameReceiver.flushedWrites.count)
        for (idx, expectedFrame) in expectedFrames.enumerated() {
            let actualFrame = frameReceiver.flushedWrites[idx]
            expectedFrame.assertFrameMatches(this: actualFrame)
        }
        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testClosingActiveChannels() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame.
        childChannel.close(promise: nil)
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testClosePromiseIsSatisfiedWithTheEvent() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        var closed = false
        childChannel.close().whenComplete { _ in closed = true }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertFalse(closed)

        // Now send the stream closed event. This will satisfy the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertTrue(closed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultipleClosePromisesAreSatisfied() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(1)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it several times. This triggers one RST_STREAM frame. The channel will not be closed at this time.
        var firstClosed = false
        var secondClosed = false
        var thirdClosed = false
        childChannel.close().whenComplete { _ in
            XCTAssertFalse(firstClosed)
            XCTAssertFalse(secondClosed)
            XCTAssertFalse(thirdClosed)
            firstClosed = true
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed)
            XCTAssertFalse(secondClosed)
            XCTAssertFalse(thirdClosed)
            secondClosed = true
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed)
            XCTAssertTrue(secondClosed)
            XCTAssertFalse(thirdClosed)
            thirdClosed = true
        }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertFalse(thirdClosed)

        // Now send the stream closed event. This will satisfy the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertTrue(thirdClosed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testClosePromiseFailsWithError() throws {
        let frameReceiver = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        var closeError: Error? = nil
        childChannel.close().whenFailure { closeError = $0 }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        frameReceiver.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertNil(closeError)

        // Now send the stream closed event. This will fail the close promise.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testFramesAreNotDeliveredUntilStreamIsSetUp() throws {
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFrameRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(1)

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.context(handlerType: InboundFrameRecorder.self).wait().handler as! InboundFrameRecorder
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Send a few data frames for this stream, which should also not go through.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Use a PING frame to check that the channel is still functioning.
        let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        XCTAssertNoThrow(try self.channel.writeInbound(ping))
        try self.channel.assertReceivedFrame().assertPingFrameMatches(this: ping)
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, complete the setup promise. This should trigger all the frames to be delivered.
        setupCompletePromise.succeed(())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertHeadersFrameMatches(this: frame)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFrameMatches(this: dataFrame)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testFramesAreNotDeliveredIfSetUpFails() throws {
        let writeRecorder = FrameWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFrameRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's send a headers frame to open the stream, along with some DATA frames.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)

        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.context(handlerType: InboundFrameRecorder.self).wait().handler as! InboundFrameRecorder
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, fail the setup promise. This should deliver a RST_STREAM frame, but not yet close the channel.
        // The channel should, however, be inactive.
        var channelClosed = false
        childChannel.closeFuture.whenComplete { _ in channelClosed = true }
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)
        XCTAssertFalse(channelClosed)

        setupCompletePromise.fail(MyError())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        // Even delivering a new DATA frame should do nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Now sending the stream closed event should complete the closure. All frames should be dropped. No new writes.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        XCTAssertFalse(channelClosed)

        (childChannel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(channelClosed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testFlushingOneChannelDoesntFlushThemAll() throws {
        let writeTracker = FrameWriteRecorder()
        var channels: [Channel] = []
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channels.append(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeTracker).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open two streams.
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
            self.activateStream(streamID)
        }
        XCTAssertEqual(channels.count, 2)

        // We will now write a headers frame to each channel. Neither frame should be written to the connection. To verify this
        // we will flush the parent channel.
        for (idx, streamID) in [firstStreamID, secondStreamID].enumerated() {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            channels[idx].write(frame, promise: nil)
        }
        self.channel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 0)

        // Now we're going to flush only the first child channel. This should cause one flushed write.
        channels[0].flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 1)

        // Now the other.
        channels[1].flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testUnflushedWritesFailOnClose() throws {
        var childChannel: Channel? = nil
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            childChannel = channel
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // We will now write a headers frame to the channel, but don't flush it.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        childChannel!.write(responseFrame).whenFailure {
            writeError = $0
        }
        XCTAssertNil(writeError)

        // Now we're going to deliver a normal close to the stream.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertEqual(writeError as? ChannelError, ChannelError.eof)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testUnflushedWritesFailOnError() throws {
        var childChannel: Channel? = nil
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            childChannel = channel
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // We will now write a headers frame to the channel, but don't flush it.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        childChannel!.write(responseFrame).whenFailure {
            writeError = $0
        }
        XCTAssertNil(writeError)

        // Now we're going to deliver a normal close to the stream.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)
        XCTAssertEqual(writeError as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWritesFailOnClosedStreamChannels() throws {
        var childChannel: Channel? = nil
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            childChannel = channel
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNotNil(channel)

        // Now let's close it.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        // We will now write a headers frame to the channel. This should fail immediately.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        childChannel!.write(responseFrame).whenFailure {
            writeError = $0
        }
        XCTAssertEqual(writeError as? ChannelError, ChannelError.ioOnClosedChannel)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReadPullsInAllFrames() throws {
        var childChannel: Channel? = nil
        let frameRecorder = InboundFrameRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) -> EventLoopFuture<Void> in
            childChannel = channel

            // We're going to disable autoRead on this channel.
            return channel.getOption(ChannelOptions.autoRead).map {
                XCTAssertTrue($0)
            }.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: false)
            }.flatMap {
                channel.getOption(ChannelOptions.autoRead)
            }.map {
                XCTAssertFalse($0)
            }.flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())


        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(1)
        XCTAssertNotNil(childChannel)

        // Now we're going to deliver 5 data frames for this stream.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        for _ in 0..<5 {
            let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // These frames should not have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // We'll call read() on the child channel.
        childChannel!.read()

        // All frames should now have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertFrameMatches(this: frame)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFrame(endStream: false, streamID: 1, payload: buffer)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReadIsPerChannel() throws {
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)
        var frameRecorders: [HTTP2StreamID: InboundFrameRecorder] = [:]

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, streamID) -> EventLoopFuture<Void> in
            let recorder = InboundFrameRecorder()
            frameRecorders[streamID] = recorder

            // Disable autoRead on the first channel.
            return channel.setOption(ChannelOptions.autoRead, value: streamID != firstStreamID).flatMap {
                return channel.pipeline.addHandler(recorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open two streams.
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
            self.activateStream(streamID)
        }
        XCTAssertEqual(frameRecorders.count, 2)

        // Stream 1 should not have received a frame, stream 3 should.
        XCTAssertEqual(frameRecorders[firstStreamID]!.receivedFrames.count, 0)
        XCTAssertEqual(frameRecorders[secondStreamID]!.receivedFrames.count, 1)

        // Deliver a DATA frame to each stream, which should also have gone into stream 3 but not stream 1.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        // Stream 1 should not have received a frame, stream 3 should.
        XCTAssertEqual(frameRecorders[firstStreamID]!.receivedFrames.count, 0)
        XCTAssertEqual(frameRecorders[secondStreamID]!.receivedFrames.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReadWillCauseAutomaticFrameDelivery() throws {
        var childChannel: Channel? = nil
        let frameRecorder = InboundFrameRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) -> EventLoopFuture<Void> in
            childChannel = channel

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)
        XCTAssertNotNil(childChannel)

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Call read, the header frame will come through.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Call read again, nothing happens.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Now deliver a data frame.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        // Delivering another data frame does nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReadWithNoPendingDataCausesReadOnParentChannel() throws {
        var childChannel: Channel? = nil
        let readCounter = ReadCounter()
        let frameRecorder = InboundFrameRecorder()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) -> EventLoopFuture<Void> in
            childChannel = channel

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(readCounter).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        self.activateStream(streamID)
        XCTAssertNotNil(childChannel)

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // There should be no calls to read.
        XCTAssertEqual(readCounter.readCount, 0)

        // Call read, the header frame will come through. No calls to read on the parent stream.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCounter.readCount, 0)

        // Call read again, read is called on the parent stream. No frames delivered.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCounter.readCount, 1)

        // Now deliver a data frame.
        var buffer = self.channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("Hello, world!")
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered. No extra call to read.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 1)

        // Another call to read issues a read to the parent stream.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 2)

        // Another call to read, this time does not issue a read to the parent stream.
        childChannel!.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 2)

        // Delivering two more frames does not cause another call to read, and only one frame
        // is delivered.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        XCTAssertEqual(readCounter.readCount, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testHandlersAreRemovedOnClosure() throws {
        var handlerRemoved = false
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in handlerRemoved = true }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.pipeline.addHandler(HandlerRemovedHandler(removedPromise: handlerRemovedPromise))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved)

        // Now we send the channel a clean exit.
        let event = StreamClosedEvent(streamID: streamID, reason: nil)
        self.channel.pipeline.fireUserInboundEventTriggered(event)
        XCTAssertFalse(handlerRemoved)

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testHandlersAreRemovedOnClosureWithError() throws {
        var handlerRemoved = false
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in handlerRemoved = true }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.pipeline.addHandler(HandlerRemovedHandler(removedPromise: handlerRemovedPromise))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders(), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved)

        // Now we send the channel a clean exit.
        let event = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(event)
        XCTAssertFalse(handlerRemoved)

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatingOutboundChannel() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        var createdChannelCount = 0
        var configuredChannelCount = 0
        var streamIDs = Array<HTTP2StreamID>()
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { (channel, streamID) in
                createdChannelCount += 1
                streamIDs.append(streamID)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { _ in
                configuredChannelCount += 1
            }
        }

        XCTAssertEqual(createdChannelCount, 0)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs.count, 0)

        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs, [2, 4, 6].map { HTTP2StreamID($0) })

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 3)
        XCTAssertEqual(streamIDs, [2, 4, 6].map { HTTP2StreamID($0) })

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatingOutboundChannelClient() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        var createdChannelCount = 0
        var configuredChannelCount = 0
        var streamIDs = Array<HTTP2StreamID>()
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { (channel, streamID) in
                createdChannelCount += 1
                streamIDs.append(streamID)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { _ in
                configuredChannelCount += 1
            }
        }

        XCTAssertEqual(createdChannelCount, 0)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs.count, 0)

        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount, 3)
        XCTAssertEqual(configuredChannelCount, 3)
        XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWritesOnCreatedChannelAreDelayed() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()
        var childChannel: Channel? = nil
        var childStreamID: HTTP2StreamID? = nil

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            childChannel = channel
            childStreamID = streamID
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertNotNil(childChannel)
        XCTAssertNotNil(childStreamID)

        childChannel!.writeAndFlush(HTTP2Frame(streamID: childStreamID!, payload: .headers(.init(headers: HPACKHeaders()))), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        configurePromise.succeed(())
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWritesAreCancelledOnFailingInitializer() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        var childChannel: Channel? = nil
        var childStreamID: HTTP2StreamID? = nil

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            childChannel = channel
            childStreamID = streamID
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        var writeError: Error? = nil
        childChannel!.writeAndFlush(HTTP2Frame(streamID: childStreamID!, payload: .headers(.init(headers: HPACKHeaders())))).whenFailure { writeError = $0 }
        XCTAssertNil(writeError)

        configurePromise.fail(MyError())
        XCTAssertNotNil(writeError)
        XCTAssertTrue(writeError is MyError)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testFailingInitializerDoesNotWrite() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        configurePromise.fail(MyError())
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatedChildChannelDoesNotActivateEarly() throws {
        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertFalse(activated)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatedChildChannelActivatesIfParentIsActive() throws {
        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8765)).wait())
        XCTAssertFalse(activated)

        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testInitiatedChildChannelActivates() throws {
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            return channel.pipeline.addHandler(activeRecorder)
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        self.channel.pipeline.fireChannelActive()

        // Open a new stream.
        XCTAssertFalse(activated)
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerIgnoresPriorityFrames() throws {
        self.channel.addNoOpMultiplexer(mode: .server)

        let simplePingFrame = HTTP2Frame(streamID: 106, payload: .priority(.init(exclusive: true, dependency: .rootStream, weight: 15)))
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerForwardsActiveToParent() throws {
        self.channel.addNoOpMultiplexer(mode: .client)

        var didActivate = false

        let activePromise = self.channel.eventLoop.makePromise(of: Void.self)
        activePromise.futureResult.whenSuccess {
            didActivate = true
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(ActiveHandler(activatedPromise: activePromise)).wait())
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/nothing")).wait())
        XCTAssertTrue(didActivate)
        
        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatedChildChannelCanBeClosedImmediately() throws {
        var closed = false

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { (channel, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertFalse(closed)
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            channel.close().whenComplete { _ in closed = true }
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed)
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatedChildChannelCanBeClosedBeforeWritingHeaders() throws {
        var closed = false

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { (channel, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: channelPromise) { (channel, streamID) in
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let child = try assertNoThrowWithValue(channelPromise.futureResult.wait())
        child.closeFuture.whenComplete { _ in closed = true }

        XCTAssertFalse(closed)
        child.close(promise: nil)
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed)
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatedChildChannelCanBeClosedImmediatelyWhenBaseIsActive() throws {
        var closed = false

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { (channel, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertFalse(closed)
        multiplexer.createStreamChannel(promise: nil) { (channel, streamID) in
            channel.close().whenComplete { _ in closed = true }
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed)
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testCreatedChildChannelCanBeClosedBeforeWritingHeadersWhenBaseIsActive() throws {
        var closed = false

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { (channel, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: channelPromise) { (channel, streamID) in
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let child = try assertNoThrowWithValue(channelPromise.futureResult.wait())
        child.closeFuture.whenComplete { _ in closed = true }

        XCTAssertFalse(closed)
        child.close(promise: nil)
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed)
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerCoalescesFlushCallsDuringChannelRead() throws {
        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Add a flush counter.
        let flushCounter = FlushCounter()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(flushCounter).wait())

        // Add a server-mode multiplexer that will add an auto-response handler.
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (channel, _) in
            channel.pipeline.addHandler(QuickResponseHandler())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // We're going to send in 10 request frames.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        XCTAssertEqual(flushCounter.flushCount, 0)

        let framesToSend = stride(from: 1, through: 19, by: 2).map { HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(.init(headers: requestHeaders, endStream: true))) }
        for frame in framesToSend  {
            self.channel.pipeline.fireChannelRead(NIOAny(frame))
        }
        self.channel.embeddedEventLoop.run()

        // Response frames should have been written, but no flushes, so they aren't visible.
        XCTAssertEqual(try self.channel.sentFrames().count, 0)
        XCTAssertEqual(flushCounter.flushCount, 0)

        // Now send channel read complete. The frames should be flushed through.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(try self.channel.sentFrames().count, 10)
        XCTAssertEqual(flushCounter.flushCount, 1)
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerDoesntFireReadCompleteForEachFrame() {
        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let frameRecorder = InboundFrameRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (childChannel, _) in
            return childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 0)

        // Wake up and activate the stream.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        let requestFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: requestHeaders, endStream: false)))
        self.channel.pipeline.fireChannelRead(NIOAny(requestFrame))
        self.activateStream(1)
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 1)

        // Now we're going to send 9 data frames.
        var requestData = self.channel.allocator.buffer(capacity: 1024)
        requestData.writeBytes("Hello world!".utf8)
        let dataFrames = repeatElement(HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(requestData), endStream: false))), count: 9)

        for frame in dataFrames {
            self.channel.pipeline.fireChannelRead(NIOAny(frame))
        }

        // We should have 1 read (the HEADERS), and zero read completes.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 1)

        // Fire read complete on the parent and it'll propagate to the child, also firing the reads..
        self.channel.pipeline.fireChannelReadComplete()

        // We should have 10 reads, and one read complete.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 2)

        // If we fire a new read complete on the parent, the child doesn't see it this time, as it received no frames.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 2)
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerCorrectlyTellsAllStreamsAboutReadComplete() {
        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // These are deliberately getting inserted to all streams. The test above confirms the single-stream
        // behaviour is correct.
        let frameRecorder = InboundFrameRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { (childChannel, _) in
            return childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 0)

        // Wake up and activate the streams.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])

        for streamID in [HTTP2StreamID(1), HTTP2StreamID(3), HTTP2StreamID(5)] {
            let requestFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders, endStream: false)))
            self.channel.pipeline.fireChannelRead(NIOAny(requestFrame))
            self.activateStream(streamID)
        }
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 3)

        // Firing in readComplete does not cause a readComplete, as no new frames were delivered.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 3)

        // Now we're going to send a data frame on stream 1.
        var requestData = self.channel.allocator.buffer(capacity: 1024)
        requestData.writeBytes("Hello world!".utf8)
        let frame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(requestData), endStream: false)))
        self.channel.pipeline.fireChannelRead(NIOAny(frame))

        // We should have 3 reads, and 3 read completes. We don't actually get this frame yet, because
        // we do not do a "fast-delivery" path.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 3)

        // Fire read complete on the parent and it'll propagate to the child, but only to the one
        // that saw a frame.
        self.channel.pipeline.fireChannelReadComplete()

        // We should have 4 reads, and 4 read completes.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 4)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 4)

        // If we fire a new read complete on the parent, the children don't see it.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 4)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 4)
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerModifiesStreamChannelWritabilityBasedOnFixedSizeTokens() throws {
        let multiplexer = HTTP2StreamMultiplexer(mode: .client,
                                                 channel: self.channel,
                                                 outboundBufferSizeHighWatermark: 100,
                                                 outboundBufferSizeLowWatermark: 50) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel, _ in
            return childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        let headersFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers, endStream: false)))

        var dataBuffer = childChannel.allocator.buffer(capacity: 90)
        dataBuffer.writeBytes(repeatElement(0, count: 90))
        let dataFrame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(dataBuffer), endStream: false)))

        childChannel.write(headersFrame, promise: nil)
        childChannel.write(dataFrame, promise: nil)
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write another 20 byte DATA frame (20 bytes). This should flip the channel writability.
        dataBuffer = childChannel.allocator.buffer(capacity: 20)
        dataBuffer.writeBytes(repeatElement(0, count: 20))
        let secondDataFrame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(dataBuffer), endStream: false)))
        childChannel.write(secondDataFrame, promise: nil)

        // Now we're going to send another HEADERS frame (for trailers). This should not affect the channel writability.
        let trailers = HPACKHeaders([])
        let trailersFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: trailers, endStream: true)))
        childChannel.write(trailersFrame, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now we flush the writes. This flips the writability again.
        childChannel.flush()
        XCTAssertTrue(childChannel.isWritable)
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerModifiesStreamChannelWritabilityBasedOnParentChannelWritability() throws {
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: self.channel) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a few new child streams.
        let promises = (0..<5).map { _ in self.channel.eventLoop.makePromise(of: Channel.self) }
        for promise in promises {
            multiplexer.createStreamChannel(promise: promise) { childChannel, _ in
                return childChannel.eventLoop.makeSucceededFuture(())
            }
        }
        self.channel.embeddedEventLoop.run()

        let channels = try assertNoThrowWithValue(promises.map { promise in try promise.futureResult.wait() })

        // These are all writable.
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])

        // Mark the parent channel not writable. This currently changes nothing.
        self.channel.isWritable = false
        self.channel.pipeline.fireChannelWritabilityChanged()
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])

        // Now activate each channel. As we do, we'll see its writability state change.
        for childChannel in channels {
            let streamID = try assertNoThrowWithValue(childChannel.getOption(HTTP2StreamChannelOptions.streamID).wait())
            self.activateStream(streamID)
            XCTAssertFalse(childChannel.isWritable, "Channel \(streamID) is incorrectly writable")
        }

        // All are now non-writable.
        XCTAssertEqual(channels.map { $0.isWritable }, [false, false, false, false, false])

        // And back again.
        self.channel.isWritable = true
        self.channel.pipeline.fireChannelWritabilityChanged()
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testMultiplexerModifiesStreamChannelWritabilityBasedOnFixedSizeTokensAndChannelWritability() throws {
        let multiplexer = HTTP2StreamMultiplexer(mode: .client,
                                                 channel: self.channel,
                                                 outboundBufferSizeHighWatermark: 100,
                                                 outboundBufferSizeLowWatermark: 50) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel, _ in
            return childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        self.activateStream(1)

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        let headersFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: headers, endStream: false)))

        var dataBuffer = childChannel.allocator.buffer(capacity: 90)
        dataBuffer.writeBytes(repeatElement(0, count: 90))
        let dataFrame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(dataBuffer), endStream: false)))

        childChannel.write(headersFrame, promise: nil)
        childChannel.write(dataFrame, promise: nil)
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write another 20 byte DATA frame (20 bytes). This should flip the channel writability.
        dataBuffer = childChannel.allocator.buffer(capacity: 20)
        dataBuffer.writeBytes(repeatElement(0, count: 20))
        let secondDataFrame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(dataBuffer), endStream: false)))
        childChannel.write(secondDataFrame, promise: nil)

        // Now we're going to send another HEADERS frame (for trailers). This should not affect the channel writability.
        let trailers = HPACKHeaders([])
        let trailersFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: trailers, endStream: true)))
        childChannel.write(trailersFrame, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now mark the channel not writable.
        self.channel.isWritable = false
        self.channel.pipeline.fireChannelWritabilityChanged()

        // Now we flush the writes. The channel remains not writable.
        childChannel.flush()
        XCTAssertFalse(childChannel.isWritable)

        // Now we mark the parent channel writable. This flips the writability state.
        self.channel.isWritable = true
        self.channel.pipeline.fireChannelWritabilityChanged()
        XCTAssertTrue(childChannel.isWritable)
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testStreamChannelToleratesFailingInitializer() {
        struct DummyError: Error {}
        let multiplexer = HTTP2StreamMultiplexer(mode: .client,
                                                 channel: self.channel,
                                                 outboundBufferSizeHighWatermark: 100,
                                                 outboundBufferSizeLowWatermark: 50) { (_, _) in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel, _ in
            childChannel.close().flatMap {
                childChannel.eventLoop.makeFailedFuture(DummyError())
            }
        }
        self.channel.embeddedEventLoop.run()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testInboundChannelWindowSizeIsCustomisable() throws {
        let targetWindowSize = 1 << 18

        let multiplexer = HTTP2StreamMultiplexer(mode: .client,
                                                 channel: self.channel,
                                                 targetWindowSize: targetWindowSize) { (channel, streamID) in
            return channel.eventLoop.makeSucceededFuture(())
        }

        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5)).wait())

        // Ok, create an inbound channel.
        let frame = HTTP2Frame(streamID: HTTP2StreamID(1), payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try self.channel.writeInbound(frame))

        // Now claim that the window got consumed. Nothing happens.
        XCTAssertNoThrow(try XCTAssertNil(self.channel.readOutbound(as: HTTP2Frame.self)))
        var windowEvent = NIOHTTP2WindowUpdatedEvent(streamID: 1, inboundWindowSize: (targetWindowSize / 2) + 1, outboundWindowSize: nil)
        channel.pipeline.fireUserInboundEventTriggered(windowEvent)
        XCTAssertNoThrow(try XCTAssertNil(self.channel.readOutbound(as: HTTP2Frame.self)))

        // Consume the last byte.
        windowEvent = NIOHTTP2WindowUpdatedEvent(streamID: 1, inboundWindowSize: (targetWindowSize / 2), outboundWindowSize: nil)
        channel.pipeline.fireUserInboundEventTriggered(windowEvent)
        guard let receivedFrame = try assertNoThrowWithValue(self.channel.readOutbound(as: HTTP2Frame.self)) else {
            XCTFail("No frame received")
            return
        }

        receivedFrame.assertWindowUpdateFrame(streamID: 1, windowIncrement: targetWindowSize / 2)
        XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: false))
    }

    func testMultiplexerFiresInitialFramesInCorrectOrder() throws {
        final class BufferingChannelHandler<Element>: ChannelDuplexHandler {
            typealias InboundIn = Element
            typealias InboundOut = Element
            typealias OutboundIn = Element
            typealias OutboundOut = Element
            
            let elementsToBufferCount: Int = 1
            var bufferedElements: CircularBuffer<Element> = []

            func read(context: ChannelHandlerContext) {
                while let bufferedElement = bufferedElements.popFirst() {
                    context.fireChannelRead(wrapInboundOut(bufferedElement))
                }
                
                context.read()
            }
            
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                bufferedElements.append(unwrapInboundIn(data))
                
                if bufferedElements.count > elementsToBufferCount {
                    context.fireChannelRead(wrapInboundOut(bufferedElements.removeFirst()))
                }
            }
        }
        
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))
        let streamID = HTTP2StreamID(1)
        let headerFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders())))
        let payloadBuffer = channel.allocator.buffer(capacity: 0)
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(payloadBuffer))))
        
        let multiplexer = HTTP2StreamMultiplexer(mode: .server, channel: self.channel) { channel in
            channel.pipeline.addHandler(FramePayloadExpecter(expectedPayload: [headerFrame.payload, dataFrame.payload]))
        }
        
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(BufferingChannelHandler<HTTP2Frame>()).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(multiplexer).wait())

        XCTAssertNoThrow(try self.channel.writeInbound(headerFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        self.activateStream(streamID)
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertNoThrow(try self.channel.finish())
    }
}
