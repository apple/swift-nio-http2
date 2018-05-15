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
@testable import NIOHTTP2

private extension ChannelPipeline {
    /// Adds a simple no-op `HTTP2StreamMultiplexer` to the pipeline.
    func addNoOpMultiplexer() {
        XCTAssertNoThrow(try self.add(handler: HTTP2StreamMultiplexer { (channel, streamID) in
            self.eventLoop.newSucceededFuture(result: ())
        }).wait())
    }
}


/// A handler that asserts the frames received match the expected set.
final class FrameExpecter: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    private let expectedFrames: [HTTP2Frame]
    private var actualFrames: [HTTP2Frame] = []

    init(expectedFrames: [HTTP2Frame]) {
        self.expectedFrames = expectedFrames
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.actualFrames.append(frame)
    }

    func handlerRemoved(ctx: ChannelHandlerContext) {
        XCTAssertEqual(self.expectedFrames.count, self.actualFrames.count)

        for (idx, expectedFrame) in self.expectedFrames.enumerated() {
            let actualFrame = self.actualFrames[idx]
            expectedFrame.assertFrameMatches(this: actualFrame)
        }
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

    func testMultiplexerIgnoresFramesOnStream0() throws {
        self.channel.pipeline.addNoOpMultiplexer()

        let simplePingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5)))
        XCTAssertNoThrow(try self.channel.writeInbound(simplePingFrame))
        XCTAssertNoThrow(try self.channel.assertReceivedFrame().assertFrameMatches(this: simplePingFrame))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testHeadersFramesCreateNewChannels() throws {
        var channelCount = 0
        let multiplexer = HTTP2StreamMultiplexer { (channel, _) in
            channelCount += 1
            return channel.close()
        }
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: multiplexer).wait())

        // Let's send a bunch of headers frames.
        for streamID in stride(from: 1, to: 100, by: 2) {
            let frame = HTTP2Frame(streamID: HTTP2StreamID(knownID: Int32(streamID)), payload: .headers(HTTPHeaders()))
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }

        XCTAssertEqual(channelCount, 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseThemselvesWhenToldTo() throws {
        var completedChannelCount = 0
        var closeFutures: [EventLoopFuture<Void>] = []
        let multiplexer = HTTP2StreamMultiplexer { (channel, _) in
            closeFutures.append(channel.closeFuture)
            channel.closeFuture.whenSuccess { completedChannelCount += 1 }
            return channel.eventLoop.newSucceededFuture(result: ())
        }
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: multiplexer).wait())

        // Let's send a bunch of headers frames with endStream on them. This should open some streams.
        let streamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID(knownID: Int32($0)) }
        for streamID in streamIDs {
            var frame = HTTP2Frame(streamID: streamID, payload: .headers(HTTPHeaders()))
            frame.endStream = true
            XCTAssertNoThrow(try self.channel.writeInbound(frame))
        }
        XCTAssertEqual(completedChannelCount, 0)

        // Now we send them all a clean exit.
        for streamID in streamIDs {
            let event = StreamClosedEvent(streamID: streamID, reason: nil)
            self.channel.pipeline.fireUserInboundEventTriggered(event)
        }

        // At this stage all the promises should be completed.
        XCTAssertEqual(completedChannelCount, 50)
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterResetStreamEventFirstThenFrame() throws {
        var closeError: Error? = nil

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(knownID: Int32(1))
        var frame = HTTP2Frame(streamID: streamID, payload: .headers(HTTPHeaders()))
        frame.endStream = true
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))

        let multiplexer = HTTP2StreamMultiplexer { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            return channel.pipeline.add(handler: FrameExpecter(expectedFrames: [frame, rstStreamFrame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNil(closeError)

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        // Now we can send a RST_STREAM frame.
        XCTAssertNoThrow(try self.channel.writeInbound(rstStreamFrame))

        // At this stage the stream should be closed with the appropriate error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterResetStreamFrameFirstThenEvent() throws {
        var closeError: Error? = nil

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(knownID: Int32(1))
        var frame = HTTP2Frame(streamID: streamID, payload: .headers(HTTPHeaders()))
        frame.endStream = true
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))

        let multiplexer = HTTP2StreamMultiplexer { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            return channel.pipeline.add(handler: FrameExpecter(expectedFrames: [frame, rstStreamFrame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNil(closeError)

        // Now we can send a RST_STREAM frame.
        XCTAssertNoThrow(try self.channel.writeInbound(rstStreamFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .cancel)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        // At this stage the stream should be closed with the appropriate error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .cancel))
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterGoawayEventFirstThenFrame() throws {
        var closeError: Error? = nil

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(knownID: Int32(1))
        var frame = HTTP2Frame(streamID: streamID, payload: .headers(HTTPHeaders()))
        frame.endStream = true
        let goAwayFrame = HTTP2Frame(streamID: streamID, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))

        let multiplexer = HTTP2StreamMultiplexer { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            // The channel won't see the goaway frame.
            return channel.pipeline.add(handler: FrameExpecter(expectedFrames: [frame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNil(closeError)

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .refusedStream)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        // Now we can send a GOAWAY frame. This will close the stream.
        XCTAssertNoThrow(try self.channel.writeInbound(goAwayFrame))

        // At this stage the stream should be closed with the appropriate manufactured error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .refusedStream))
        XCTAssertNoThrow(try self.channel.finish())
    }

    func testChannelsCloseAfterGoawayFrameFirstThenEvent() throws {
        var closeError: Error? = nil

        // First, set up the frames we want to send/receive.
        let streamID = HTTP2StreamID(knownID: Int32(1))
        var frame = HTTP2Frame(streamID: streamID, payload: .headers(HTTPHeaders()))
        frame.endStream = true
        let goAwayFrame = HTTP2Frame(streamID: streamID, payload: .goAway(lastStreamID: .rootStream, errorCode: .http11Required, opaqueData: nil))

        let multiplexer = HTTP2StreamMultiplexer { (channel, _) in
            XCTAssertNil(closeError)
            channel.closeFuture.whenFailure { closeError = $0 }
            // The channel won't see the goaway frame.
            return channel.pipeline.add(handler: FrameExpecter(expectedFrames: [frame]))
        }
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: multiplexer).wait())

        // Let's open the stream up.
        XCTAssertNoThrow(try self.channel.writeInbound(frame))
        XCTAssertNil(closeError)

        // Now we can send a GOAWAY frame. This will close the stream.
        XCTAssertNoThrow(try self.channel.writeInbound(goAwayFrame))

        // Now we send the user event.
        let userEvent = StreamClosedEvent(streamID: streamID, reason: .refusedStream)
        self.channel.pipeline.fireUserInboundEventTriggered(userEvent)

        // At this stage the stream should be closed with the appropriate manufactured error code.
        XCTAssertEqual(closeError as? NIOHTTP2Errors.StreamClosed,
                       NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: .refusedStream))
        XCTAssertNoThrow(try self.channel.finish())
    }
}
