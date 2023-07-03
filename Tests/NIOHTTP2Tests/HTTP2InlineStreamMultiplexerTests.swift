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
import Atomics
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import NIOHPACK       // for HPACKHeaders initializers
@testable import NIOHTTP2

private extension Channel {
    /// Adds a simple no-op ``HTTP2StreamMultiplexer`` to the pipeline.
    func addNoOpInlineMultiplexer(mode: NIOHTTP2Handler.ParserMode, eventLoop: EventLoop) {
        XCTAssertNoThrow(try self.pipeline.addHandler(NIOHTTP2Handler(mode: mode, eventLoop: eventLoop) { channel in
            self.eventLoop.makeSucceededFuture(())
        }).wait())
    }
}

private struct MyError: Error { }

typealias IODataWriteRecorder = WriteRecorder<IOData>

extension IODataWriteRecorder {
    func drainConnectionSetupWrites(mode: NIOHTTP2Handler.ParserMode = .server) throws {
        var frameDecoder = HTTP2FrameDecoder(allocator: ByteBufferAllocator(), expectClientMagic: mode == .client)

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
    static let basicRequestHeaders = HPACKHeaders(headers: [.init(name: ":path", value: "/"), .init(name: ":method", value: "GET"), .init(name: ":scheme", value: "HTTP/2.0")])
    static let basicResponseHeaders = HPACKHeaders(headers: [.init(name: ":status", value: "200")])
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
    class TestHookHandler: ChannelInboundHandler {
        typealias InboundIn = HTTP2Frame.FramePayload
        typealias OutboundOut = HTTP2Frame.FramePayload

        let channelReadHook: (ChannelHandlerContext, HTTP2Frame.FramePayload) -> ()

        init(channelReadHook: @escaping (ChannelHandlerContext, HTTP2Frame.FramePayload) -> Void) {
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

        let simplePingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame.encode()))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHeadersFramesCreateNewChannels() throws {
        let channelCount = ManagedAtomic<Int>(0)
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
            return channel.close()
        }

        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a bunch of headers frames.
        for streamID in stride(from: 1, to: 100, by: 2) {
            let frame = HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }

        XCTAssertEqual(channelCount.load(ordering: .sequentiallyConsistent), 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseThemselvesWhenToldTo() throws {
        let completedChannelCount = ManagedAtomic<Int>(0)
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channel.closeFuture.whenSuccess { completedChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent) }
            return channel.pipeline.addHandler(TestHookHandler { context, payload in
                guard case .headers(let requestHeaders) = payload else {
                    preconditionFailure("Expected request headers.")
                }
                XCTAssertEqual(requestHeaders.headers, .basicRequestHeaders)

                let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseHeaders, endStream: true))
                context.writeAndFlush(NIOAny(headers), promise: nil)
            })
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a bunch of headers frames with endStream on them. This should open some streams.
        let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders, endStream: true))
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
        let closeError = NIOLockedValueBox<Error?>(nil)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders, endStream: true)))
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            closeError.withLockedValue { closeError in
                XCTAssertNil(closeError)
            }
            channel.closeFuture.whenFailure { failureError in
                closeError.withLockedValue { closeError in
                    closeError = failureError
                }
            }
            return channel.pipeline.addHandler(FramePayloadExpecter(expectedPayload: [frame.payload, rstStreamFrame.payload]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        closeError.withLockedValue { closeError in
            XCTAssertNil(closeError)
        }

        // Now we can send a RST_STREAM frame.
        XCTAssertNoThrow(try self.channel.writeInbound(rstStreamFrame.encode()))

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        // At this stage the stream should be closed with the appropriate error code.
        closeError.withLockedValue { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed,
                           NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel))
        }
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterGoawayFrameFirstThenEvent() throws {
        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders, endStream: true)))
        let goAwayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { channel in
            XCTFail()
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup(mode: .client))

        // Let's open the stream up.
        let multiplexer = try http2Handler.multiplexer.wait()
        let streamFuture = multiplexer.createStreamChannel { channel in
            return channel.eventLoop.makeSucceededVoidFuture()
        }

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        let stream = try streamFuture.wait()

        stream.writeAndFlush(frame.payload, promise: nil)

        // Now we can send a GOAWAY frame. This will close the stream.
        XCTAssertNoThrow(try self.channel.writeInbound(goAwayFrame.encode()))

        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        XCTAssertThrowsError(try stream.closeFuture.wait()) { closeError in
            XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                           NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel))
        }
        // At this stage the stream should be closed with the appropriate manufactured error code.
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosingIdleChannels() throws {
        let frameReceiver = IODataWriteRecorder()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        // Let's send a bunch of headers frames. These will all be answered by RST_STREAM frames.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        for streamID in streamIDs {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }

        let expectedFrames = streamIDs.map { HTTP2Frame(streamID: $0, payload: .rstStream(.cancel)) }
        XCTAssertEqual(expectedFrames.count, frameReceiver.flushedWrites.count)

        var frameDecoder = HTTP2FrameDecoder(allocator: channel.allocator, expectClientMagic: false)
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
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame.
        childChannel.close(promise: nil)
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(allocator: channel.allocator, expectClientMagic: false)
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
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        var closed = false
        childChannel.close().whenComplete { _ in closed = true }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(allocator: channel.allocator, expectClientMagic: false)
        if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertTrue(closed)
    }

    func testMultipleClosePromisesAreSatisfied() throws {
        let frameReceiver = IODataWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

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
        var frameDecoder = HTTP2FrameDecoder(allocator: channel.allocator, expectClientMagic: false)
        if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertTrue(thirdClosed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClosePromiseFailsWithError() throws {
        let frameReceiver = IODataWriteRecorder()
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channelPromise.succeed(channel)
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameReceiver).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        try frameReceiver.drainConnectionSetupWrites()

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be active.
        let childChannel = try channelPromise.futureResult.wait()
        XCTAssertTrue(childChannel.isActive)

        // Now we close it. This triggers a RST_STREAM frame. The channel will not be closed at this time.
        var closeError: Error? = nil
        childChannel.close().whenFailure { closeError = $0 }
        XCTAssertEqual(frameReceiver.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(allocator: channel.allocator, expectClientMagic: false)
        if case .byteBuffer(let flushedWriteBuffer) = frameReceiver.flushedWrites[0] {
            frameDecoder.append(bytes: flushedWriteBuffer)
        }
        let (flushedFrame, _) = try frameDecoder.nextFrame()!
        flushedFrame.assertRstStreamFrame(streamID: streamID, errorCode: .cancel)
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: .cancel))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFramesAreNotDeliveredUntilStreamIsSetUp() throws {
        let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
        let setupCompletePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFramePayloadRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a headers frame to open the stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // The channel should now be available, but no frames should have been received on either the parent or child channel.
        let childChannel = try channelPromise.futureResult.wait()
        let frameRecorder = try childChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).wait()
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Send a few data frames for this stream, which should also not go through.
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!")))))
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
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channelPromise.succeed(channel)
            return channel.pipeline.addHandler(InboundFramePayloadRecorder()).flatMap {
                setupCompletePromise.futureResult
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        try writeRecorder.drainConnectionSetupWrites()

        // Let's send a headers frame to open the stream, along with some DATA frames.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        let dataFrame = try HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))).encode()
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
        var channelClosed = false
        childChannel.closeFuture.whenComplete { _ in channelClosed = true }
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)
        XCTAssertFalse(channelClosed)

        setupCompletePromise.fail(MyError())
        self.channel.assertNoFramesReceived()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertFalse(childChannel.isActive)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        var frameDecoder = HTTP2FrameDecoder(allocator: channel.allocator, expectClientMagic: false)
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
        XCTAssertFalse(channelClosed)

        (childChannel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(channelClosed)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFlushingOneChannelDoesntFlushThemAll() throws {
        let writeTracker = IODataWriteRecorder()
        let channels = NIOLockedValueBox<[Channel]>([])
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channels.withLockedValue { channels in
                channels.append(channel)
            }
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeTracker).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        try writeTracker.drainConnectionSetupWrites()

        // Let's open two streams.
        let firstStreamID = HTTP2StreamID(1)
        let secondStreamID = HTTP2StreamID(3)
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders, endStream: true)))
            XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        }
        channels.withLockedValue { channels in
            XCTAssertEqual(channels.count, 2)
        }

        // We will now write a headers frame to each channel. Neither frame should be written to the connection. To verify this
        // we will flush the parent channel.
        for (idx, _) in [firstStreamID, secondStreamID].enumerated() {
            let frame = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseHeaders))
            channels.withLockedValue { channels in
                channels[idx].write(frame, promise: nil)
            }
        }
        self.channel.flush()
        XCTAssertEqual(writeTracker.flushedWrites.count, 0)

        // Now we're going to flush only the first child channel. This should cause one flushed write.
        channels.withLockedValue { channels in
            channels[0].flush()
        }
        XCTAssertEqual(writeTracker.flushedWrites.count, 1)

        // Now the other.
        channels.withLockedValue { channels in
            channels[1].flush()
        }
        XCTAssertEqual(writeTracker.flushedWrites.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testUnflushedWritesFailOnError() throws {
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders, endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNotNil(channel)

        // We will now write a headers frame to the channel, but don't flush it.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseHeaders))
        childChannel.withLockedValue { childChannel in
            childChannel!.write(responseFrame).whenFailure {
                writeError = $0
            }
        }
        XCTAssertNil(writeError)

        // write a reset stream frame to close stream
        let resetFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))
        XCTAssertNoThrow(try self.channel.writeInbound(resetFrame.encode()))

        XCTAssertNotNil(writeError)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesFailOnClosedStreamChannels() throws {
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }
            return channel.pipeline.addHandler(TestHookHandler { context, payload in
                guard case .headers(let requestHeaders) = payload else {
                    preconditionFailure("Expected request headers.")
                }
                XCTAssertEqual(requestHeaders.headers, .basicRequestHeaders)

                let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseHeaders, endStream: true))
                context.writeAndFlush(NIOAny(headers), promise: nil)
            })
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders, endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNotNil(channel)

        // We will now write a headers frame to the channel. This should fail immediately.
        var writeError: Error? = nil
        let responseFrame = HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders))
        childChannel.withLockedValue { childChannel in
            childChannel!.write(responseFrame).whenFailure {
                writeError = $0
            }
        }
        XCTAssertEqual(writeError as? ChannelError, ChannelError.ioOnClosedChannel)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadPullsInAllFrames() throws {
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let frameRecorder = InboundFramePayloadRecorder()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel -> EventLoopFuture<Void> in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }

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
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNotNil(childChannel)

        // Now we're going to deliver 5 data frames for this stream.
        let payloadBuffer = ByteBuffer(string: "Hello, world!")
        let dataFrame = try HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(payloadBuffer)))).encode()
        for _ in 0..<5 {
            XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        }

        // These frames should not have been delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // We'll call read() on the child channel.
        childChannel.withLockedValue { childChannel in
            childChannel!.read()
        }

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

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel -> EventLoopFuture<Void> in
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
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open two streams.
        for streamID in [firstStreamID, secondStreamID] {
            let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
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
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let frameRecorder = InboundFramePayloadRecorder()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel -> EventLoopFuture<Void> in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNotNil(childChannel)

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // Call read, the header frame will come through.
        childChannel.withLockedValue { childChannel in
            childChannel!.read()
        }
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Call read again, nothing happens.
        childChannel.withLockedValue { childChannel in
            childChannel!.read()
        }
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)

        // Now deliver a data frame.
        let dataFrame = try HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))).encode()
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        // Delivering another data frame does nothing.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testReadWithNoPendingDataCausesReadOnParentChannel() throws {
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let readCounter = ReadCounter()
        let frameRecorder = InboundFramePayloadRecorder()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel -> EventLoopFuture<Void> in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }

            // We're going to disable autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.pipeline.addHandler(frameRecorder)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(readCounter).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertNotNil(childChannel)

        // This stream should have seen no frames.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)

        // There should be no calls to read.
        XCTAssertEqual(readCounter.readCount, 0)

        // Call read, the header frame will come through. No calls to read on the parent stream.
        childChannel.withLockedValue { childChannel in
            childChannel!.read()
        }
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCounter.readCount, 0)

        // Call read again, read is called on the parent stream. No frames delivered.
        childChannel.withLockedValue { childChannel in
            childChannel!.read()
        }
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCounter.readCount, 1)

        // Now deliver a data frame.
        let dataFrame = try HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))).encode()
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered. No extra call to read.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 1)

        // Another call to read issues a read to the parent stream.
        childChannel.withLockedValue { childChannel in
            childChannel!.read()
        }
        XCTAssertEqual(frameRecorder.receivedFrames.count, 2)
        XCTAssertEqual(readCounter.readCount, 2)

        // Another call to read, this time does not issue a read to the parent stream.
        childChannel.withLockedValue { childChannel in
            childChannel!.read()
        }
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

    func testHandlersAreRemovedOnClosure() throws {
        var handlerRemoved = false
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in handlerRemoved = true }

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            return channel.pipeline.addHandlers([
                HandlerRemovedHandler(removedPromise: handlerRemovedPromise),
                TestHookHandler { context, payload in
                    guard case .headers(let requestHeaders) = payload else {
                        preconditionFailure("Expected request headers.")
                    }
                    XCTAssertEqual(requestHeaders.headers, .basicRequestHeaders)

                    let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseHeaders, endStream: true))
                    context.writeAndFlush(NIOAny(headers), promise: nil)
                }])
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders, endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved)

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHandlersAreRemovedOnClosureWithError() throws {
        var handlerRemoved = false
        let handlerRemovedPromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        handlerRemovedPromise.futureResult.whenComplete { _ in handlerRemoved = true }

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop)  { channel in
            return channel.pipeline.addHandlers([
                HandlerRemovedHandler(removedPromise: handlerRemovedPromise),
                TestHookHandler { context, payload in
                    guard case .headers(let requestHeaders) = payload else {
                        preconditionFailure("Expected request headers.")
                    }
                    XCTAssertEqual(requestHeaders.headers, .basicRequestHeaders)

                    let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseHeaders, endStream: true))
                    context.writeAndFlush(NIOAny(headers), promise: nil)
                }])
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders, endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))

        // No handlerRemoved so far.
        XCTAssertFalse(handlerRemoved)

        // The handlers will only be removed after we spin the loop.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(handlerRemoved)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatingOutboundChannelClient() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let createdChannelCount = ManagedAtomic<Int>(0)
        var configuredChannelCount = 0
        var streamIDs = Array<HTTP2StreamID>()
        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil)) // to make the channel active

        let multiplexer = try http2Handler.multiplexer.wait()
        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { channel in
                createdChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { channel in
                configuredChannelCount += 1
                // Write some headers: the flush will trigger a stream ID to be assigned to the channel.
                channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders))).whenSuccess {
                    channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { streamID in
                        streamIDs.append(streamID)
                    }
                }
            }
        }

        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs.count, 0)

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount, 3)
        XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesOnCreatedChannelAreDelayed() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = IODataWriteRecorder()
        let childChannel = NIOLockedValueBox<Channel?>(nil)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        try writeRecorder.drainConnectionSetupWrites(mode: .client)

        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertNotNil(childChannel)

        childChannel.withLockedValue { childChannel in
            childChannel!.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders)), promise: nil)
        }
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        configurePromise.succeed(())
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testWritesAreCancelledOnFailingInitializer() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let childChannel = NIOLockedValueBox<Channel?>(nil)

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        var writeError: Error? = nil
        childChannel.withLockedValue { childChannel in
            childChannel!.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders))).whenFailure { writeError = $0 }
        }
        XCTAssertNil(writeError)

        configurePromise.fail(MyError())
        XCTAssertNotNil(writeError)
        XCTAssertTrue(writeError is MyError)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testFailingInitializerDoesNotWrite() throws {
        let configurePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let writeRecorder = FrameWriteRecorder()

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            return configurePromise.futureResult
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        configurePromise.fail(MyError())
        XCTAssertEqual(writeRecorder.flushedWrites.count, 0)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelDoesNotActivateEarly() throws {
        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertFalse(activated)

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(unixDomainSocketPath: "/whatever"), promise: nil))

        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testCreatedChildChannelActivatesIfParentIsActive() throws {
        var activated = false

        let activePromise: EventLoopPromise<Void> = self.channel.eventLoop.makePromise()
        let activeRecorder = ActiveHandler(activatedPromise: activePromise)
        activePromise.futureResult.map {
            activated = true
        }.whenFailure { (_: Error) in
            XCTFail("Activation promise must not fail")
        }

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())

        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8765)).wait())
        XCTAssertFalse(activated)

        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            return channel.pipeline.addHandler(activeRecorder)
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

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

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            return channel.pipeline.addHandler(activeRecorder)
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())
        self.channel.pipeline.fireChannelActive()

        // Open a new stream.
        XCTAssertFalse(activated)
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        XCTAssertTrue(activated)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultiplexerIgnoresPriorityFrames() throws {
        self.channel.addNoOpInlineMultiplexer(mode: .server, eventLoop: self.channel.eventLoop)
        XCTAssertNoThrow(try connectionSetup())

        let simplePingFrame = HTTP2Frame(streamID: 106, payload: .priority(.init(exclusive: true, dependency: .rootStream, weight: 15)))
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame.encode()))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testMultiplexerForwardsActiveToParent() throws {
        self.channel.addNoOpInlineMultiplexer(mode: .client, eventLoop: self.channel.eventLoop)

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

    func testCreatedChildChannelCanBeClosedImmediately() throws {
        let closed = ManagedAtomic<Bool>(false)

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { channel in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())

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
        var closed = false

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { channel in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: channelPromise) { channel in
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

    func testCreatedChildChannelCanBeClosedImmediatelyWhenBaseIsActive() throws {
        let closed = ManagedAtomic<Bool>(false)

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { channel in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertEqual(try self.channel.readAllBuffers().count, 2) // magic & settings

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
        var closed = false

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { channel in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertEqual(try self.channel.readAllBuffers().count, 2) // magic & settings

        let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: channelPromise) { channel in
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

    func testMultiplexerCoalescesFlushCallsDuringChannelRead() throws {
        // Add a flush counter.
        let flushCounter = FlushCounter()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(flushCounter).wait())

        // Add a server-mode multiplexer that will add an auto-response handler.
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
            channel.pipeline.addHandler(QuickFramePayloadResponseHandler())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // We're going to send in 10 request frames.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        XCTAssertEqual(flushCounter.flushCount, 2) // two flushes in connection setup

        let framesToSend = stride(from: 1, through: 19, by: 2).map { HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(.init(headers: requestHeaders, endStream: true))) }
        for frame in framesToSend {
            self.channel.pipeline.fireChannelRead(NIOAny(try frame.encode()))
        }
        self.channel.embeddedEventLoop.run()

        // Response frames should have been written, but no flushes, so they aren't visible.
        XCTAssertEqual(try self.channel.decodedSentFrames().count, 2) // 2 for handler setup
        XCTAssertEqual(flushCounter.flushCount, 2) // 2 for handler setup

        // Now send channel read complete. The frames should be flushed through.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(try self.channel.decodedSentFrames().count, 10)
        XCTAssertEqual(flushCounter.flushCount, 3)
    }

    func testMultiplexerDoesntFireReadCompleteForEachFrame() throws {
        let frameRecorder = InboundFramePayloadRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { childChannel in
            return childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 0)

        // Wake up and activate the stream.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        let requestFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: requestHeaders, endStream: false)))
        XCTAssertNoThrow(self.channel.pipeline.fireChannelRead(NIOAny(try requestFrame.encode())))
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 1)

        // Now we're going to send 9 data frames.
        let dataFrame = try HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))).encode()
        for _ in 0..<9 {
            self.channel.pipeline.fireChannelRead(NIOAny(dataFrame))
        }

        // We should have 1 read (the HEADERS), and one read complete.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 1)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 1)

        // Fire read complete on the parent and it'll propagate to the child. This will trigger the reads.
        self.channel.pipeline.fireChannelReadComplete()

        // We should have 10 reads, and two read completes.
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 2)

        // If we fire a new read complete on the parent, the child doesn't see it this time, as it received no frames.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 10)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 2)
    }

    func testMultiplexerCorrectlyTellsAllStreamsAboutReadComplete() throws {
        // These are deliberately getting inserted to all streams. The test above confirms the single-stream
        // behaviour is correct.
        let frameRecorder = InboundFramePayloadRecorder()
        let readCompleteCounter = ReadCompleteCounter()

        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { childChannel in
            return childChannel.pipeline.addHandler(frameRecorder).flatMap {
                childChannel.pipeline.addHandler(readCompleteCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        XCTAssertEqual(frameRecorder.receivedFrames.count, 0)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 0)

        // Wake up and activate the streams.
        let requestHeaders = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
        for streamID in [HTTP2StreamID(1), HTTP2StreamID(3), HTTP2StreamID(5)] {
            let requestFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders, endStream: false)))
            try self.channel.pipeline.fireChannelRead(NIOAny(requestFrame.encode()))
        }
        self.channel.embeddedEventLoop.run()

        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 3)

        // Firing in readComplete does not cause a second readComplete for each stream, as no frames were delivered.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.receivedFrames.count, 3)
        XCTAssertEqual(readCompleteCounter.readCompleteCount, 3)

        // Now we're going to send a data frame on stream 1.
        let dataFrame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!")))))
        self.channel.pipeline.fireChannelRead(NIOAny(try dataFrame.encode()))

        // We should have 3 reads, and 3 read completes. The frame is not delivered as we have no frame fast-path.
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

    func testMultiplexerModifiesStreamChannelWritabilityBasedOnFixedSizeTokens() throws {
        var streamConfiguration = NIOHTTP2Handler.StreamConfiguration()
        streamConfiguration.outboundBufferSizeHighWatermark = 100
        streamConfiguration.outboundBufferSizeLowWatermark = 50
        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop, streamConfiguration: streamConfiguration) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            return childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
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
        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a few new child streams.
        let promises = (0..<5).map { _ in self.channel.eventLoop.makePromise(of: Channel.self) }
        for promise in promises {
            let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: promise) { childChannel in
                return childChannel.eventLoop.makeSucceededFuture(())
            }
        }
        self.channel.embeddedEventLoop.run()

        let channels = try assertNoThrowWithValue(promises.map { promise in try promise.futureResult.wait() })

        // These are all writable.
        XCTAssertEqual(channels.map { $0.isWritable }, [true, true, true, true, true])

        // We need to write (and flush) some data so that the streams get stream IDs.
        for childChannel in channels {
            XCTAssertNoThrow(try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders))).wait())
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
        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop, streamConfiguration: streamConfiguration) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now we want to create a new child stream.
        let childChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: childChannelPromise) { childChannel in
            return childChannel.eventLoop.makeSucceededFuture(())
        }
        self.channel.embeddedEventLoop.run()

        let childChannel = try assertNoThrowWithValue(childChannelPromise.futureResult.wait())
        // We need to write (and flush) some data so that the streams get stream IDs.
        XCTAssertNoThrow(try childChannel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders))).wait())

        XCTAssertTrue(childChannel.isWritable)

        // We're going to write a HEADERS frame (not counted towards flow control calculations) and a 90 byte DATA frame (90 bytes). This will not flip the
        // writability state.
        let headers = HPACKHeaders([(":path", "/"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https")])
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
        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop, streamConfiguration: streamConfiguration) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())

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
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let readCounter = ReadCounter()
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel -> EventLoopFuture<Void> in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }

            // We're going to _enable_ autoRead on this channel.
            return channel.setOption(ChannelOptions.autoRead, value: true).flatMap {
                channel.pipeline.addHandler(readCounter)
            }
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's open a stream.
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
        childChannel.withLockedValue { childChannel in
            XCTAssertNotNil(childChannel)
        }

        // There should be two calls to read: the first, when the stream was activated, the second after the HEADERS
        // frame was delivered.
        XCTAssertEqual(readCounter.readCount, 2)

        // Now deliver a data frame.
        let dataFrame = try HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!"))))).encode()
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))

        // This frame should have been immediately delivered, _and_ a call to read should have happened.
        XCTAssertEqual(readCounter.readCount, 3)

        // Delivering two more frames causes two more calls to read.
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        XCTAssertEqual(readCounter.readCount, 5)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testStreamChannelSupportsSyncOptions() throws {
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop) { channel in
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
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        let frame = HTTP2Frame(streamID: HTTP2StreamID(1), payload: .headers(.init(headers: .basicRequestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(frame.encode()))
    }

    func testStreamErrorIsDeliveredToChannel() throws {
        let goodHeaders = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")
        ])
        var badHeaders = goodHeaders
        badHeaders.add(name: "transfer-encoding", value: "chunked")

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { channel in
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup(mode: .client))
        XCTAssertEqual(try self.channel.readAllBuffers().count, 3) // drain outbound magic, settings & ACK

        // We need to activate the underlying channel here.
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 80)).wait())

        // Now create two child channels with error recording handlers in them. Save one, ignore the other.
        let errorRecorder = ErrorRecorder()
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }
            return channel.pipeline.addHandler(errorRecorder)
        }

        let secondErrorRecorder = ErrorRecorder()
        multiplexer.createStreamChannel(promise: nil) { channel in
            // For this one we'll do a write immediately, to bring it into existence and give it a stream ID.
            channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: goodHeaders)), promise: nil)
            return channel.pipeline.addHandler(secondErrorRecorder)
        }
        self.channel.embeddedEventLoop.run()

        // On this child channel, write and flush an invalid headers frame.
        XCTAssertEqual(errorRecorder.errors.count, 0)
        XCTAssertEqual(secondErrorRecorder.errors.count, 0)

        childChannel.withLockedValue { childChannel in
            childChannel!.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: badHeaders)), promise: nil)
        }

        // It should come through to the channel.
        XCTAssertEqual(
            errorRecorder.errors.first.flatMap { $0 as? NIOHTTP2Errors.ForbiddenHeaderField },
            NIOHTTP2Errors.forbiddenHeaderField(name: "transfer-encoding", value: "chunked")
        )
        XCTAssertEqual(secondErrorRecorder.errors.count, 0)

        // Simulate closing the child channel in response to the error.
        childChannel.withLockedValue { childChannel in
            childChannel!.close(promise: nil)
        }
        self.channel.embeddedEventLoop.run()

        // Only the HEADERS frames should have been written: we closed before the other channel became active, so
        // it should not have triggered an RST_STREAM frame.
        let frames = try self.channel.decodedSentFrames()
        XCTAssertEqual(frames.count, 1)

        frames[0].assertHeadersFrame(endStream: false, streamID: 1, headers: goodHeaders, priority: nil, type: .request)
    }

    func testPendingReadsAreFlushedEvenWithoutUnsatisfiedReadOnChannelInactive() throws {
        let goodHeaders = HPACKHeaders([
            (":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "localhost")
        ])

        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop) { channel in
            XCTFail("Server push is unexpected")
            return channel.eventLoop.makeSucceededFuture(())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup(mode: .client))
        XCTAssertEqual(try self.channel.readAllBuffers().count, 3) // drain outbound magic, settings & ACK

        // Now create and save a child channel with an error recording handler in it.
        let consumer = ReadAndFrameConsumer()
        let childChannel = NIOLockedValueBox<Channel?>(nil)
        let multiplexer = try http2Handler.multiplexer.wait()
        multiplexer.createStreamChannel(promise: nil) { channel in
            childChannel.withLockedValue { childChannel in
                childChannel = channel
            }
            return channel.pipeline.addHandler(consumer)
        }
        self.channel.embeddedEventLoop.run()

        let streamID = HTTP2StreamID(1)

        let payload = HTTP2Frame.FramePayload.Headers(headers: goodHeaders, endStream: true)
        try childChannel.withLockedValue { childChannel in
            XCTAssertNoThrow(try childChannel!.writeAndFlush(HTTP2Frame.FramePayload.headers(payload)).wait())
        }

        let frames = try self.channel.decodedSentFrames()
        XCTAssertEqual(frames.count, 1)
        frames.first?.assertHeadersFrameMatches(this: HTTP2Frame(streamID: streamID, payload: .headers(payload)))

        XCTAssertEqual(consumer.readCount, 1)

        // 1. pass header onwards

        let responseHeaderFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: [":status": "200"])))
        XCTAssertNoThrow(try self.channel.writeInbound(responseHeaderFrame.encode()))
        XCTAssertEqual(consumer.receivedFrames.count, 1)
        XCTAssertEqual(consumer.readCompleteCount, 1)
        XCTAssertEqual(consumer.readCount, 2)

        consumer.forwardRead = false

        // 2. pass body onwards

        let responseFrame1 = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(.init(string: "foo")))))
        XCTAssertNoThrow(try self.channel.writeInbound(responseFrame1.encode()))
        XCTAssertEqual(consumer.receivedFrames.count, 2)
        XCTAssertEqual(consumer.readCompleteCount, 2)
        XCTAssertEqual(consumer.readCount, 3)
        XCTAssertEqual(consumer.readPending, true)

        // 3. pass on more body - should not change a thing, since read is pending in consumer

        let responseFrame2 = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(.init(string: "bar")), endStream: false)))
        XCTAssertNoThrow(try self.channel.writeInbound(responseFrame2.encode()))
        XCTAssertEqual(consumer.receivedFrames.count, 2)
        XCTAssertEqual(consumer.readCompleteCount, 2)
        XCTAssertEqual(consumer.readCount, 3)
        XCTAssertEqual(consumer.readPending, true)

        // 4. signal stream is closed – this should force forward all pending frames

        let responseFrame3 = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(.init(string: "bar")), endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(responseFrame3.encode()))
        XCTAssertEqual(consumer.receivedFrames.count, 4)
        XCTAssertEqual(consumer.readCompleteCount, 3)
        XCTAssertEqual(consumer.readCount, 3)
        XCTAssertEqual(consumer.channelInactiveCount, 1)
        XCTAssertEqual(consumer.readPending, true)
    }

    fileprivate struct CountingStreamDelegate: NIOHTTP2StreamDelegate {
        private var store = Store()

        func streamCreated(_ id: NIOHTTP2.HTTP2StreamID, channel: NIOCore.Channel) {
            self.store.created+=1
            self.store.open+=1
        }

        func streamClosed(_ id: NIOHTTP2.HTTP2StreamID, channel: NIOCore.Channel) {
            self.store.closed+=1
            self.store.open-=1
        }

        var created: Int {
            self.store.created
        }

        var closed: Int {
            self.store.closed
        }

        var open: Int {
            self.store.open
        }

        class Store {
            var created: Int = 0
            var closed: Int = 0
            var open: Int = 0
        }
    }

    func testDelegateReceivesCreationAndCloseNotifications() throws {
        let streamDelegate = CountingStreamDelegate()
        let completedChannelCount = ManagedAtomic<Int>(0)
        let http2Handler = NIOHTTP2Handler(mode: .server, eventLoop: self.channel.eventLoop, streamDelegate: streamDelegate) { channel in
            channel.closeFuture.whenSuccess { completedChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent) }
            return channel.pipeline.addHandler(TestHookHandler { context, payload in
                if case .headers(let requestHeaders) = payload {
                    XCTAssertEqual(requestHeaders.headers, .basicRequestHeaders)

                    let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicResponseHeaders, endStream: true))
                    context.writeAndFlush(NIOAny(headers), promise: nil)
                }
            })
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        XCTAssertNoThrow(try connectionSetup())

        // Let's send a bunch of headers frames. This should open some streams.
        let headers = HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders, endStream: false))
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
            let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(ByteBuffer(string: "Hello, world!")), endStream: true)))
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
        var configuredChannelCount = 0
        var streamIDs = Array<HTTP2StreamID>()
        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: self.channel.eventLoop, streamDelegate: streamDelegate) { _ in
            XCTFail("Must not be called")
            return self.channel.eventLoop.makeFailedFuture(MyError())
        }
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(http2Handler).wait())
        try connectionSetup(mode: .client)

        let multiplexer = try http2Handler.multiplexer.wait()
        for _ in 0..<3 {
            let channelPromise: EventLoopPromise<Channel> = self.channel.eventLoop.makePromise()
            multiplexer.createStreamChannel(promise: channelPromise) { channel in
                createdChannelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                return configurePromise.futureResult
            }
            channelPromise.futureResult.whenSuccess { channel in
                configuredChannelCount += 1
                // Write some headers: the flush will trigger a stream ID to be assigned to the channel.
                channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: .basicRequestHeaders, endStream: true))).whenSuccess {
                    channel.getOption(HTTP2StreamChannelOptions.streamID).whenSuccess { streamID in
                        streamIDs.append(streamID)
                    }
                }
            }
        }

        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount, 0)
        XCTAssertEqual(streamIDs.count, 0)
        XCTAssertEqual(streamDelegate.created, 0)
        XCTAssertEqual(streamDelegate.closed, 0)
        XCTAssertEqual(streamDelegate.open, 0)

        configurePromise.succeed(())
        XCTAssertEqual(createdChannelCount.load(ordering: .sequentiallyConsistent), 3)
        XCTAssertEqual(configuredChannelCount, 3)
        XCTAssertEqual(streamIDs, [1, 3, 5].map { HTTP2StreamID($0) })
        XCTAssertEqual(streamDelegate.created, 3)
        XCTAssertEqual(streamDelegate.closed,0)
        XCTAssertEqual(streamDelegate.open, 3)

        // write a response to allow the streams to fully closes
        for id in streamIDs {
            let headers = HTTP2Frame(streamID: id, payload: .headers(.init(headers: .basicResponseHeaders, endStream: true)))
            XCTAssertNoThrow(try self.channel.writeInbound(headers.encode()))
        }
        (self.channel.eventLoop as! EmbeddedEventLoop).run()

        XCTAssertEqual(streamDelegate.created, 3)
        XCTAssertEqual(streamDelegate.closed,3)
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
