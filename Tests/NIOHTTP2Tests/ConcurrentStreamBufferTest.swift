//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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

struct TestCaseError: Error { }


// MARK: Helper assertions for outbound frame actions.
// We need these to work around the fact that neither EventLoopPromise or MarkedCircularBuffer have equatable
// conformances.
extension OutboundFrameAction {
    internal func assertForward(file: StaticString = #filePath, line: UInt = #line) {
        guard case .forward = self else {
            XCTFail("Expected .forward, got \(self)", file: (file), line: line)
            return
        }
    }

    internal func assertNothing(file: StaticString = #filePath, line: UInt = #line) {
        guard case .nothing = self else {
            XCTFail("Expected .nothing, got \(self)", file: (file), line: line)
            return
        }
    }

    internal func assertForwardAndDrop(file: StaticString = #filePath, line: UInt = #line) throws -> (MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>, NIOHTTP2Errors.StreamClosed) {
        guard case .forwardAndDrop(let promises, let error) = self else {
            XCTFail("Expected .forwardAndDrop, got \(self)", file: (file), line: line)
            throw TestCaseError()
        }

        return (promises, error)
    }

    internal func assertSucceedAndDrop(file: StaticString = #filePath, line: UInt = #line) throws -> (MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>, NIOHTTP2Errors.StreamClosed) {
        guard case .succeedAndDrop(let promises, let error) = self else {
            XCTFail("Expected .succeedAndDrop, got \(self)", file: (file), line: line)
            throw TestCaseError()
        }

        return (promises, error)
    }
}


final class ConcurrentStreamBufferTests: XCTestCase {
    var loop: EmbeddedEventLoop!

    override func setUp() {
        self.loop = EmbeddedEventLoop()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.loop.syncShutdownGracefully())
        self.loop = nil
    }

    func testBasicFunctionality() throws {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 2)

        // Write frames for three streams.
        let frames = stride(from: 1, through: 5, by: 2).map { HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(.init(headers: HPACKHeaders([])))) }
        let results: [OutboundFrameAction] = try assertNoThrowWithValue(frames.map {
            let result = try manager.processOutboundFrame($0, promise: nil, channelWritable: true)
            if case .forward = result {
                manager.streamCreated($0.streamID)
            }
            return result
        })

        // Only two of these should have been passed through.
        results[0].assertForward()
        results[1].assertForward()
        results[2].assertNothing()

        // Asking for pending writes should do nothing.
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Completing stream 1 should not produce a write yet.
        XCTAssertNil(manager.streamClosed(1))
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Now we flush. This should cause the remaining HEADERS frame to be written.
        manager.flushReceived()
        guard let write = manager.nextFlushedWritableFrame() else {
            XCTFail("Did not flush a frame")
            return
        }
        XCTAssertNil(manager.nextFlushedWritableFrame())

        write.0.assertFrameMatches(this: frames.last!)
        XCTAssertNil(write.1)
    }

    func testToleratesNegativeNumbersOfStreams() throws {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 2)

        // Write frames for three streams and flush them.
        let frames = stride(from: 1, through: 5, by: 2).map { HTTP2Frame(streamID: HTTP2StreamID($0), payload: .headers(.init(headers: HPACKHeaders([])))) }
        let results: [OutboundFrameAction] = try assertNoThrowWithValue(frames.map {
            let result = try manager.processOutboundFrame($0, promise: nil, channelWritable: true)
            if case .forward = result {
                manager.streamCreated($0.streamID)
            }
            return result
        })

        // Only two of these should have been passed through.
        results[0].assertForward()
        results[1].assertForward()
        results[2].assertNothing()

        // Flushing doesn't move anything.
        manager.flushReceived()
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Now we're going to drop the number of allowed concurrent streams to 1.
        manager.maxOutboundStreams = 1

        // No change.
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Write a new stream. This should be buffered.
        let newStreamFrame = HTTP2Frame(streamID: 7, payload: .headers(.init(headers: HPACKHeaders([]), endStream: true)))
        XCTAssertNoThrow(try manager.processOutboundFrame(newStreamFrame, promise: nil, channelWritable: true).assertNothing())
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Complete stream 1. Nothing should happen, as only one stream is allowed through.
        XCTAssertNil(manager.streamClosed(1))
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Now complete another stream. This unblocks the next stream, but only one.
        XCTAssertNil(manager.streamClosed(3))

        guard let write = manager.nextFlushedWritableFrame() else {
            XCTFail("Did not flush a frame")
            return
        }
        XCTAssertNil(manager.nextFlushedWritableFrame())

        write.0.assertFrameMatches(this: frames.last!)
        XCTAssertNil(write.1)
    }

    func testCascadingFrames() throws {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to test a cascade of frames as a result of stream closure. To do this, we set up, let's say, 100
        // streams where all but the first has an END_STREAM frame in it.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))

        let subsequentFrames: [HTTP2Frame] = stride(from: 3, to: 201, by: 2).map { streamID in
            HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: .headers(.init(headers: HPACKHeaders([]), endStream: true)))
        }

        // Write the first frame, and all the subsequent frames, and flush them. This will lead to one flushed frame.
        XCTAssertNoThrow(try manager.processOutboundFrame(firstFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(1)
        for frame in subsequentFrames {
            XCTAssertNoThrow(try manager.processOutboundFrame(frame, promise: nil, channelWritable: true).assertNothing())
        }
        manager.flushReceived()
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Ok, now we're going to tell the buffer that the first stream is closed, and then spin over the manager getting
        // new frames and closing them until there are no more to get.
        var cascadedFrames: [HTTP2Frame] = Array()
        XCTAssertNil(manager.streamClosed(1))

        while let write = manager.nextFlushedWritableFrame() {
            cascadedFrames.append(write.0)
            XCTAssertNil(write.1)
            XCTAssertNil(manager.streamClosed(write.0.streamID))
        }

        subsequentFrames.assertFramesMatch(cascadedFrames)
    }

    func testBufferedFramesPassedThroughOnStreamClosed() {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to start stream 1, and then arrange a buffer of a bunch of frames in stream 3. We'll flush some, but not all of them
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let subsequentFrame = HTTP2Frame(streamID: 3, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        XCTAssertNoThrow(try manager.processOutboundFrame(firstFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(1)

        XCTAssertNoThrow(try (0..<15).forEach { _ in XCTAssertNoThrow(try manager.processOutboundFrame(subsequentFrame, promise: nil, channelWritable: true).assertNothing()) })
        manager.flushReceived()
        XCTAssertNoThrow(try (0..<15).forEach { _ in XCTAssertNoThrow(try manager.processOutboundFrame(subsequentFrame, promise: nil, channelWritable: true).assertNothing()) })

        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Ok, now we're going to unblock stream 3 by completing stream 1.
        XCTAssertNil(manager.streamClosed(1))

        // The flushed writes should all be passed through.
        var flushedFrames: [HTTP2Frame] = Array()
        while let write = manager.nextFlushedWritableFrame() {
            flushedFrames.append(write.0)
            XCTAssertNil(write.1)
        }
        flushedFrames.assertFramesMatch(Array(repeating: subsequentFrame, count: 15))

        // A subsequent flush will drive the rest of the frames through.
        manager.flushReceived()
        while let write = manager.nextFlushedWritableFrame() {
            flushedFrames.append(write.0)
            XCTAssertNil(write.1)
        }
        flushedFrames.assertFramesMatch(Array(repeating: subsequentFrame, count: 30))
    }

    func testResetStreamOnUnbufferingStream() throws {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to start stream 1, and then arrange a buffer of a bunch of frames in stream 3. We'll flush some, but not all of them
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let subsequentFrame = HTTP2Frame(streamID: 3, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        XCTAssertNoThrow(try manager.processOutboundFrame(firstFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(1)

        let writeStatus = NIOLockedValueBox<[Bool?]>(Array(repeating: nil, count: 30))

        var writePromises: [EventLoopFuture<Void>] = try assertNoThrowWithValue((0..<15).map { _ in
            let p = self.loop.makePromise(of: Void.self)
            XCTAssertNoThrow(try manager.processOutboundFrame(subsequentFrame, promise: p, channelWritable: true).assertNothing())
            return p.futureResult
        })
        manager.flushReceived()
        XCTAssertNoThrow(try writePromises.append(contentsOf: (0..<15).map { _ in
            let p = self.loop.makePromise(of: Void.self)
            XCTAssertNoThrow(try manager.processOutboundFrame(subsequentFrame, promise: p, channelWritable: true).assertNothing())
            return p.futureResult
        }))

        for (idx, promise) in writePromises.enumerated() {
            promise.map {
                writeStatus.withLockedValue { writeStatus in
                    writeStatus[idx] = true
                }
            }.whenFailure { error in
                XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .cancel))
                writeStatus.withLockedValue { writeStatus in
                    writeStatus[idx] = false
                }
            }
        }

        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Now we're going to unblock stream 3 by completing stream 1. This will leave our buffer still in place, as we can't
        // pass on the unflushed writes.
        XCTAssertNil(manager.streamClosed(1))

        var flushedFrames: [HTTP2Frame] = Array()
        while let write = manager.nextFlushedWritableFrame() {
            flushedFrames.append(write.0)
            write.1?.succeed(())
        }

        flushedFrames.assertFramesMatch(Array(repeating: subsequentFrame, count: 15))

        // Only the first 15 are done.
        writeStatus.withLockedValue { writeStatus in
            XCTAssertEqual(writeStatus, Array(repeating: true as Bool?, count: 15) + Array(repeating: nil as Bool?, count: 15))
        }

        // Now we're going to write a RST_STREAM frame on stream 3
        let rstStreamFrame = HTTP2Frame(streamID: 3, payload: .rstStream(.cancel))
        let (droppedWrites, error) = try assertNoThrowWithValue(manager.processOutboundFrame(rstStreamFrame, promise: nil, channelWritable: true).assertForwardAndDrop())

        // Fail all these writes.
        for write in droppedWrites {
            write.1?.fail(error)
        }

        XCTAssertEqual(error, NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .cancel))
        writeStatus.withLockedValue { writeStatus in
            XCTAssertEqual(writeStatus, Array(repeating: true as Bool?, count: 15) + Array(repeating: false as Bool?, count: 15))
        }
    }

    func testResetStreamOnBufferingStream() throws {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to start stream 1, and then arrange a buffer of a bunch of frames in stream 3. We won't flush stream 3.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let subsequentFrame = HTTP2Frame(streamID: 3, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        XCTAssertNoThrow(try manager.processOutboundFrame(firstFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(1)

        let writeStatus = NIOLockedValueBox<[Bool?]>(Array(repeating: nil, count: 15))

        let writePromises: [EventLoopFuture<Void>] = try assertNoThrowWithValue((0..<15).map { _ in
            let p = self.loop.makePromise(of: Void.self)
            XCTAssertNoThrow(try manager.processOutboundFrame(subsequentFrame, promise: p, channelWritable: true).assertNothing())
            return p.futureResult
        })

        for (idx, promise) in writePromises.enumerated() {
            promise.map {
                writeStatus.withLockedValue { writeStatus in
                    writeStatus[idx] = true
                }
            }.whenFailure { error in
                XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .cancel))
                writeStatus.withLockedValue { writeStatus in
                    writeStatus[idx] = false
                }
            }
        }

        // No new writes other than the first frame.
        XCTAssertNil(manager.nextFlushedWritableFrame())
        writeStatus.withLockedValue { writeStatus in
            XCTAssertEqual(writeStatus, Array(repeating: nil as Bool?, count: 15))
        }

        // Now we're going to send RST_STREAM on 3. All writes should fail, and we should be asked to drop the RST_STREAM frame.
        let rstStreamFrame = HTTP2Frame(streamID: 3, payload: .rstStream(.cancel))
        let (droppedWrites, error) = try assertNoThrowWithValue(manager.processOutboundFrame(rstStreamFrame, promise: nil, channelWritable: true).assertSucceedAndDrop())

        // Fail all these writes.
        for write in droppedWrites {
            write.1?.fail(error)
        }

        writeStatus.withLockedValue { writeStatus in
            XCTAssertEqual(writeStatus, Array(repeating: false as Bool?, count: 15))
        }

        // Flushing changes nothing.
        manager.flushReceived()
        XCTAssertNil(manager.nextFlushedWritableFrame())
    }

    func testGoingBackwardsInStreamIDIsNotAllowed() {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to create stream 1 and stream 11. Stream 1 will be passed through, stream 11 will have to wait.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let elevenFrame = HTTP2Frame(streamID: 11, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try manager.processOutboundFrame(oneFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(1)
        XCTAssertNoThrow(try manager.processOutboundFrame(elevenFrame, promise: nil, channelWritable: true).assertNothing())

        // Now we're going to try to write a frame for stream 5. This will fail.
        let fiveFrame = HTTP2Frame(streamID: 5, payload: .headers(.init(headers: HPACKHeaders([]))))

        XCTAssertThrowsError(try manager.processOutboundFrame(fiveFrame, promise: nil, channelWritable: true)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.StreamIDTooSmall)
        }
    }

    func testFramesForNonLocalStreamIDsAreIgnoredClient() {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to create stream 1 and stream 3, which will be buffered.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let threeFrame = HTTP2Frame(streamID: 3, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try manager.processOutboundFrame(oneFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(1)
        XCTAssertNoThrow(try manager.processOutboundFrame(threeFrame, promise: nil, channelWritable: true).assertNothing())

        // Now we're going to try to write a frame for stream 4, a server-initiated stream. This will be passed through safely.
        let fourFrame = HTTP2Frame(streamID: 4, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try manager.processOutboundFrame(fourFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(4)

        XCTAssertEqual(manager.currentOutboundStreams, 1)
    }

    func testFramesForNonLocalStreamIDsAreIgnoredServer() {
        var manager = ConcurrentStreamBuffer(mode: .server, initialMaxOutboundStreams: 1)

        // We're going to create stream 2 and stream 4. First, however, we reserve them. These are not buffered, per RFC 7540 § 5.1.2:
        //
        // > Streams in either of the "reserved" states do not count toward the stream limit.
        let twoFramePromise = HTTP2Frame(streamID: 1, payload: .pushPromise(.init(pushedStreamID: 2, headers: HPACKHeaders([]))))
        let fourFramePromise = HTTP2Frame(streamID: 1, payload: .pushPromise(.init(pushedStreamID: 4, headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try manager.processOutboundFrame(twoFramePromise, promise: nil, channelWritable: true).assertForward())
        XCTAssertNoThrow(try manager.processOutboundFrame(fourFramePromise, promise: nil, channelWritable: true).assertForward())

        // Now we're going to try to initiate these by sending HEADERS frames. This will buffer the second one.
        let twoFrame = HTTP2Frame(streamID: 2, payload: .headers(.init(headers: HPACKHeaders([]))))
        let fourFrame = HTTP2Frame(streamID: 4, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try manager.processOutboundFrame(twoFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(2)
        XCTAssertNoThrow(try manager.processOutboundFrame(fourFrame, promise: nil, channelWritable: true).assertNothing())

        // Now we're going to try to write a frame for stream 3, a client-initiated stream. This will be passed through safely.
        let threeFrame = HTTP2Frame(streamID: 3, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try manager.processOutboundFrame(threeFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(3)

        XCTAssertEqual(manager.currentOutboundStreams, 1)
    }

    func testDropsFramesOnStreamClosure() throws {
        // Here we're going to buffer up a bunch of frames, pull one out, and then close the stream. This should drop the frames.
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to start stream 1, and then arrange a buffer of a bunch of frames in stream 3.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let subsequentFrame = HTTP2Frame(streamID: 3, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        XCTAssertNoThrow(try manager.processOutboundFrame(firstFrame, promise: nil, channelWritable: true).assertForward())
        manager.streamCreated(1)

        let writeStatus = NIOLockedValueBox<[Bool?]>(Array(repeating: nil, count: 15))
        let writePromises: [EventLoopFuture<Void>] = try assertNoThrowWithValue((0..<15).map { _ in
            let p = self.loop.makePromise(of: Void.self)
            XCTAssertNoThrow(try manager.processOutboundFrame(subsequentFrame, promise: p, channelWritable: true).assertNothing())
            return p.futureResult
        })
        for (idx, promise) in writePromises.enumerated() {
            promise.map {
                writeStatus.withLockedValue { writeStatus in
                    writeStatus[idx] = true
                }
            }.whenFailure { error in
                XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .protocolError))
                writeStatus.withLockedValue { writeStatus in
                    writeStatus[idx] = false
                }
            }
        }
        manager.flushReceived()
        XCTAssertNil(manager.nextFlushedWritableFrame())

        // Ok, now we're going to unblock stream 3 by completing stream 1.
        XCTAssertNil(manager.streamClosed(1))

        // Let's now start stream 3.
        manager.streamCreated(3)

        // Now, let's close stream 3.
        guard let droppedFrames = manager.streamClosed(3) else {
            XCTFail("Didn't return dropped frames")
            return
        }
        for (_, promise) in droppedFrames {
            promise?.fail(NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .protocolError))
        }

        writeStatus.withLockedValue { writeStatus in
            XCTAssertEqual(writeStatus, Array(repeating: false, count: 15))
        }
    }

    func testBufferingWithBlockedChannel() throws {
        var manager = ConcurrentStreamBuffer(mode: .client, initialMaxOutboundStreams: 100)

        // Write a frame for the first stream. This will be buffered, as the connection isn't writable.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try manager.processOutboundFrame(firstFrame, promise: nil, channelWritable: false).assertNothing())

        // Write a frame for the second stream. This should also be buffered, as the connection still isn't writable.
        let secondFrame = HTTP2Frame(streamID: 3, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try manager.processOutboundFrame(secondFrame, promise: nil, channelWritable: false).assertNothing())

        manager.flushReceived()

        // Grab a pending write, simulating the connection becoming writable.
        guard let firstWritableFrame = manager.nextFlushedWritableFrame() else {
            XCTFail("Did not write frame")
            return
        }
        firstWritableFrame.0.assertFrameMatches(this: firstFrame)
        manager.streamCreated(1)

        // Now write a frame for stream 5. Even though the connection is writable, this should be buffered.
        let thirdFrame = HTTP2Frame(streamID: 5, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try manager.processOutboundFrame(thirdFrame, promise: nil, channelWritable: true).assertNothing())

        // Now we're going to try to write data once to each stream, simulating the channel being blocked. Stream 1 should
        // progress, as the stream is actually open, while the writes for stream 3 and 5 should be buffered.
        let fourthFrame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        XCTAssertNoThrow(try manager.processOutboundFrame(fourthFrame, promise: nil, channelWritable: true).assertForward())

        let fifthFrame = HTTP2Frame(streamID: 3, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        XCTAssertNoThrow(try manager.processOutboundFrame(fifthFrame, promise: nil, channelWritable: true).assertNothing())

        let sixthFrame = HTTP2Frame(streamID: 5, payload: .data(.init(data: .byteBuffer(ByteBufferAllocator().buffer(capacity: 0)))))
        XCTAssertNoThrow(try manager.processOutboundFrame(sixthFrame, promise: nil, channelWritable: true).assertNothing())

        manager.flushReceived()

        // Now the remaining frames should come out.
        var frames = [HTTP2Frame]()
        while let frame = manager.nextFlushedWritableFrame() {
            frames.append(frame.0)
        }
        frames.assertFramesMatch([secondFrame, fifthFrame, thirdFrame, sixthFrame])
    }
}
