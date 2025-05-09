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

import Atomics
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import NIOHPACK  // for HPACKHeaders initializers
@testable import NIOHTTP2

extension Channel {
    /// Adds a simple no-op ``HTTP2StreamMultiplexer`` to the pipeline.
    fileprivate func addNoOpInlineMultiplexer(mode: NIOHTTP2Handler.ParserMode, eventLoop: EventLoop) {
        XCTAssertNoThrow(
            try self.eventLoop.makeCompletedFuture {
                let handler = NIOHTTP2Handler(
                    mode: mode,
                    eventLoop: eventLoop,
                    inboundStreamInitializer: { channel in
                        self.eventLoop.makeSucceededFuture(())
                    }
                )
                try self.pipeline.syncOperations.addHandler(handler)
            }.wait()
        )
    }
}

private struct MyError: Error {}

typealias IODataWriteRecorder = WriteRecorder<IOData>

extension IODataWriteRecorder {
    func drainConnectionSetupWrites(mode: NIOHTTP2Handler.ParserMode = .server) throws {
        var frameDecoder = HTTP2FrameDecoder(
            allocator: ByteBufferAllocator(),
            expectClientMagic: mode == .client,
            maximumSequentialContinuationFrames: 5
        )

        while self.flushedWrites.count > 0 {
            let write = self.flushedWrites.removeFirst()
            guard case .byteBuffer(let buffer) = write else {
                preconditionFailure("Unexpected write type.")
            }
            frameDecoder.append(bytes: buffer)
        }

        // settings
        guard case .settings = try frameDecoder.nextFrame()!.0.payload else {
            XCTFail("Failed to decode expected settings.")
            return
        }

        if mode == .server {
            // settings ACK
            guard case .settings = try frameDecoder.nextFrame()!.0.payload else {
                XCTFail("Failed to decode expected settings ACK.")
                return
            }
        }
    }
}

extension HPACKHeaders {
    static let basicRequestValues = HPACKHeaders(headers: [
        .init(name: ":path", value: "/"), .init(name: ":method", value: "GET"),
        .init(name: ":scheme", value: "HTTP/2.0"),
    ])
    static let basicResponseValues = HPACKHeaders(headers: [.init(name: ":status", value: "200")])
}

final class HTTP2InlineStreamMultiplexerTests: XCTestCase {
    var channel: EmbeddedChannel!
    let allocator = ByteBufferAllocator()

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        self.channel = nil
    }

    func connectionSetup(mode: NIOHTTP2Handler.ParserMode = .server) throws {
        var frameEncoder = HTTP2FrameEncoder(allocator: channel.allocator)
        var buffer = channel.allocator.buffer(capacity: 1024)

        self.channel.pipeline.connect(to: try .init(unixDomainSocketPath: "/no/such/path"), promise: nil)

        // We'll receive the preamble from the peer, which is normal.
        let newSettings: HTTP2Settings = []
        let settings = HTTP2Frame(streamID: 0, payload: .settings(.settings(newSettings)))

        if mode == .server {
            buffer.writeString("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        }
        XCTAssertNil(try frameEncoder.encode(frame: settings, to: &buffer))
        XCTAssertNil(try frameEncoder.encode(frame: HTTP2Frame(streamID: 0, payload: .settings(.ack)), to: &buffer))
        try channel.writeInbound(buffer)

        // receive settings
        guard case .settings = try self.channel.assertReceivedFrame().payload else {
            preconditionFailure()
        }
        // receive settings ack
        guard case .settings = try self.channel.assertReceivedFrame().payload else {
            preconditionFailure()
        }
    }

    // a ChannelInboundHandler which executes the provided closure on channelRead
    final class TestHookHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = HTTP2Frame.FramePayload
        typealias OutboundOut = HTTP2Frame.FramePayload

        let channelReadHook: @Sendable (ChannelHandlerContext, HTTP2Frame.FramePayload) -> Void

        init(channelReadHook: @escaping @Sendable (ChannelHandlerContext, HTTP2Frame.FramePayload) -> Void) {
            self.channelReadHook = channelReadHook
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let payload = self.unwrapInboundIn(data)
            self.channelReadHook(context, payload)
        }
    }

    func testMultiplexerIgnoresFramesOnStream0() throws {
        self.channel.addNoOpInlineMultiplexer(mode: .server, eventLoop: self.channel.eventLoop)
        XCTAssertNoThrow(try connectionSetup())

        let simplePingFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .ping(HTTP2PingData(withInteger: 5), ack: false)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame.encode()))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHeadersFramesCreateNewChannels() throws {
        let channelCount = ManagedAtomic<Int>(0)
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                return channel.close()
            }
        )

        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a bunch of headers frames.
        for streamID in stride(from: 1, to: 100, by: 2) {
            let frame = HTTP2Frame(
                streamID: HTTP2StreamID(streamID),
                payload: HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues))
            )
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }

        XCTAssertEqual(channelCount.load(ordering: .sequentiallyConsistent), 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseThemselvesWhenToldTo() throws {
        let completedChannelCount = ManagedAtomic<Int>(0)
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channel.closeFuture.whenSuccess {
                    completedChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                }
                return channel.pipeline.addHandler(
                    TestHookHandler { context, payload in
                        guard case .headers(let requestHeaders) = payload else {
                            preconditionFailure("Expected request headers.")
                        }
                        XCTAssertEqual(requestHeaders.headers, .basicRequestValues)

                        let headers = HTTP2Frame.FramePayload.headers(
                            .init(headers: .basicResponseValues, endStream: true)
                        )
                        context.writeAndFlush(NIOAny(headers), promise: nil)
                    }
                )
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a bunch of headers frames with endStream on them. This should open some streams.
        let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues, endStream: true))
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTP2Frame(streamID: streamID, payload: headers).encode()))
        }
        XCTAssertEqual(completedChannelCount.load(ordering: .sequentiallyConsistent), 0)

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage all the promises should be completed.
        XCTAssertEqual(completedChannelCount.load(ordering: .sequentiallyConsistent), 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterResetStreamFrameFirstThenEvent() throws {
        let errorEncounteredHandler = ErrorEncounteredHandler()
        let streamChannelClosed = NIOLockedValueBox(false)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: .basicRequestValues, endStream: true))
        )
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))

        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                try? channel.pipeline.syncOperations.addHandler(errorEncounteredHandler)
                XCTAssertNil(errorEncounteredHandler.encounteredError)
                channel.closeFuture.whenSuccess {
                    streamChannelClosed.withLockedValue { $0 = true }
                }
                return channel.pipeline.addHandler(
                    FramePayloadExpecter(expectedPayload: [frame.payload, rstStreamFrame.payload])
                )
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNil(errorEncounteredHandler.encounteredError)

        // Now we can send a RST_STREAM frame.
        XCTAssertNoThrow(try self.channel.writeInbound(rstStreamFrame.encode()))

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed, the appropriate error code should have been
        // fired down the pipeline.
        streamChannelClosed.withLockedValue { XCTAssertTrue($0) }
        XCTAssertEqual(
            errorEncounteredHandler.encounteredError as? NIOHTTP2Errors.StreamClosed,
            NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel)
        )
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterGoawayFrameFirstThenEvent() throws {
        let errorEncounteredHandler = ErrorEncounteredHandler()
        let streamChannelClosed = NIOLockedValueBox(false)

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: .basicRequestValues, endStream: true))
        )
        let goAwayFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil)
        )

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail()
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup(mode: .client))

        // Let's open the stream up.
        let multiplexer = try http2Handler.multiplexer.wait()
        let streamFuture = multiplexer.createStreamChannel { channel in
            try? channel.pipeline.syncOperations.addHandler(errorEncounteredHandler)
            XCTAssertNil(errorEncounteredHandler.encounteredError)
            channel.closeFuture.whenSuccess {
                streamChannelClosed.withLockedValue { $0 = true }
            }
            return channel.eventLoop.makeSucceededVoidFuture()
        }

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        let stream = try streamFuture.wait()

        stream.writeAndFlush(frame.payload, promise: nil)
        XCTAssertNil(errorEncounteredHandler.encounteredError)

        // Now we can send a GOAWAY frame. This will close the stream.
        XCTAssertNoThrow(try self.channel.writeInbound(goAwayFrame.encode()))

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed, the appropriate error code should have been
        // fired down the pipeline.
        streamChannelClosed.withLockedValue { XCTAssertTrue($0) }
        XCTAssertEqual(
            errorEncounteredHandler.encounteredError as? NIOHTTP2Errors.StreamClosed,
            NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel)
        )
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosingIdleChannels() throws {
        let frameReceiver = IODataWriteRecorder()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channel.close()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        // Let's send a bunch of headers frames. These will all be answered by RST_STREAM frames.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }

        let expectedFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .rstStream(.cancel)) }
        XCTAssertEqual(expectedFrames.count, frameReceiver.flushedWrites.count)

        var frameDecoder = HTTP2FrameDecoder(
            allocator: channel.allocator,
            expectClientMagic: false,
            maximumSequentialContinuationFrames: 5
        )
        for (idx, expectedFrame) in expectedFrames.enumerated() {
            if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[idx] {
                frameDecoder.append(bytes: flushedWriteBuffer)
            }
            let (actualFrame, _) = try frameDecoder.nextFrame()!
            expectedFrame.assertFrameMatches(this: actualFrame)
        }
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosingActiveChannels() throws {
        let frameReceiver = IODataWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelPromise.succeed(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame.
        childChannel.close(promise: nil)
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(
            allocator: channel.allocator,
            expectClientMagic: false,
            maximumSequentialContinuationFrames: 5
        )
        if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosePromiseIsSatisfied() throws {
        let frameReceiver = IODataWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelPromise.succeed(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        let closed = ManagedAtomic<Bool>(false)
        childChannel.close().whenComplete { _ in closed.store(true, ordering: .sequentiallyConsistent) }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(
            allocator: channel.allocator,
            expectClientMagic: false,
            maximumSequentialContinuationFrames: 5
        )
        if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
    }

    func testMultipleClosePromisesAreSatisfied() throws {
        let frameReceiver = IODataWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelPromise.succeed(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it several times. This triggers one RST_STREAM frame. The channel will not be closed at this time.
        let firstClosed = ManagedAtomic<Bool>(false)
        let secondClosed = ManagedAtomic<Bool>(false)
        let thirdClosed = ManagedAtomic<Bool>(false)
        childChannel.close().whenComplete { _ in
            XCTAssertFalse(firstClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(secondClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(thirdClosed.load(ordering: .sequentiallyConsistent))
            firstClosed.store(true, ordering: .sequentiallyConsistent)
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(secondClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(thirdClosed.load(ordering: .sequentiallyConsistent))
            secondClosed.store(true, ordering: .sequentiallyConsistent)
        }
        childChannel.close().whenComplete { _ in
            XCTAssertTrue(firstClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertTrue(secondClosed.load(ordering: .sequentiallyConsistent))
            XCTAssertFalse(thirdClosed.load(ordering: .sequentiallyConsistent))
            thirdClosed.store(true, ordering: .sequentiallyConsistent)
        }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(
            allocator: channel.allocator,
            expectClientMagic: false,
            maximumSequentialContinuationFrames: 5
        )
        if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertTrue(thirdClosed.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosePromiseSucceedsAndErrorIsFiredDownstream() throws {
        let frameReceiver = IODataWriteRecorder()
        let errorEncounteredHandler = ErrorEncounteredHandler()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelPromise.succeed(channel)
                try? channel.pipeline.syncOperations.addHandler(errorEncounteredHandler)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame.
        // Make sure the closeFuture is not failed (closing still succeeds).
        // The promise from calling close() should fail to provide the caller with diagnostics.
        childChannel.closeFuture.whenFailure { _ in
            XCTFail("The close promise should not be failed.")
        }
        childChannel.close().whenComplete { result in
            switch result {
            case .success:
                XCTFail("The close promise should have been failed.")
            case .failure(let error):
                XCTAssertTrue(error is NIOHTTP2Errors.StreamClosed)
            }
        }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)

        var frameDecoder = HTTP2FrameDecoder(
            allocator: channel.allocator,
            expectClientMagic: false,
            maximumSequentialContinuationFrames: 5
        )
        if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertEqual(
            errorEncounteredHandler.encounteredError as? NIOHTTP2Errors.StreamClosed,
            NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel)
        )

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesAreNotDeliveredUntilStreamIsSetUp() throws {
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelPromise.succeed(channel)
                return channel.pipeline.addHandler(InboundFramePayloadRecorder()).flatMap {
                    setupCompletePromise.futureResult
                }
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).wait()
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Send a few data frames for this stream, which should also not go through.
        let dataFrame = HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))
        )
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame.encode()))
        }
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Use a PING frame to check that the channel is still functioning.
        let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        XCTAssertNoThrow(try self.channel.writeInbound(ping.encode()))
        try self.channel.assertReceivedFrame().assertPingFrameMatches(this: ping)
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, complete the setup promise. This should trigger all the frames to be delivered.
        setupCompletePromise.succeed(())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertHeadersFramePayloadMatches(this: frame.payload)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFramePayloadMatches(this: dataFrame.payload)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesAreNotDeliveredIfSetUpFails() throws {
        let writeRecorder = IODataWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelPromise.succeed(channel)
                return channel.pipeline.addHandler(InboundFramePayloadRecorder()).flatMap {
                    setupCompletePromise.futureResult
                }
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        try writeRecorder.drainConnectionSetupWrites()

        // Let's send a headers frame to open the stream, along with some DATA frames.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        let dataFrame = try HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))
        ).encode()
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).wait()
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Ok, fail the setup promise. This should deliver a RST_STREAM frame, but not yet close the channel.
        // The channel should, however, be inactive.
        let channelClosed = ManagedAtomic<Bool>(false)
        childChannel.closeFuture.whenComplete { _ in channelClosed.store(true, ordering: .sequentiallyConsistent) }
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)
        XCTAssertFalse(channelClosed.load(ordering: .sequentiallyConsistent))

        setupCompletePromise.fail(MyError())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(
            allocator: channel.allocator,
            expectClientMagic: false,
            maximumSequentialContinuationFrames: 5
        )
        if case .byteBuffer(let flushedWriteBuffer) = writeRecorder.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)

        // Even delivering a new DATA frame should do nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        XCTAssertFalse(channelClosed.load(ordering: .sequentiallyConsistent))

        (childChannel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(channelClosed.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testFlushingOneChannelDoesntFlushThemAll() async throws {
        let writeTracker = IODataWriteRecorder()
        let (channelsStream, channelsContinuation) = AsyncStream.makeStream(of: Channel.self)
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channelsContinuation.yield(channel)
                return channel.eventLoop.makeSucceededFuture(())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeTracker).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        try writeTracker.drainConnectionSetupWrites()

        // Let's open two streams.
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(
                streamID: streamID,
                payload: .headers(.init(headers: .basicRequestValues, endStream: true))
            )
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }

        var streamChannelIterator = channelsStream.makeAsyncIterator()
        let firstStreamChannel = await streamChannelIterator.next()!
        let secondStreamChannel = await streamChannelIterator.next()!

        // We will now write a headers frame to each channel. Neither frame should be written to the connection. To verify this
        // we will flush the parent channel.
        for channel in [firstStreamChannel, secondStreamChannel] {
            let frame = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseValues))
            channel.write(frame, promise: nil)
        }
        self.channel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 0)

        // Now we're going to flush only the first child channel. This should cause one flushed write.
        firstStreamChannel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 1)

        // Now the other.
        secondStreamChannel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testUnflushedWritesFailOnError() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                childChannelPromise.succeed(channel)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: .basicRequestValues, endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNotNil(channel)
        let childChannel = try childChannelPromise.futureResult.wait()

        // We will now write a headers frame to the channel, but don't flush it.
        let writeError = NIOLockedValueBox<Error?>(nil)
        let responseFrame = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseValues))
        childChannel.write(responseFrame).whenFailure { error in
            writeError.withLockedValue { writeError in
                writeError = error
            }
        }
        writeError.withLockedValue { writeError in
            XCTAssertNil(writeError)
        }

        // write a reset stream frame to close stream
        let resetFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))
        XCTAssertNoThrow(try self.channel.writeInbound(resetFrame.encode()))

        writeError.withLockedValue { writeError in
            XCTAssertNotNil(writeError)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesFailOnClosedStreamChannels() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                childChannelPromise.succeed(channel)
                return channel.pipeline.addHandler(
                    TestHookHandler { context, payload in
                        guard case .headers(let requestHeaders) = payload else {
                            preconditionFailure("Expected request headers.")
                        }
                        XCTAssertEqual(requestHeaders.headers, .basicRequestValues)

                        let headers = HTTP2Frame.FramePayload.headers(
                            .init(headers: .basicResponseValues, endStream: true)
                        )
                        context.writeAndFlush(NIOAny(headers), promise: nil)
                    }
                )
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: .basicRequestValues, endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNotNil(channel)

        let childChannel = try childChannelPromise.futureResult.wait()

        // We will now write a headers frame to the channel. This should fail immediately.
        let writeError = NIOLockedValueBox<Error?>(nil)
        let responseFrame = HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues))
        childChannel.write(responseFrame).whenFailure { error in
            writeError.withLockedValue { writeError in
                writeError = error
            }
        }
        writeError.withLockedValue { writeError in
            XCTAssertEqual(writeError as? ChannelError, ChannelError.ioOnClosedChannel)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadPullsInAllFrames() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let frameRecorder = InboundFramePayloadRecorder()
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel -> EventLoopFuture<Void> in
                childChannelPromise.succeed(channel)

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
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        let childChannel = try childChannelPromise.futureResult.wait()

        // Now we're going to deliver 5 data frames for this stream.
        let payloadBuffer = ByteBuffer(string: "Hello, world!")
        let dataFrame = try HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(payloadBuffer))))
            .encode()
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // These frames should not have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // We'll call read() on the child channel.
        childChannel.read()

        // All frames should now have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 6)
        frameRecorder.receivedFrames[0].assertFramePayloadMatches(this: frame.payload)
        for idx in 1...5 {
            frameRecorder.receivedFrames[idx].assertDataFramePayload(endStream: false, payload: payloadBuffer)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadIsPerChannel() throws {
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)

        // We don't have access to the streamID in the inbound stream initializer; we have to track
        // the expected ID here.
        let autoRead = ManagedAtomic<Bool>(false)
        let frameRecorders = NIOLockedValueBox<[HTTP2StreamID: InboundFramePayloadRecorder]>([:])

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) {
            channel -> EventLoopFuture<Void> in
            let recorder = InboundFramePayloadRecorder()
            frameRecorders.withLockedValue { frameRecorders in
                let expectedStreamID = frameRecorders.count * 2 + 1
                frameRecorders[HTTP2StreamID(expectedStreamID)] = recorder
            }

            // We'll disable auto read on the first channel only.
            let autoReadValue = autoRead.load(ordering: .sequentiallyConsistent)
            autoRead.store(true, ordering: .sequentiallyConsistent)

            return channel.setOption(ChannelOptions.autoRead, value: autoReadValue).flatMap {
                channel.pipeline.addHandler(recorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open two streams.
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }

        frameRecorders.withLockedValue { frameRecorders in
            XCTAssertEqual(frameRecorders.count, 2)
            // Stream 1 should not have received a frame, stream 3 should.
            XCTAssertEqual(frameRecorders[firstStreamID]!.receivedFrames.count, 0)
            XCTAssertEqual(frameRecorders[secondStreamID]!.receivedFrames.count, 1)
        }

        // Deliver a DATA frame to each stream, which should also have gone into stream 3 but not stream 1.
        let payloadBuffer = ByteBuffer(string: "Hello, world!")
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(payloadBuffer))))
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }

        frameRecorders.withLockedValue { frameRecorders in
            // Stream 1 should not have received a frame, stream 3 should.
            XCTAssertEqual(frameRecorders[firstStreamID]!.receivedFrames.count, 0)
            XCTAssertEqual(frameRecorders[secondStreamID]!.receivedFrames.count, 2)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadWillCauseAutomaticFrameDelivery() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let frameRecorder = InboundFramePayloadRecorder()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) {
            channel -> EventLoopFuture<Void> in
            childChannelPromise.succeed(channel)

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        let childChannel = try childChannelPromise.futureResult.wait()

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Call read, the header frame will come through.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Call read again, nothing happens.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Now deliver a data frame.
        let dataFrame = try HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))
        ).encode()
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        // Delivering another data frame does nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadWithNoPendingDataCausesReadOnParentChannel() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let readCounter = ReadCounter()
        let frameRecorder = InboundFramePayloadRecorder()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) {
            channel -> EventLoopFuture<Void> in
            childChannelPromise.succeed(channel)

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(readCounter).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        let childChannel = try childChannelPromise.futureResult.wait()

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // There should be no calls to read.
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 0)
        }

        // Call read, the header frame will come through. No calls to read on the parent stream.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 0)
        }

        // Call read again, read is called on the parent stream. No frames delivered.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 1)
        }

        // Now deliver a data frame.
        let dataFrame = try HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))
        ).encode()
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered. No extra call to read.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 1)
        }

        // Another call to read issues a read to the parent stream.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        // Another call to read, this time does not issue a read to the parent stream.
        childChannel.read()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        // Delivering two more frames does not cause another call to read, and only one frame
        // is delivered.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHandlersAreRemovedOnClosure() throws {
        let handlerRemoved = ManagedAtomic<Bool>(false)
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in
            handlerRemoved.store(true, ordering: .sequentiallyConsistent)
        }

        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channel.pipeline.addHandlers([
                    HandlerRemovedHandler(removedPromise: handlerRemovedPromise),
                    TestHookHandler { context, payload in
                        guard case .headers(let requestHeaders) = payload else {
                            preconditionFailure("Expected request headers.")
                        }
                        XCTAssertEqual(requestHeaders.headers, .basicRequestValues)

                        let headers = HTTP2Frame.FramePayload.headers(
                            .init(headers: .basicResponseValues, endStream: true)
                        )
                        context.writeAndFlush(NIOAny(headers), promise: nil)
                    },
                ])
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: .basicRequestValues, endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved.load(ordering: .sequentiallyConsistent))

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHandlersAreRemovedOnClosureWithError() throws {
        let handlerRemoved = ManagedAtomic<Bool>(false)
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in
            handlerRemoved.store(true, ordering: .sequentiallyConsistent)
        }

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channel.pipeline.addHandlers([
                HandlerRemovedHandler(removedPromise: handlerRemovedPromise),
                TestHookHandler { context, payload in
                    guard case .headers(let requestHeaders) = payload else {
                        preconditionFailure("Expected request headers.")
                    }
                    XCTAssertEqual(requestHeaders.headers, .basicRequestValues)

                    let headers = HTTP2Frame.FramePayload.headers(
                        .init(headers: .basicResponseValues, endStream: true)
                    )
                    context.writeAndFlush(NIOAny(headers), promise: nil)
                },
            ])
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: .basicRequestValues, endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved.load(ordering: .sequentiallyConsistent))

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatingOutboundChannelClient() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let createdChannelCount = ManagedAtomic<Int>(0)
        let configuredChannelCount = ManagedAtomic<Int>(0)
        let streamIDs = NIOLockedValueBox([HTTP2StreamID]())
        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        // to make the channel active
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let multiplexer = try http2Handler.multiplexer.wait()
        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { channel in
                createdChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { channel in
                configuredChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                // Write some headers: the flush will trigger a stream ID to be assigned to the channel.
                channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues))).whenSuccess
                {
                    channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { streamID in
                        streamIDs.withLockedValue { streamIDs in
                            streamIDs.append(streamID)
                        }
                    }
                }
            }
        }

        // Run the loop to create the channels.
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 0)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs.count, 0)
        }

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 3)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesOnCreatedChannelAreDelayed() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = IODataWriteRecorder()
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        try writeRecorder.drainConnectionSetupWrites(mode: .client)

        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannelPromise.succeed(channel)
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        let childChannel = try childChannelPromise.futureResult.wait()

        childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues)), promise: nil)

        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        configurePromise.succeed(())
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesAreCancelledOnFailingInitializer() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)

        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannelPromise.succeed(channel)
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        let childChannel = try childChannelPromise.futureResult.wait()

        let writeError = NIOLockedValueBox<Error?>(nil)
        childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues))).whenFailure {
            error in
            writeError.withLockedValue { writeError in
                writeError = error
            }
        }
        writeError.withLockedValue { writeError in
            XCTAssertNil(writeError)
        }

        configurePromise.fail(MyError())
        writeError.withLockedValue { writeError in
            XCTAssertNotNil(writeError)
            XCTAssertTrue(writeError is MyError)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFailingInitializerDoesNotWrite() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()

        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        configurePromise.fail(MyError())
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelDoesNotActivateEarly() throws {
        let activated = ManagedAtomic<Bool>(false)

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        activePromise.futureResult.map {
            activated.store(true, ordering: .sequentiallyConsistent)
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            let activeRecorder = ActiveHandler(activatedPromise: activePromise)
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertFalse(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelActivatesIfParentIsActive() throws {
        let activated = ManagedAtomic<Bool>(false)

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        activePromise.futureResult.map {
            activated.store(true, ordering: .sequentiallyConsistent)
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8765)).wait())
        XCTAssertFalse(activated.load(ordering: .sequentiallyConsistent))

        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            let activeRecorder = ActiveHandler(activatedPromise: activePromise)
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testInitiatedChildChannelActivates() throws {
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let activated = ManagedAtomic<Bool>(false)

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        activePromise.futureResult.map {
            activated.store(true, ordering: .sequentiallyConsistent)
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                let activeRecorder = ActiveHandler(activatedPromise: activePromise)
                return channel.pipeline.addHandler(activeRecorder)
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())
        self.channel.pipeline.fireChannelActive()

        // Open a new stream.
        XCTAssertFalse(activated.load(ordering: .sequentiallyConsistent))
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultiplexerIgnoresPriorityFrames() throws {
        self.channel.addNoOpInlineMultiplexer(mode: .server, eventLoop: self.channel.eventLoop)
        XCTAssertNoThrow(try connectionSetup())

        let simplePingFrame = HTTP2Frame(
            streamID: 106,
            payload: .priority(.init(exclusive: true, dependency: .rootStream, weight: 15))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame.encode()))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultiplexerForwardsActiveToParent() throws {
        self.channel.addNoOpInlineMultiplexer(mode: .client, eventLoop: self.channel.eventLoop)

        let activated = ManagedAtomic<Bool>(false)

        let activePromise = self.channel.eventLoop.makePromise(of: Void.self)
        activePromise.futureResult.whenSuccess {
            activated.store(true, ordering: .sequentiallyConsistent)
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(ActiveHandler(activatedPromise: activePromise)).wait())
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/nothing")).wait())
        XCTAssertTrue(activated.load(ordering: .sequentiallyConsistent))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelCanBeClosedImmediately() throws {
        let closed = ManagedAtomic<Bool>(false)

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            channel.close().whenComplete { _ in closed.store(true, ordering: .sequentiallyConsistent) }
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testCreatedChildChannelCanBeClosedBeforeWritingHeaders() throws {
        let closed = ManagedAtomic<Bool>(false)

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: channelPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let child = try assertNoThrowWithValue(channelPromise.futureResult.wait())
        child.closeFuture.whenComplete { _ in
            closed.store(true, ordering: .sequentiallyConsistent)
        }

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        child.close(promise: nil)
        self.channel.embeddedEventLoop.run()
        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testCreatedChildChannelCanBeClosedImmediatelyWhenBaseIsActive() throws {
        let closed = ManagedAtomic<Bool>(false)

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertEqual(try self.channel.readAllBuffers().count, 2)  // magic & settings

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            channel.close().whenComplete { _ in closed.store(true, ordering: .sequentiallyConsistent) }
            return channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testCreatedChildChannelCanBeClosedBeforeWritingHeadersWhenBaseIsActive() throws {
        let closed = ManagedAtomic<Bool>(false)

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertEqual(try self.channel.readAllBuffers().count, 2)  // magic & settings

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: channelPromise) { channel in
            channel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let child = try assertNoThrowWithValue(channelPromise.futureResult.wait())
        child.closeFuture.whenComplete { _ in
            closed.store(true, ordering: .sequentiallyConsistent)
        }

        XCTAssertFalse(closed.load(ordering: .sequentiallyConsistent))
        child.close(promise: nil)
        self.channel.embeddedEventLoop.run()

        XCTAssertTrue(closed.load(ordering: .sequentiallyConsistent))
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testMultiplexerCoalescesFlushCallsDuringChannelRead() throws {
        // Add a flush counter.
        let flushCounter = FlushCounter()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(flushCounter).wait())

        // Add a server-mode multiplexer that will add an auto-response handler.
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channel.pipeline.addHandler(QuickFramePayloadResponseHandler())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // We're going to send in 10 request frames.
        let requestHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        XCTAssertEqual(flushCounter.flushCount, 2)  // two flushes in connection setup

        let framesToSend = stride(from: 1, through: 19, by: 2).map {
            HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(.init(headers: requestHeaders, endStream: true)))
        }
        for frame in framesToSend {
            self.channel.pipeline.fireChannelRead(try frame.encode())
        }
        self.channel.embeddedEventLoop.run()

        // Response frames should have been written, but no flushes, so they aren't visible.
        XCTAssertEqual(try self.channel.decodedSentFrames().count, 2)  // 2 for handler setup
        XCTAssertEqual(flushCounter.flushCount, 2)  // 2 for handler setup

        // Now send channel read complete. The frames should be flushed through.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(try self.channel.decodedSentFrames().count, 10)
        XCTAssertEqual(flushCounter.flushCount, 3)
    }

    func testMultiplexerDoesntFireReadCompleteForEachFrame() throws {
        let frameRecorder = InboundFramePayloadRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { childChannel in
            childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 0)
        }

        // Wake up and activate the stream.
        let requestHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let requestFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: requestHeaders, endStream: false)))
        XCTAssertNoThrow(self.channel.pipeline.fireChannelRead(try requestFrame.encode()))
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 1)
        }

        // Now we're going to send 9 data frames.
        let dataFrame = try HTTP2Frame(
            streamID: 1,
            payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))
        ).encode()
        for _ in 0..<9 {
            self.channel.pipeline.fireChannelRead(dataFrame)
        }

        // We should have 1 read (the HEADERS), and one read complete.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 1)
        }

        // Fire read complete on the parent and it'll propagate to the child. This will trigger the reads.
        self.channel.pipeline.fireChannelReadComplete()

        // We should have 10 reads, and two read completes.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 2)
        }

        // If we fire a new read complete on the parent, the child doesn't see it this time, as it received no frames.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 2)
        }
    }

    func testMultiplexerCorrectlyTellsAllStreamsAboutReadComplete() throws {
        // These are deliberately getting inserted to all streams. The test above confirms the single-stream
        // behaviour is correct.
        let frameRecorder = InboundFramePayloadRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { childChannel in
            childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 0)
        }

        // Wake up and activate the streams.
        let requestHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        for streamID in [HTTP2StreamID(1), HTTP2StreamID(3), HTTP2StreamID(5)] {
            let requestFrame = HTTP2Frame(
                streamID: streamID,
                payload: .headers(.init(headers: requestHeaders, endStream: false))
            )
            try self.channel.pipeline.fireChannelRead(requestFrame.encode())
        }
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 3)
        }

        // Firing in readComplete does not cause a second readComplete for each stream, as no frames were delivered.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 3)
        }

        // Now we're going to send a data frame on stream 1.
        let dataFrame = HTTP2Frame(
            streamID: 1,
            payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))
        )
        self.channel.pipeline.fireChannelRead(try dataFrame.encode())

        // We should have 3 reads, and 3 read completes. The frame is not delivered as we have no frame fast-path.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 3)
        }

        // Fire read complete on the parent and it'll propagate to the child, but only to the one
        // that saw a frame.
        self.channel.pipeline.fireChannelReadComplete()

        // We should have 4 reads, and 4 read completes.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 4)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 4)
        }

        // If we fire a new read complete on the parent, the children don't see it.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 4)
        readCompleteCounter.readCompleteCount.withLockedValue { readCompleteCount in
            XCTAssertEqual(readCompleteCount, 4)
        }
    }

    func testMultiplexerModifiesStreamChannelWritabilityBasedOnFixedSizeTokens() throws {
        var streamConfiguration = NIOHTTP2Handler.StreamConfiguration()
        streamConfiguration.outboundBufferSizeHighWatermark = 100
        streamConfiguration.outboundBufferSizeLowWatermark = 50
        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            streamConfiguration: streamConfiguration,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))

        var dataBuffer = childChannel.allocator.buffer(capacity: 90)
        dataBuffer.writeBytes(repeatElement(0, count: 90))
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(headersPayload, promise: nil)
        childChannel.write(dataPayload, promise: nil)
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write another 20 byte DATA frame (20 bytes). This should flip the channel writability.
        dataBuffer = childChannel.allocator.buffer(capacity: 20)
        dataBuffer.writeBytes(repeatElement(0, count: 20))
        let secondDataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(secondDataPayload, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now we're going to send another HEADERS frame (for trailers). This should not affect the channel writability.
        let trailers = HPACKHeaders([])
        let trailersFrame = HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true))
        childChannel.write(trailersFrame, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now we flush the writes. This flips the writability again.
        childChannel.flush()
        XCTAssertTrue(childChannel.isWritable)
    }

    func testMultiplexerModifiesStreamChannelWritabilityBasedOnParentChannelWritability() throws {

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a few new child streams.
        let promises = (0..<5).map { _ in self.channel.eventLoop.makePromise(of: Channel.self) }
        for promise in promises {
            let multiplexer = try http2Handler.multiplexer.wait()
            multiplexer.createStreamChannel(promise: promise) { childChannel in
                childChannel.eventLoop.makeSucceededFuture(())
            }
        }
        self.channel.embeddedEventLoop.run()

        let channels = try assertNoThrowWithValue(promises.map { promise in try promise.futureResult.wait() })

        // These are all writable.
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])

        // We need to write (and flush) some data so that the streams get stream IDs.
        for childChannel in channels {
            XCTAssertNoThrow(
                try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues)))
                    .wait()
            )
        }

        // Mark the parent channel not writable. This currently changes nothing.
        self.channel.isWritable = false
        self.channel.pipeline.fireChannelWritabilityChanged()

        // All are now non-writable.
        XCTAssertEqual(channels.map { $0.isWritable }, [false, false, false, false, false])

        // And back again.
        self.channel.isWritable = true
        self.channel.pipeline.fireChannelWritabilityChanged()
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])
    }

    func testMultiplexerModifiesStreamChannelWritabilityBasedOnFixedSizeTokensAndChannelWritability() throws {
        var streamConfiguration = NIOHTTP2Handler.StreamConfiguration()
        streamConfiguration.outboundBufferSizeHighWatermark = 100
        streamConfiguration.outboundBufferSizeLowWatermark = 50
        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            streamConfiguration: streamConfiguration,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        // We need to write (and flush) some data so that the streams get stream IDs.
        XCTAssertNoThrow(
            try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues))).wait()
        )

        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"),
        ])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))

        var dataBuffer = childChannel.allocator.buffer(capacity: 90)
        dataBuffer.writeBytes(repeatElement(0, count: 90))
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(headersPayload, promise: nil)
        childChannel.write(dataPayload, promise: nil)
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write another 20 byte DATA frame (20 bytes). This should flip the channel writability.
        dataBuffer = childChannel.allocator.buffer(capacity: 20)
        dataBuffer.writeBytes(repeatElement(0, count: 20))
        let secondDataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(dataBuffer), endStream: false))

        childChannel.write(secondDataPayload, promise: nil)
        XCTAssertFalse(childChannel.isWritable)

        // Now we're going to send another HEADERS frame (for trailers). This should not affect the channel writability.
        let trailers = HPACKHeaders([])
        let trailersPayload = HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true))
        childChannel.write(trailersPayload, promise: nil)
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

    func testStreamChannelToleratesFailingInitializer() throws {
        struct DummyError: Error {}
        var streamConfiguration = NIOHTTP2Handler.StreamConfiguration()
        streamConfiguration.outboundBufferSizeHighWatermark = 100
        streamConfiguration.outboundBufferSizeLowWatermark = 50
        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            streamConfiguration: streamConfiguration,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            childChannel.close().flatMap {
                childChannel.eventLoop.makeFailedFuture(DummyError())
            }
        }
        self.channel.embeddedEventLoop.run()
    }

    func testReadWhenUsingAutoreadOnChildChannel() throws {
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let readCounter = ReadCounter()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) {
            channel -> EventLoopFuture<Void> in
            childChannelPromise.succeed(channel)

            // We're going to _enable_ autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: true).flatMap {
                channel.pipeline.addHandler(readCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        let _ = try childChannelPromise.futureResult.wait()  // just ensure that the initializer ran

        // There should be two calls to read: the first, when the stream was activated, the second after the HEADERS
        // frame was delivered.
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 2)
        }

        // Now deliver a data frame.
        let dataFrame = try HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))
        ).encode()
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered, _and_ a call to read should have happened.
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 3)
        }

        // Delivering two more frames causes two more calls to read.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        readCounter.readCount.withLockedValue { readCount in
            XCTAssertEqual(readCount, 5)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testStreamChannelSupportsSyncOptions() throws {
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTAssert(channel is HTTP2StreamChannel)
                if let sync = channel.syncOptions {
                    do {
                        let streamID = try sync.getOption(HTTP2StreamChannelOptions.streamID)
                        XCTAssertEqual(streamID, HTTP2StreamID(1))

                        let autoRead = try sync.getOption(ChannelOptions.autoRead)
                        try sync.setOption(ChannelOptions.autoRead, value: !autoRead)
                        XCTAssertNotEqual(autoRead, try sync.getOption(ChannelOptions.autoRead))
                    } catch {
                        XCTFail("Missing StreamID")
                    }
                } else {
                    XCTFail("syncOptions was nil but should be supported for HTTP2StreamChannel")
                }

                return channel.close()
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        let frame = HTTP2Frame(streamID: HTTP2StreamID(1), payload: .headers(.init(headers: .basicRequestValues)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
    }

    func testStreamErrorIsDeliveredToChannel() throws {
        let goodHeaders = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])
        var badHeaders = goodHeaders
        badHeaders.add(name: "transfer-encoding", value: "chunked")

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                channel.eventLoop.makeSucceededFuture(())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup(mode: .client))
        XCTAssertEqual(try self.channel.readAllBuffers().count, 3)  // drain outbound magic, settings & ACK

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now create two child channels with error recording handlers in them. Save one, ignore the other.
        let firstChildChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            firstChildChannelPromise.succeed(channel)
            return channel.pipeline.addHandler(ErrorRecorder())
        }

        let secondChildChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: nil) { channel in
            secondChildChannelPromise.succeed(channel)
            // For this one we'll do a write immediately, to bring it into existence and give it a stream ID.
            channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: goodHeaders)), promise: nil)
            return channel.pipeline.addHandler(ErrorRecorder())
        }
        self.channel.embeddedEventLoop.run()

        let firstChildChannel = try firstChildChannelPromise.futureResult.wait()
        let secondChildChannel = try secondChildChannelPromise.futureResult.wait()

        // On this child channel, write and flush an invalid headers frame.
        _ = firstChildChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(errors.count, 0)
            }
        }
        _ = secondChildChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(errors.count, 0)
            }
        }

        firstChildChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: badHeaders)), promise: nil)

        // It should come through to the channel.
        _ = firstChildChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(
                    errors.first.flatMap { $0 as? NIOHTTP2Errors.ForbiddenHeaderField },
                    NIOHTTP2Errors.forbiddenHeaderField(name: "transfer-encoding", value: "chunked")
                )
            }
        }

        _ = secondChildChannel.pipeline.handler(type: ErrorRecorder.self).map { errorRecorder in
            errorRecorder.errors.withLockedValue { errors in
                XCTAssertEqual(errors.count, 0)
            }
        }

        // Simulate closing the child channel in response to the error.
        firstChildChannel.close(promise: nil)
        self.channel.embeddedEventLoop.run()

        // Only the HEADERS frames should have been written: we closed before the other channel became active, so
        // it should not have triggered an RST_STREAM frame.
        let frames = try self.channel.decodedSentFrames()
        XCTAssertEqual(frames.count, 1)

        frames[0].assertHeadersFrame(endStream: false, streamID: 1, headers: goodHeaders, priority: nil, type: .request)
    }

    func testPendingReadsAreFlushedEvenWithoutUnsatisfiedReadOnChannelInactive() throws {
        let goodHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost"),
        ])

        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            inboundStreamInitializer: { channel in
                XCTFail("Server push is unexpected")
                return channel.eventLoop.makeSucceededFuture(())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup(mode: .client))
        XCTAssertEqual(try self.channel.readAllBuffers().count, 3)  // drain outbound magic, settings & ACK

        // Now create and save a child channel with an error recording handler in it.x
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: childChannelPromise) { channel in
            channel.eventLoop.makeCompletedFuture {
                let consumer = ReadAndFrameConsumer()
                return try channel.pipeline.syncOperations.addHandler(consumer)
            }
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try childChannelPromise.futureResult.wait()

        let streamID = HTTP2StreamID(1)

        let payload = HTTP2Frame.FramePayload.Headers(headers: goodHeaders, endStream: true)

        XCTAssertNoThrow(try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(payload)).wait())

        let frames = try self.channel.decodedSentFrames()
        XCTAssertEqual(frames.count, 1)
        frames.first?.assertHeadersFrameMatches(this: HTTP2Frame(streamID: streamID, payload: .headers(payload)))

        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).map { consumer in
            XCTAssertEqual(consumer.readCount, 1)
        }.wait()

        // 1. pass header onwards

        let responseHeaderFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: [":status": "200"])))
        XCTAssertNoThrow(try self.channel.writeInbound(responseHeaderFrame.encode()))
        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).map { consumer in
            XCTAssertEqual(consumer.receivedFrames.count, 1)
            XCTAssertEqual(consumer.readCompleteCount, 1)
            XCTAssertEqual(consumer.readCount, 2)

            consumer.forwardRead = false
        }.wait()

        // 2. pass body onwards

        let responseFrame1 = HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(.init(string: "foo"))))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(responseFrame1.encode()))

        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).map { consumer in
            XCTAssertEqual(consumer.receivedFrames.count, 2)
            XCTAssertEqual(consumer.readCompleteCount, 2)
            XCTAssertEqual(consumer.readCount, 3)
            XCTAssertEqual(consumer.readPending, true)
        }.wait()

        // 3. pass on more body - should not change a thing, since read is pending in consumer

        let responseFrame2 = HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(.init(string: "bar")), endStream: false))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(responseFrame2.encode()))

        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).map { consumer in
            XCTAssertEqual(consumer.receivedFrames.count, 2)
            XCTAssertEqual(consumer.readCompleteCount, 2)
            XCTAssertEqual(consumer.readCount, 3)
            XCTAssertEqual(consumer.readPending, true)
        }.wait()

        // 4. signal stream is closed – this should force forward all pending frames

        let responseFrame3 = HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(.init(string: "bar")), endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(responseFrame3.encode()))

        try childChannel.pipeline.handler(type: ReadAndFrameConsumer.self).map { consumer in
            XCTAssertEqual(consumer.receivedFrames.count, 4)
            XCTAssertEqual(consumer.readCompleteCount, 3)
            XCTAssertEqual(consumer.readCount, 3)
            XCTAssertEqual(consumer.channelInactiveCount, 1)
            XCTAssertEqual(consumer.readPending, true)
        }.wait()
    }

    fileprivate struct CountingStreamDelegate: NIOHTTP2StreamDelegate {
        private let store = NIOLockedValueBox<Store>(Store())

        func streamCreated(_ id: NIOHTTP2.HTTP2StreamID, channel: NIOCore.Channel) {
            self.store.withLockedValue { store in
                store.created += 1
                store.open += 1
            }
        }

        func streamClosed(_ id: NIOHTTP2.HTTP2StreamID, channel: NIOCore.Channel) {
            self.store.withLockedValue { store in
                store.closed += 1
                store.open -= 1
            }
        }

        var created: Int {
            self.store.withLockedValue { store in
                store.created
            }
        }

        var closed: Int {
            self.store.withLockedValue { store in
                store.closed
            }
        }

        var open: Int {
            self.store.withLockedValue { store in
                store.open
            }
        }

        struct Store {
            var created: Int = 0
            var closed: Int = 0
            var open: Int = 0
        }
    }

    func testDelegateReceivesCreationAndCloseNotifications() throws {
        let streamDelegate = CountingStreamDelegate()
        let completedChannelCount = ManagedAtomic<Int>(0)
        let http2Handler = NIOHTTP2Handler(
            mode: .server,
            eventLoop: self.channel.eventLoop,
            streamDelegate: streamDelegate,
            inboundStreamInitializer: { channel in
                channel.closeFuture.whenSuccess {
                    completedChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                }
                return channel.pipeline.addHandler(
                    TestHookHandler { context, payload in
                        if case .headers(let requestHeaders) = payload {
                            XCTAssertEqual(requestHeaders.headers, .basicRequestValues)

                            let headers = HTTP2Frame.FramePayload.headers(
                                .init(headers: .basicResponseValues, endStream: true)
                            )
                            context.writeAndFlush(NIOAny(headers), promise: nil)
                        }
                    }
                )
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a bunch of headers frames. This should open some streams.
        let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues, endStream: false))
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTP2Frame(streamID: streamID, payload: headers).encode()))
        }
        XCTAssertEqual(completedChannelCount.load(ordering: .sequentiallyConsistent), 0)
        XCTAssertEqual(streamDelegate.created, 50)
        XCTAssertEqual(streamDelegate.closed, 0)
        XCTAssertEqual(streamDelegate.open, 50)

        // Let's some data with endStream to close the streams.
        for streamID in streamIDs {
            let dataFrame = HTTP2Frame(
                streamID: streamID,
                payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!")), endStream: true))
            )
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame.encode()))
        }
        XCTAssertEqual(completedChannelCount.load(ordering: .sequentiallyConsistent), 0)
        XCTAssertEqual(streamDelegate.created, 50)
        XCTAssertEqual(streamDelegate.closed, 50)
        XCTAssertEqual(streamDelegate.open, 0)

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage all the promises should be completed, all the streams should be closed.
        XCTAssertEqual(completedChannelCount.load(ordering: .sequentiallyConsistent), 50)
        XCTAssertEqual(streamDelegate.created, 50)
        XCTAssertEqual(streamDelegate.closed, 50)
        XCTAssertEqual(streamDelegate.open, 0)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testDelegateReceivesOutboundCreationAndCloseNotifications() throws {
        let streamDelegate = CountingStreamDelegate()
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let createdChannelCount = ManagedAtomic<Int>(0)
        let configuredChannelCount = ManagedAtomic<Int>(0)
        let streamIDs = NIOLockedValueBox([HTTP2StreamID]())
        let http2Handler = NIOHTTP2Handler(
            mode: .client,
            eventLoop: self.channel.eventLoop,
            streamDelegate: streamDelegate,
            inboundStreamInitializer: { channel in
                XCTFail("Must not be called")
                return channel.eventLoop.makeFailedFuture(MyError())
            }
        )
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(http2Handler))
        try connectionSetup(mode: .client)

        let multiplexer = try http2Handler.multiplexer.wait()
        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { channel in
                createdChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { channel in
                configuredChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                // Write some headers: the flush will trigger a stream ID to be assigned to the channel.
                channel.writeAndFlush(
                    HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestValues, endStream: true))
                ).whenSuccess {
                    channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { streamID in
                        streamIDs.withLockedValue { streamIDs in
                            streamIDs.append(streamID)
                        }
                    }
                }
            }
        }

        // Run the loop to create the channels.
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 0)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs.count, 0)
        }
        XCTAssertEqual(streamDelegate.created, 0)
        XCTAssertEqual(streamDelegate.closed, 0)
        XCTAssertEqual(streamDelegate.open, 0)

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount.load(ordering: .sequentiallyConsistent), 3)
        streamIDs.withLockedValue { streamIDs in
            XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })
        }
        XCTAssertEqual(streamDelegate.created, 3)
        XCTAssertEqual(streamDelegate.closed, 0)
        XCTAssertEqual(streamDelegate.open, 3)

        // write a response to allow the streams to fully closes
        try streamIDs.withLockedValue { streamIDs in
            for id in streamIDs {
                let headers = HTTP2Frame(
                    streamID: id,
                    payload: .headers(.init(headers: .basicResponseValues, endStream: true))
                )
                XCTAssertNoThrow(try self.channel.writeInbound(headers.encode()))
            }
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        XCTAssertEqual(streamDelegate.created, 3)
        XCTAssertEqual(streamDelegate.closed, 3)
        XCTAssertEqual(streamDelegate.open, 0)

        XCTAssertNoThrow(try self.channel.finish())
    }
}

private final class ReadAndFrameConsumer: ChannelInboundHandler, ChannelOutboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundIn = HTTP2Frame.FramePayload

    private(set) var receivedFrames: [HTTP2Frame.FramePayload] = []
    private(set) var readCount = 0
    private(set) var readCompleteCount = 0
    private(set) var channelInactiveCount = 0
    private(set) var readPending = false

    var forwardRead = true {
        didSet {
            if self.forwardRead, self.readPending {
                self.context.read()
                self.readPending = false
            }
        }
    }

    var context: ChannelHandlerContext!

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.receivedFrames.append(self.unwrapInboundIn(data))
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.readCompleteCount += 1
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.channelInactiveCount += 1
        context.fireChannelInactive()
    }

    func read(context: ChannelHandlerContext) {
        self.readCount += 1
        if forwardRead {
            context.read()
            self.readPending = false
        } else {
            self.readPending = true
        }
    }
}

extension HTTP2Frame {
    func encode() throws -> ByteBuffer {
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: 1024)

        var frameEncoder = HTTP2FrameEncoder(allocator: allocator)
        let extraData = try frameEncoder.encode(frame: self, to: &buffer)
        if let extraData = extraData {
            switch extraData {
            case .byteBuffer(let extraBuffer):
                buffer.writeImmutableBuffer(extraBuffer)
            default:
                preconditionFailure()
            }
        }
        return buffer
    }
}
