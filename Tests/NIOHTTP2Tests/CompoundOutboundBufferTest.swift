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
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 100)

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
            XCTAssertNoThrow(try buffer.processOutboundFrame(frame, promise: nil).assertForward(), "Threw on \(frame)")
        }
    }

    func testSimpleOutboundStreamBuffering() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // Let's create 100 new outbound streams.
        let firstFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let subsequentFrames: [HTTP2Frame] = stride(from: 3, to: 201, by: 2).map { streamID in
            HTTP2Frame(streamID: HTTP2StreamID(streamID), payload: .headers(.init(headers: HPACKHeaders([]), endStream: true)))
        }

        // Write the first frame, and all the subsequent frames, and flush them. This will lead to one flushed frame.
        XCTAssertNoThrow(try buffer.processOutboundFrame(firstFrame, promise: nil).assertForward())
        buffer.streamCreated(1, initialWindowSize: 65535)
        for frame in subsequentFrames {
            XCTAssertNoThrow(try buffer.processOutboundFrame(frame, promise: nil).assertNothing())
        }
        buffer.flushReceived()
        buffer.nextFlushedWritableFrame().assertNoFrame()

        // Ok, now we're going to tell the buffer that the first stream is closed, and then spin over the buffer getting
        // new frames and closing them until there are no more to get.
        var newFrames: [HTTP2Frame] = Array()
        XCTAssertEqual(buffer.streamClosed(1).count, 0)

        while case .frame(let write) = buffer.nextFlushedWritableFrame() {
            newFrames.append(write.0)
            XCTAssertNil(write.1)
            buffer.streamCreated(write.0.streamID, initialWindowSize: 65535)
            XCTAssertEqual(buffer.streamClosed(write.0.streamID).count, 0)
        }

        subsequentFrames.assertFramesMatch(newFrames)
    }

    func testSimpleFlowControlBuffering() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1)
        let streamOne = HTTP2StreamID(1)
        buffer.streamCreated(streamOne, initialWindowSize: 15)

        var frame = self.createDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertNoThrow(try buffer.processOutboundFrame(frame, promise: nil).assertNothing())

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
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // We're going to create stream 1 and stream 11. Stream 1 will be passed through, stream 11 will have to wait.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let elevenFrame = HTTP2Frame(streamID: 11, payload: .headers(.init(headers: HPACKHeaders([]))))
        XCTAssertNoThrow(try buffer.processOutboundFrame(oneFrame, promise: nil).assertForward())
        buffer.streamCreated(1, initialWindowSize: 15)
        XCTAssertNoThrow(try buffer.processOutboundFrame(elevenFrame, promise: nil).assertNothing())

        // Now we're going to try to write a frame for stream 5. This will fail.
        let fiveFrame = HTTP2Frame(streamID: 5, payload: .headers(.init(headers: HPACKHeaders([]))))

        do {
            _ = try buffer.processOutboundFrame(fiveFrame, promise: nil)
            XCTFail("Did not throw")
        } catch is NIOHTTP2Errors.StreamIDTooSmall {
            // Ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFlowControlStreamThrows() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1)
        let streamOne = HTTP2StreamID(1)

        let frame = self.createDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertThrowsError(try buffer.processOutboundFrame(frame, promise: nil)) {
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
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1)

        // Create two streams. The first proceeds, the second does not. The second stream is actually created with a data
        // frame, which is a violation of what is required by the flow control buffer.
        let oneFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]))))
        let dataFrame = self.createDataFrame(3, byteBufferSize: 15)
        XCTAssertNoThrow(try buffer.processOutboundFrame(oneFrame, promise: nil).assertForward())
        buffer.streamCreated(1, initialWindowSize: 15)
        XCTAssertNoThrow(try buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        buffer.flushReceived()

        buffer.nextFlushedWritableFrame().assertNoFrame()

        // Ok, now we complete stream 1. This makes the next frame elegible for emission.
        XCTAssertEqual(buffer.streamClosed(1).count, 0)
        buffer.nextFlushedWritableFrame().assertError(NIOHTTP2Errors.NoSuchStream(streamID: 3))
    }

    func testBufferedFrameDrops() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1)

        var results: [Bool?] = Array(repeating: nil as Bool?, count: 4)
        var futures: [EventLoopFuture<Void>] = []

        // Write in a bunch of frames, which will get buffered.
        for streamID in [HTTP2StreamID(1), HTTP2StreamID(3)] {
            let startFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: HPACKHeaders([]))))
            let dataFrame = self.createDataFrame(streamID, byteBufferSize: 50)

            let startPromise = self.loop.makePromise(of: Void.self)
            let dataPromise = self.loop.makePromise(of: Void.self)
            if streamID == 1 {
                XCTAssertNoThrow(try buffer.processOutboundFrame(startFrame, promise: startPromise).assertForward())
                startPromise.succeed(())
                buffer.streamCreated(streamID, initialWindowSize: 65535)
            } else {
                XCTAssertNoThrow(try buffer.processOutboundFrame(startFrame, promise: startPromise).assertNothing())
            }

            XCTAssertNoThrow(try buffer.processOutboundFrame(dataFrame, promise: dataPromise).assertNothing())
            futures.append(contentsOf: [startPromise.futureResult, dataPromise.futureResult])
        }

        for (idx, future) in futures.enumerated() {
            future.map {
                results[idx] = true
            }.whenFailure { error in
                XCTAssertEqual(error as? NIOHTTP2Errors.StreamClosed, NIOHTTP2Errors.StreamClosed(streamID: 3, errorCode: .protocolError))
                results[idx] = false
            }
        }

        // Ok, mark the flush point.
        buffer.flushReceived()
        XCTAssertEqual(results, [true, nil, nil, nil])

        // Now, fail stream one.
        for promise in buffer.streamClosed(1) {
            promise?.fail(NIOHTTP2Errors.StreamClosed(streamID: 3, errorCode: .protocolError))
        }
        XCTAssertEqual(results, [true, false, nil, nil])

        // Now fail stream three.
        for promise in buffer.streamClosed(3) {
            promise?.fail(NIOHTTP2Errors.StreamClosed(streamID: 3, errorCode: .protocolError))
        }
        XCTAssertEqual(results, [true, false, false, false])
    }

    func testRejectsPrioritySelfDependency() {
        var buffer = CompoundOutboundBuffer(mode: .client, initialMaxOutboundStreams: 1)

        XCTAssertThrowsError(try buffer.priorityUpdate(streamID: 1, priorityData: .init(exclusive: false, dependency: 1, weight: 36))) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.PriorityCycle(streamID: 1))
        }
        XCTAssertThrowsError(try buffer.priorityUpdate(streamID: 1, priorityData: .init(exclusive: true, dependency: 1, weight: 36))) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.PriorityCycle(streamID: 1))
        }
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
    fileprivate mutating func receivedFrames(file: StaticString = #file, line: UInt = #line) -> [HTTP2Frame] {
        var receivedFrames: [HTTP2Frame] = Array()

        loop: while true {
            switch self.nextFlushedWritableFrame() {
            case .noFrame:
                break loop
            case .frame(let bufferedFrame, let promise):
                receivedFrames.append(bufferedFrame)
                promise?.succeed(())
            case .error(let promise, let error):
                promise?.fail(error)
                XCTFail("Caught error: \(error)", file: file, line: line)
            }
        }

        return receivedFrames
    }
}

extension CompoundOutboundBuffer.FlushedWritableFrameResult {
    internal func assertNoFrame(file: StaticString = #file, line: UInt = #line) {
        guard case .noFrame = self else {
            XCTFail("Expected .noFrame, got \(self)", file: file, line: line)
            return
        }
    }

    internal func assertError<ErrorType: Error & Equatable>(_ error: ErrorType, file: StaticString = #file, line: UInt = #line) {
        guard case .error(let promise, let thrownError) = self else {
            XCTFail("Expected .error, got \(self)", file: file, line: line)
            return
        }

        guard let castError = thrownError as? ErrorType, castError == error else {
            XCTFail("Expected \(error), got \(thrownError)", file: file, line: line)
            return
        }

        promise?.fail(error)
    }
}
