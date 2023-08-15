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

final class CompoundOutboundBufferTest: XCTestCase {
    var loop: EmbeddedEventLoop!

    override func setUp() {
        self.loop = EmbeddedEventLoop()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.loop.syncShutdownGracefully())
        self.loop = nil
    }

    func testSimpleControlFramePassthrough() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 100, maxBufferedControlFrames: 1000)

        let frames: [HTTP2Frame] = [
            HTTP2Frame(streamID: .rootStream, payload: .ping(.init(withInteger: 0), ack: true)),
            HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: 0, errorCode: .protocolError, opaqueData: nil)),
            HTTP2Frame(streamID: .rootStream, payload: .settings(.settings([]))),
            HTTP2Frame(streamID: .rootStream, payload: .alternativeService(origin: nil, field: nil)),
            HTTP2Frame(streamID: .rootStream, payload: .origin([])),
            HTTP2Frame(streamID: 1, payload: .priority(.init(exclusive: true, dependency: 0, weight: 200))),
            HTTP2Frame(streamID: 1, payload: .rstStream(.protocolError)),
        ]

        for frame in frames {
            XCTAssertNoThrow(try buffer.processOutboundFrame(frame, promise: nil, channelWritable: true).assertForward(), "Threw on \(frame)")
        }
    }

    func testSimpleOutboundStreamBuffering() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        // Let's create 100 new outbound streams.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let subsequentFrames: [HTTP2Frame] = stride(from: 3, to: 201, by: 2).map { streamID in
            HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: .headers(.init(headers: HPACKHeaders([]), endStream: true)))
        }

        // Write the first frame, and all the subsequent frames, and flush them. This will lead to one flushed frame.
        XCTAssertNoThrow(try buffer.processOutboundFrame(firstFrame, promise: nil, channelWritable: true).assertForward())
        buffer.streamCreated(1, initialWindowSize: 65535)
        for frame in subsequentFrames {
            XCTAssertNoThrow(try buffer.processOutboundFrame(frame, promise: nil, channelWritable: true).assertNothing())
        }
        buffer.flushReceived()
        buffer.nextFlushedWritableFrame(channelWritable: true).assertNoFrame()

        // Ok, now we're going to tell the buffer that the first stream is closed, and then spin over the buffer getting
        // new frames and closing them until there are no more to get.
        var newFrames: [HTTP2Frame] = Array()
        XCTAssertEqual(buffer.streamClosed(1).count, 0)

        while case .frame(let frame, let promise) = buffer.nextFlushedWritableFrame(channelWritable: true) {
            newFrames.append(frame)
            XCTAssertNil(promise)
            buffer.streamCreated(frame.streamID, initialWindowSize: 65535)
            XCTAssertEqual(buffer.streamClosed(frame.streamID).count, 0)
        }

        subsequentFrames.assertFramesMatch(newFrames)
    }

    func testSimpleFlowControlBuffering() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)
        let streamOne = HTTP2StreamID(1)
        buffer.streamCreated(streamOne, initialWindowSize: 15)

        var frame = self.createDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertNoThrow(try buffer.processOutboundFrame(frame, promise: nil, channelWritable: true).assertNothing())

        buffer.flushReceived()
        buffer.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)])

        // Update the window.
        buffer.updateStreamWindow(streamOne, newSize: 20)
        buffer.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 20)])

        // And again, we get the rest.
        buffer.updateStreamWindow(streamOne, newSize: 20)
        buffer.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)])
    }

    func testConcurrentStreamErrorThrows() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        // We're going to create stream 1 and stream 11. Stream 1 will be passed through, stream 11 will have to wait.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let elevenFrame = HTTP2Frame(streamID: 11, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try buffer.processOutboundFrame(oneFrame, promise: nil, channelWritable: true).assertForward())
        buffer.streamCreated(1, initialWindowSize: 15)
        XCTAssertNoThrow(try buffer.processOutboundFrame(elevenFrame, promise: nil, channelWritable: true).assertNothing())

        // Now we're going to try to write a frame for stream 5. This will fail.
        let fiveFrame = HTTP2Frame(streamID: 5, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertThrowsError(try buffer.processOutboundFrame(fiveFrame, promise: nil, channelWritable: true)) {error in
            XCTAssertTrue(error is NIOHTTP2Errors.StreamIDTooSmall)
        }
    }

    func testFlowControlStreamThrows() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)
        let streamOne = HTTP2StreamID(1)

        let frame = self.createDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertThrowsError(try buffer.processOutboundFrame(frame, promise: nil, channelWritable: true)) {
            guard let err = $0 as? NIOHTTP2Errors.NoSuchStream else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
        }
    }

    func testDelayedFlowControlStreamErrors() {
        // This is like testFlowControlStreamThrows, but we delay this behind a concurrentStreams buffer such that
        // it appears during nextFlushedWritableFrame.
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        // Create two streams. The first proceeds, the second does not. The second stream is actually created with a data
        // frame, which is a violation of what is required by the flow control buffer.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let dataFrame = self.createDataFrame(3, byteBufferSize: 15)
        XCTAssertNoThrow(try buffer.processOutboundFrame(oneFrame, promise: nil, channelWritable: true).assertForward())
        buffer.streamCreated(1, initialWindowSize: 15)
        XCTAssertNoThrow(try buffer.processOutboundFrame(dataFrame, promise: nil, channelWritable: true).assertNothing())
        buffer.flushReceived()

        buffer.nextFlushedWritableFrame(channelWritable: true).assertNoFrame()

        // Ok, now we complete stream 1. This makes the next frame elegible for emission.
        XCTAssertEqual(buffer.streamClosed(1).count, 0)
        buffer.nextFlushedWritableFrame(channelWritable: true).assertError(NIOHTTP2Errors.noSuchStream(streamID: 3))
    }

    func testBufferedFrameDrops() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        let results = NIOLockedValueBox<[Bool?]>(Array(repeating: nil as Bool?, count: 4))
        var futures: [EventLoopFuture<Void>] = []

        // Write in a bunch of frames, which will get buffered.
        for streamID in [HTTP2StreamID(1), HTTP2StreamID(3)] {
            let startFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders([]))))
            let dataFrame = self.createDataFrame(streamID, byteBufferSize: 50)

            let startPromise = self.loop.makePromise(of: Void.self)
            let dataPromise = self.loop.makePromise(of: Void.self)
            if streamID == 1 {
                XCTAssertNoThrow(try buffer.processOutboundFrame(startFrame, promise: startPromise, channelWritable: true).assertForward())
                startPromise.succeed(())
                buffer.streamCreated(streamID, initialWindowSize: 65535)
            } else {
                XCTAssertNoThrow(try buffer.processOutboundFrame(startFrame, promise: startPromise, channelWritable: true).assertNothing())
            }

            XCTAssertNoThrow(try buffer.processOutboundFrame(dataFrame, promise: dataPromise, channelWritable: true).assertNothing())
            futures.append(contentsOf: [startPromise.futureResult, dataPromise.futureResult])
        }

        for (idx, future) in futures.enumerated() {
            future.map {
                results.withLockedValue { results in
                    results[idx] = true
                }
            }.whenFailure { error in
                XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .protocolError))
                results.withLockedValue { results in
                    results[idx] = false
                }
            }
        }

        // Ok, mark the flush point.
        buffer.flushReceived()
        results.withLockedValue { results in
            XCTAssertEqual(results, [true, nil, nil, nil])
        }

        // Now, fail stream one.
        for promise in buffer.streamClosed(1) {
            promise?.fail(NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .protocolError))
        }
        results.withLockedValue { results in
            XCTAssertEqual(results, [true, false, nil, nil])
        }

        // Now fail stream three.
        for promise in buffer.streamClosed(3) {
            promise?.fail(NIOHTTP2Errors.streamClosed(streamID: 3, errorCode: .protocolError))
        }
        results.withLockedValue { results in
            XCTAssertEqual(results, [true, false, false, false])
        }
    }

    func testRejectsPrioritySelfDependency() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        XCTAssertThrowsError(try buffer.priorityUpdate(streamID: 1, priorityData: .init(exclusive: false, dependency: 1, weight: 36))) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.priorityCycle(streamID: 1))
        }
        XCTAssertThrowsError(try buffer.priorityUpdate(streamID: 1, priorityData: .init(exclusive: true, dependency: 1, weight: 36))) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.priorityCycle(streamID: 1))
        }
    }

    func testBufferedFlushedFrameBufferingBehindFlowControl() {
        // This is a test that hits an edge case occasionally spotted under high load.
        // Specifically, this test catches the case where we have a flushed DATA frame buffered in the concurrent streams
        // buffer that gets unbuffered from there, and rebuffered into the flow control buffer. In this instance, the
        // buggy effect will be for this frame to get "stuck", as we were failing to propgate the fact that the frame
        // is flushed.
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        // Shrink the connection window size.
        buffer.connectionWindowSize = 5

        // Now, prepare our four frames. We'll open a stream and consume the connection window, then
        // attempt to open another stream and send a data frame. The second two frames must buffer.
        let firstHeaders = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let firstData = self.createDataFrame(1, byteBufferSize: 5)
        let secondHeaders = HTTP2Frame(streamID: 3, payload: .headers(.init(headers: HPACKHeaders([]))))
        let secondData = self.createDataFrame(3, byteBufferSize: 5)

        XCTAssertNoThrow(try buffer.processOutboundFrame(firstHeaders, promise: nil, channelWritable: true).assertForward())
        buffer.streamCreated(1, initialWindowSize: 65535)
        XCTAssertNoThrow(try buffer.processOutboundFrame(firstData, promise: nil, channelWritable: true).assertNothing())

        XCTAssertNoThrow(try buffer.processOutboundFrame(secondHeaders, promise: nil, channelWritable: true).assertNothing())
        XCTAssertNoThrow(try buffer.processOutboundFrame(secondData, promise: nil, channelWritable: true).assertNothing())

        // Now mark them flushed.
        buffer.flushReceived()

        // Now grab that first data frame and consume the connection window.
        guard case .frame(let firstUnbufferedFrame, _) = buffer.nextFlushedWritableFrame(channelWritable: true) else {
            XCTFail("Did not unbuffer a data frame")
            return
        }
        buffer.connectionWindowSize = 0
        firstUnbufferedFrame.assertFrameMatches(this: firstData)

        // Now complete the first stream.
        XCTAssertEqual(buffer.streamClosed(1).count, 0)

        // Ask for the next frame, which should be the headers.
        guard case .frame(let secondUnbufferedFrame, _) = buffer.nextFlushedWritableFrame(channelWritable: true) else {
            XCTFail("Did not unbuffer a headers frame")
            return
        }
        buffer.streamCreated(3, initialWindowSize: 65535)
        secondUnbufferedFrame.assertFrameMatches(this: secondHeaders)

        // The second frame must not unbuffer, as there is no room in the connection window.
        guard case .noFrame = buffer.nextFlushedWritableFrame(channelWritable: true) else {
            XCTFail("Emitted a frame unexpectedly")
            return
        }

        // Now increase the connection window size. This should free up the frame.
        buffer.connectionWindowSize = 5
        guard case .frame(let thirdUnbufferedFrame, _) = buffer.nextFlushedWritableFrame(channelWritable: true) else {
            XCTFail("Did not unbuffer a data frame")
            return
        }
        thirdUnbufferedFrame.assertFrameMatches(this: secondData)
    }

    func testFailingAllPromisesOnClose() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        let results = NIOLockedValueBox<[Bool?]>(Array(repeating: nil as Bool?, count: 5))
        var futures: [EventLoopFuture<Void>] = []

        // Write in a bunch of frames, which will get buffered.
        for streamID in [HTTP2StreamID(1), HTTP2StreamID(3)] {
            let startFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders([]))))
            let dataFrame = self.createDataFrame(streamID, byteBufferSize: 50)

            let startPromise = self.loop.makePromise(of: Void.self)
            let dataPromise = self.loop.makePromise(of: Void.self)
            if streamID == 1 {
                XCTAssertNoThrow(try buffer.processOutboundFrame(startFrame, promise: startPromise, channelWritable: true).assertForward())
                startPromise.succeed(())
                buffer.streamCreated(streamID, initialWindowSize: 65535)
            } else {
                XCTAssertNoThrow(try buffer.processOutboundFrame(startFrame, promise: startPromise, channelWritable: true).assertNothing())
            }

            XCTAssertNoThrow(try buffer.processOutboundFrame(dataFrame, promise: dataPromise, channelWritable: true).assertNothing())
            futures.append(contentsOf: [startPromise.futureResult, dataPromise.futureResult])
        }

        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(.init(withInteger: 0), ack: false))
        let pingPromise = self.loop.makePromise(of: Void.self)
        XCTAssertNoThrow(try buffer.processOutboundFrame(pingFrame, promise: pingPromise, channelWritable: false).assertNothing())
        futures.append(pingPromise.futureResult)

        for (idx, future) in futures.enumerated() {
            future.map {
                results.withLockedValue { results in
                    results[idx] = false
                }
            }.whenFailure { error in
                XCTAssertEqual(error as? ChannelError, ChannelError.ioOnClosedChannel)
                results.withLockedValue { results in
                    results[idx] = true
                }
            }
        }

        results.withLockedValue { results in
            XCTAssertEqual(results, [false, nil, nil, nil, nil])
        }

        // Now, invalidate the buffer.
        buffer.invalidateBuffer()
        results.withLockedValue { results in
            XCTAssertEqual(results, [false, true, true, true, true])
        }
    }

    func testBufferedControlFramesAreEmittedPreferentiallyToOtherFrames() {
        // We're going to buffera DATA frame and a control frame, then attempt to emit them and confirm they
        // come out in the right order.
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1, maxBufferedControlFrames: 1000)

        // Send a HEADERS frame through to open up a space in the flow control buffer.
        let startFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders())))
        XCTAssertNoThrow(try buffer.processOutboundFrame(startFrame, promise: nil, channelWritable: true).assertForward())
        buffer.streamCreated(1, initialWindowSize: 65535)

        // Send a DATA frame. This is buffered.
        let dataFrame = self.createDataFrame(1, byteBufferSize: 50)
        XCTAssertNoThrow(try buffer.processOutboundFrame(dataFrame, promise: nil, channelWritable: true).assertNothing())

        // Send in a PING frame which will be buffered.
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(.init(withInteger: 9), ack: false))
        XCTAssertNoThrow(try buffer.processOutboundFrame(pingFrame, promise: nil, channelWritable: false).assertNothing())

        buffer.flushReceived()

        // Now attempt to unbuffer the frames.
        guard case .frame(let firstFrame, _) = buffer.nextFlushedWritableFrame(channelWritable: true) else {
            XCTFail("Didn't get expected frame")
            return
        }
        firstFrame.assertFrameMatches(this: pingFrame)

        guard case .frame(let secondFrame, _) = buffer.nextFlushedWritableFrame(channelWritable: true) else {
            XCTFail("Didn't get expected frame")
            return
        }
        secondFrame.assertFrameMatches(this: dataFrame)
    }
}


extension CompoundOutboundBufferTest {
    func createDataFrame(_ streamID: HTTP2StreamID, byteBufferSize: Int) -> HTTP2Frame {
        var buffer = ByteBufferAllocator().buffer(capacity: byteBufferSize)
        buffer.writeBytes(repeatElement(UInt8(0xff), count: byteBufferSize))
        return HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer))))
    }
}

extension CompoundOutboundBuffer {
    fileprivate mutating func receivedFrames(file: StaticString = #filePath, line: UInt = #line) -> [HTTP2Frame] {
        var receivedFrames: [HTTP2Frame] = Array()

    loop: while true {
        switch self.nextFlushedWritableFrame(channelWritable: true) {
        case .noFrame:
            break loop
        case .frame(let bufferedFrame, let promise):
            receivedFrames.append(bufferedFrame)
            promise?.succeed(())
        case .error(let promise, let error):
            promise?.fail(error)
            XCTFail("Caught error: \(error)", file: (file), line: line)
        }
    }

        return receivedFrames
    }
}

extension CompoundOutboundBuffer.FlushedWritableFrameResult {
    internal func assertNoFrame(file: StaticString = #filePath, line: UInt = #line) {
        guard case .noFrame = self else {
            XCTFail("Expected .noFrame, got \(self)", file: (file), line: line)
            return
        }
    }

    internal func assertError<ErrorType: Error & Equatable>(_ error: ErrorType, file: StaticString = #filePath, line: UInt = #line) {
        guard case .error(let promise, let thrownError) = self else {
            XCTFail("Expected .error, got \(self)", file: (file), line: line)
            return
        }

        guard let castError = thrownError as? ErrorType, castError == error else {
            XCTFail("Expected \(error), got \(thrownError)", file: (file), line: line)
            return
        }

        promise?.fail(error)
    }
}
