//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
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
import NIOHPACK
import NIOHTTP2


/// A ChannelHandler that has a stripped down version of the HTTP/2 state machine.
final class OutboundFrameRecorder: ChannelOutboundHandler {
    typealias OutboundIn = HTTP2Frame
    typealias OutboundOut = Never

    private var _pendingWrites: [(HTTP2Frame, EventLoopPromise<Void>?)] = []

    var pendingWrites: [HTTP2Frame] {
        return self._pendingWrites.map { $0.0 }
    }

    var flushedWrites: [HTTP2Frame] = []

    private var openStreams: Set<HTTP2StreamID> = []

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self._pendingWrites.append((frame, promise))

        if !self.openStreams.contains(frame.streamID) {
            self.openStreams.insert(frame.streamID)
            ctx.fireUserInboundEventTriggered(NIOHTTP2StreamCreatedEvent(streamID: frame.streamID, localInitialWindowSize: 65535, remoteInitialWindowSize: 65535))
        }

        if frame.flags.contains(.endStream) {
            self.openStreams.remove(frame.streamID)
            ctx.fireUserInboundEventTriggered(StreamClosedEvent(streamID: frame.streamID, reason: nil))
        }
    }

    func flush(ctx: ChannelHandlerContext) {
        let flushedWrites = self._pendingWrites
        self._pendingWrites = []

        for (frame, promise) in flushedWrites {
            self.flushedWrites.append(frame)
            promise?.succeed(())
        }
    }
}

final class CloseOnWriteForStreamHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTP2Frame
    typealias OutboundOut = Never

    private let reason: HTTP2ErrorCode?
    private let streamToFail: HTTP2StreamID

    init(streamToFail: HTTP2StreamID, reason: HTTP2ErrorCode?) {
        self.streamToFail = streamToFail
        self.reason = reason
    }

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        if frame.streamID == self.streamToFail {
            ctx.fireUserInboundEventTriggered(StreamClosedEvent(streamID: self.streamToFail, reason: self.reason))
        }
        ctx.write(data, promise: promise)
    }
}

final class HTTP2ConcurrentStreamsHandlerTests: XCTestCase {
    var channel: EmbeddedChannel!

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        self.channel = nil
    }

    func testBasicFunctionality() {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 2)).wait())

        // Write frames for three streams.
        let frames = stride(from: 1, through: 5, by: 2).map { HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(HPACKHeaders([]), nil)) }
        for frame in frames {
            self.channel.write(frame, promise: nil)
        }

        // Only two of these should have been passed through, and neither should have been flushed.
        frameRecorder.pendingWrites.assertFramesMatch(frames.prefix(2))
        XCTAssertEqual(frameRecorder.flushedWrites.count, 0)

        // Flushing these should not produce another frame.
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2))

        // Sending a frame with end stream on it should not produce a write yet, though that frame should be passed through.
        var endStreamFrame = HTTP2Frame(streamID: 1, payload: .data(.byteBuffer(ByteBufferAllocator().buffer(capacity: 0))))
        endStreamFrame.flags.insert(.endStream)
        self.channel.write(endStreamFrame, promise: nil)

        frameRecorder.pendingWrites.assertFramesMatch([endStreamFrame])
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2))

        // Now we flush. This should cause the remaining HEADERS frame to be written.
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch(Array(frames.prefix(2)) + [endStreamFrame, frames.last!])
    }

    func testToleratesNegativeNumbersOfStreams() throws {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 2)).wait())

        // Write frames for three streams and flush them.
        let frames = stride(from: 1, through: 5, by: 2).map { HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(HPACKHeaders([]), nil)) }
        for frame in frames {
            self.channel.write(frame, promise: nil)
        }
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2))

        // Now we're going to drop the number of allowed concurrent streams to 1.
        let settings = HTTP2Frame(streamID: .rootStream, payload: .settings([HTTP2Setting(parameter: .maxConcurrentStreams, value: 3), HTTP2Setting(parameter: .maxConcurrentStreams, value: 1)]))
        try self.channel.writeInbound(settings)

        // No change.
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2))

        // Write a new stream. This should be buffered.
        var newStreamFrame = HTTP2Frame(streamID: 7, payload: .headers(HPACKHeaders([]), nil))
        newStreamFrame.flags.insert(.endStream)
        self.channel.writeAndFlush(newStreamFrame, promise: nil)

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2))

        // Now send an END_STREAM frame. Nothing should happen, though the frame itself should pass through.
        var endStreamFrame = HTTP2Frame(streamID: 1, payload: .data(.byteBuffer(ByteBufferAllocator().buffer(capacity: 0))))
        endStreamFrame.flags.insert(.endStream)
        self.channel.write(endStreamFrame, promise: nil)

        frameRecorder.pendingWrites.assertFramesMatch([endStreamFrame])
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2))

        // And flush it. Nothing should happen, as only one stream is allowed through.
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2) + [endStreamFrame])

        // Now send endStream for the other one. Initially nothing happens.
        var newEndStreamFrame = endStreamFrame
        newEndStreamFrame.streamID = 3
        self.channel.write(newEndStreamFrame, promise: nil)

        frameRecorder.pendingWrites.assertFramesMatch([newEndStreamFrame])
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2) + [endStreamFrame])

        // Flush it. This *does* unblock the next stream, but only one.
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch(frames.prefix(2) + [endStreamFrame, newEndStreamFrame, frames.last!])
    }

    func testCascadingFrames() throws {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 1)).wait())

        // We're going to test a cascade of frames as a result of stream closure. This is not likely to happen in real code,
        // but it's a good test to confirm that we're safe in re-entrant calls. To do this, we set up, let's say, 100
        // streams where all but the first has an END_STREAM frame in it.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(HPACKHeaders([]), nil))

        let subsequentFrames: [HTTP2Frame] = stride(from: 3, to: 201, by: 2).map { streamID in
            var frame = HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: .headers(HPACKHeaders([]), nil))
            frame.flags.insert(.endStream)
            return frame
        }

        // Write the first frame, and all the subsequent frames, and flush them. This will lead to one flushed frame.
        for frame in [firstFrame] + subsequentFrames {
            self.channel.write(frame, promise: nil)
        }
        self.channel.flush()

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame])

        // Ok, now we're going to tell the buffer that the first stream is closed. Initially, nothing will happen.
        self.channel.pipeline.fireUserInboundEventTriggered(StreamClosedEvent(streamID: 1, reason: nil))
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame])

        // Now send channelReadComplete, which will trigger the cascade. This should flush *everything*.
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame] + subsequentFrames)
    }

    func testBufferedFramesPassedThroughOnStreamClosed() {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(CloseOnWriteForStreamHandler(streamToFail: 3, reason: nil)).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 1)).wait())

        // We're going to start stream 1, and then arrange a buffer of a bunch of frames in stream 3. We'll flush some, but not all of them
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(HPACKHeaders([]), nil))
        let subsequentFrame = HTTP2Frame(streamID: 3, payload: .data(.byteBuffer(self.channel.allocator.buffer(capacity: 0))))
        self.channel.write(firstFrame, promise: nil)

        (0..<15).forEach { _ in self.channel.write(subsequentFrame, promise: nil) }
        self.channel.flush()
        (0..<15).forEach { _ in self.channel.write(subsequentFrame, promise: nil) }

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame])

        // Ok, now we're going to unblock stream 3 by completing stream 1.
        // This will cause an stream closed to fire, but that will not affect these writes.
        self.channel.pipeline.fireUserInboundEventTriggered(StreamClosedEvent(streamID: 1, reason: nil))
        self.channel.pipeline.fireChannelReadComplete()

        // The flushed writes should all be passed through.
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame] + Array(repeating: subsequentFrame, count: 15))

        // A subsequent flush will drive the rest of the frames through.
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame] + Array(repeating: subsequentFrame, count: 30))
    }

    func testResetStreamOnUnbufferingStream() {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 1)).wait())

        // We're going to start stream 1, and then arrange a buffer of a bunch of frames in stream 3. We'll flush some, but not all of them
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(HPACKHeaders([]), nil))
        let subsequentFrame = HTTP2Frame(streamID: 3, payload: .data(.byteBuffer(self.channel.allocator.buffer(capacity: 0))))
        self.channel.write(firstFrame, promise: nil)

        var writeStatus: [Bool?] = Array(repeating: nil, count: 30)

        var writePromises = (0..<15).map { _ in self.channel.write(subsequentFrame) }
        self.channel.flush()
        writePromises.append(contentsOf: (0..<15).map { _ in self.channel.write(subsequentFrame) })

        for (idx, promise) in writePromises.enumerated() {
            promise.map {
                writeStatus[idx] = true
            }.whenFailure { error in
                XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: 3, errorCode: .cancel))
                writeStatus[idx] = false
            }
        }

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame])

        // Now we're going to unblock stream 3 by completing stream 1. This will leave our buffer still in place, as we can't
        // pass on the unflushed writes.
        self.channel.pipeline.fireUserInboundEventTriggered(StreamClosedEvent(streamID: 1, reason: nil))
        self.channel.pipeline.fireChannelReadComplete()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame] + Array(repeating: subsequentFrame, count: 15))

        // Only the first 15 are done.
        XCTAssertEqual(writeStatus, Array(repeating: true as Bool?, count: 15) + Array(repeating: nil as Bool?, count: 15))

        // Now we're going to send RST_STREAM. The RST_STREAM frame should immediately pass through, and all buffered writes should be failed.
        let rstStreamFrame = HTTP2Frame(streamID: 3, payload: .rstStream(.cancel))
        self.channel.write(rstStreamFrame, promise: nil)
        frameRecorder.pendingWrites.assertFramesMatch([rstStreamFrame])
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame] + Array(repeating: subsequentFrame, count: 15))
        XCTAssertEqual(writeStatus, Array(repeating: true as Bool?, count: 15) + Array(repeating: false as Bool?, count: 15))

        // Now we'll flush it. The RST_STREAM frame will be emitted in line with the others.
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame] + Array(repeating: subsequentFrame, count: 15) + [rstStreamFrame])
    }

    func testResetStreamOnBufferingStream() {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 1)).wait())

        // We're going to start stream 1, and then arrange a buffer of a bunch of frames in stream 3. We won't flush stream 3.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(HPACKHeaders([]), nil))
        let subsequentFrame = HTTP2Frame(streamID: 3, payload: .data(.byteBuffer(self.channel.allocator.buffer(capacity: 0))))
        self.channel.writeAndFlush(firstFrame, promise: nil)

        var writeStatus: [Bool?] = Array(repeating: nil, count: 15)
        let writePromises = (0..<15).map { _ in self.channel.write(subsequentFrame) }

        for (idx, promise) in writePromises.enumerated() {
            promise.map {
                writeStatus[idx] = true
            }.whenFailure { error in
                XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: 3, errorCode: .cancel))
                writeStatus[idx] = false
            }
        }

        // No new writes other than the first frame.
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame])
        XCTAssertEqual(writeStatus, Array(repeating: nil as Bool?, count: 15))

        // Now we're going to send RST_STREAM on 3. All writes should fail, *excluding* the RST_STREAM one, which succeeds immediately.
        // No frame is sent through.
        let rstStreamFrame = HTTP2Frame(streamID: 3, payload: .rstStream(.cancel))
        let rstStreamFuture = self.channel.write(rstStreamFrame)
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame])

        XCTAssertEqual(writeStatus, Array(repeating: false as Bool?, count: 15))
        XCTAssertNoThrow(try rstStreamFuture.wait())

        // Flushing changes nothing.
        self.channel.flush()
        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([firstFrame])
    }

    func testGoingBackwardsInStreamIDIsNotAllowed() {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 1)).wait())

        // We're going to create stream 1 and stream 11. Stream 1 will be passed through, stream 11 will have to wait.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(HPACKHeaders([]), nil))
        let elevenFrame = HTTP2Frame(streamID: 11, payload: .headers(HPACKHeaders([]), nil))
        self.channel.write(oneFrame, promise: nil)
        self.channel.write(elevenFrame, promise: nil)
        self.channel.flush()

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([oneFrame])

        // Now we're going to try to write a frame for stream 5. This will fail.
        let fiveFrame = HTTP2Frame(streamID: 5, payload: .headers(HPACKHeaders([]), nil))

        do {
            try self.channel.write(fiveFrame).wait()
            XCTFail("Did not throw")
        } catch is NIOHTTP2Errors.StreamIDTooSmall {
            // Ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFramesForNonLocalStreamIDsAreIgnoredClient() {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .client, initialMaxOutboundStreams: 1)).wait())

        // We're going to create stream 1 and stream 3, which will be buffered.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(HPACKHeaders([]), nil))
        let threeFrame = HTTP2Frame(streamID: 3, payload: .headers(HPACKHeaders([]), nil))
        self.channel.write(oneFrame, promise: nil)
        self.channel.write(threeFrame, promise: nil)
        self.channel.flush()

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([oneFrame])

        // Now we're going to try to write a frame for stream 4, a server-initiated stream. This will be passed through safely.
        let fourFrame = HTTP2Frame(streamID: 4, payload: .headers(HPACKHeaders([]), nil))
        self.channel.writeAndFlush(fourFrame, promise: nil)

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([oneFrame, fourFrame])
    }

    func testFramesForNonLocalStreamIDsAreIgnoredServer() {
        let frameRecorder = OutboundFrameRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(frameRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(NIOHTTP2ConcurrentStreamsHandler(mode: .server, initialMaxOutboundStreams: 1)).wait())

        // We're going to create stream 2 and stream 4. First, however, we reserve them. These are not buffered, per RFC 7540 § 5.1.2:
        //
        // > Streams in either of the "reserved" states do not count toward the stream limit.
        let twoFramePromise = HTTP2Frame(streamID: 1, payload: .pushPromise(2, HPACKHeaders([])))
        let fourFramePromise = HTTP2Frame(streamID: 1, payload: .pushPromise(4, HPACKHeaders([])))
        self.channel.write(twoFramePromise, promise: nil)
        self.channel.write(fourFramePromise, promise: nil)
        self.channel.flush()

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([twoFramePromise, fourFramePromise])

        // Now we're going to try to initiate these by sending HEADERS frames. This will buffer the second one.
        let twoFrame = HTTP2Frame(streamID: 2, payload: .headers(HPACKHeaders([]), nil))
        let fourFrame = HTTP2Frame(streamID: 4, payload: .headers(HPACKHeaders([]), nil))
        self.channel.write(twoFrame, promise: nil)
        self.channel.write(fourFrame, promise: nil)
        self.channel.flush()

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([twoFramePromise, fourFramePromise, twoFrame])

        // Now we're going to try to write a frame for stream 3, a client-initiated stream. This will be passed through safely.
        let threeFrame = HTTP2Frame(streamID: 3, payload: .headers(HPACKHeaders([]), nil))
        self.channel.writeAndFlush(threeFrame, promise: nil)

        XCTAssertEqual(frameRecorder.pendingWrites.count, 0)
        frameRecorder.flushedWrites.assertFramesMatch([twoFramePromise, fourFramePromise, twoFrame, threeFrame])
    }
}
