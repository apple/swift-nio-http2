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
import Atomics
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import NIOHTTP2
import NIOHPACK


class OutboundFlowControlBufferTests: XCTestCase {
    var loop: EmbeddedEventLoop!
    var buffer: OutboundFlowControlBuffer!

    override func setUp() {
        self.loop = EmbeddedEventLoop()
        self.buffer = OutboundFlowControlBuffer()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.loop.syncShutdownGracefully())
        self.loop = nil
        self.buffer = nil
    }

    private func makeWritePromise() -> EventLoopPromise<Void> {
        return self.loop.makePromise()
    }

    private func receivedFrames(file: StaticString = #filePath, line: UInt = #line) -> [HTTP2Frame] {
        var receivedFrames: [HTTP2Frame] = Array()

        while let (bufferedFrame, promise) = self.buffer.nextFlushedWritableFrame() {
            receivedFrames.append(bufferedFrame)
            promise?.succeed(())
        }

        return receivedFrames
    }

    func testJustLettingDataThrough() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        let frame = self.createDataFrame(streamOne, byteBufferSize: 15)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())

        XCTAssertNil(self.buffer.nextFlushedWritableFrame())

        self.buffer.flushReceived()
        guard let (bufferedFrame, promise) = self.buffer.nextFlushedWritableFrame() else {
            XCTFail("Did not produce frame")
            return
        }
        bufferedFrame.assertFrameMatches(this: frame)
        XCTAssertNil(promise)
        XCTAssertNil(self.buffer.nextFlushedWritableFrame())
    }

    func testSimpleFramesKeepBoundaries() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        let frame = self.createDataFrame(streamOne, byteBufferSize: 5)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())
        XCTAssertNil(self.buffer.nextFlushedWritableFrame())

        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([frame, frame, frame])
    }

    func testOverlargeFramesAreSplitByteBuffer() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        var frame = self.createDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())

        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)])

        // Update the window.
        self.buffer.updateWindowOfStream(streamOne, newSize: 20)
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 20)])

        // And again, we get the rest.
        self.buffer.updateWindowOfStream(streamOne, newSize: 20)
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)])
    }

    func testOverlargeFramesAreSplitFileRegion() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        var frame = self.createDataFrame(streamOne, fileRegionSize: 50)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())

        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)], dataFileRegionToByteBuffer: false)

        // Update the window.
        self.buffer.updateWindowOfStream(streamOne, newSize: 20)
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 20)], dataFileRegionToByteBuffer: false)

        // And again, we get the rest.
        self.buffer.updateWindowOfStream(streamOne, newSize: 20)
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)], dataFileRegionToByteBuffer: false)
    }

    func testIgnoresNonDataFramesForStream() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        // Let's start by consuming the window.
        let frame = self.createDataFrame(streamOne, byteBufferSize: 15)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([frame])

        // Now we send another data frame to buffer.
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())

        // We also send a WindowUpdate frame, a RST_STREAM frame, and a PRIORITY frame.
        let windowUpdateFrame = HTTP2Frame(streamID: streamOne, payload: .windowUpdate(windowSizeIncrement: 500))
        let priorityFrame = HTTP2Frame(streamID: streamOne, payload: .priority(.init(exclusive: false, dependency: 0, weight: 50)))
        let rstStreamFrame = HTTP2Frame(streamID: streamOne, payload: .rstStream(.protocolError))

        // All of these frames are written.
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(windowUpdateFrame, promise: nil).assertForward())
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(priorityFrame, promise: nil).assertForward())
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(rstStreamFrame, promise: nil).assertForward())

        // But the DATA frame is not.
        XCTAssertEqual(self.receivedFrames().count, 0)

        // Even when we flush.
        self.buffer.flushReceived()
        XCTAssertEqual(self.receivedFrames().count, 0)

        // Unless we open the window.
        self.buffer.updateWindowOfStream(1, newSize: 20)
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([frame])
    }

    func testProperlyDelaysENDSTREAMFlag() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        // We send a large DATA frame here.
        let frameWritten = ManagedAtomic<Bool>(false)
        let framePromise: EventLoopPromise<Void> = self.loop.makePromise()
        framePromise.futureResult.map {
            frameWritten.store(true, ordering: .sequentiallyConsistent)
        }.whenFailure {
            XCTFail("Unexpected write failure: \($0)")
        }

        var frame = self.createDataFrame(streamOne, byteBufferSize: 50, endStream: true)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: framePromise).assertNothing())
        XCTAssertFalse(frameWritten.load(ordering: .sequentiallyConsistent))

        // Flush out the first frame.
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)])
        XCTAssertFalse(frameWritten.load(ordering: .sequentiallyConsistent))

        // Open the window, we get the second frame.
        self.buffer.updateWindowOfStream(streamOne, newSize: 34)
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 34)])
        XCTAssertFalse(frameWritten.load(ordering: .sequentiallyConsistent))

        // If we open again, we get the final frame, with endStream set.
        self.buffer.updateWindowOfStream(streamOne, newSize: 200)
        self.receivedFrames().assertFramesMatch([frame])
        XCTAssertTrue(frameWritten.load(ordering: .sequentiallyConsistent))
    }

    func testInterlacingWithHeaders() {
        // The purpose of this test is to validate that headers frames after the first DATA frame are appropriately queued.
        let streamOne = HTTP2StreamID(1)

        // Start by sending a headers frame through, even before createStream is fired. This should pass unmolested.
        let headers = HTTP2Frame(streamID: streamOne, payload: .headers(.init(headers: HPACKHeaders([("name", "value")]))))
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(headers, promise: nil).assertForward())

        // Now send createStream, and another headers frame. This is also fine.
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(headers, promise: nil).assertForward())

        // Now send a large DATA frame that is going to be buffered, followed by a HEADERS frame.
        let endHeaders = HTTP2Frame(streamID: streamOne, payload: .headers(.init(headers: HPACKHeaders([("name", "value")]), endStream: true)))
        var frame = self.createDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(frame, promise: nil).assertNothing())
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(endHeaders, promise: nil).assertNothing())
        self.buffer.flushReceived()

        // So far we've written only a data frame.
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 15)])

        // Open the window enough to let another data frame through.
        self.buffer.updateWindowOfStream(streamOne, newSize: 34)
        self.receivedFrames().assertFramesMatch([frame.sliceDataFrame(length: 34)])

        // Now open it again. This pushes the data frame through, AND the trailers follow.
        self.buffer.updateWindowOfStream(streamOne, newSize: 1)
        self.receivedFrames().assertFramesMatch([frame, endHeaders])
    }

    func testBufferedDataAndHeadersAreCancelledOnStreamClosure() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        // Send a DATA frame that's too big, and a HEADERS frame. We will expect
        // these to both fail.
        let dataPromise = self.loop.makePromise(of: Void.self)
        let headersPromise = self.loop.makePromise(of: Void.self)

        var dataFrame = self.createDataFrame(streamOne, byteBufferSize: 50)
        let headersFrame = HTTP2Frame(streamID: streamOne, payload: .headers(.init(headers: HPACKHeaders([("key", "value")]))))
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: dataPromise).assertNothing())
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(headersFrame, promise: headersPromise).assertNothing())
        self.buffer.flushReceived()

        self.receivedFrames().assertFramesMatch([dataFrame.sliceDataFrame(length: 15)])

        // Ok, drop the stream.
        guard let droppedFrames = self.buffer.streamClosed(streamOne) else {
            XCTFail("Did not drop any frames")
            return
        }
        for (_, promise) in droppedFrames {
            promise?.fail(NIOHTTP2Errors.streamClosed(streamID: streamOne, errorCode: .protocolError))
        }

        XCTAssertThrowsError(try dataPromise.futureResult.wait()) {
            guard let err = $0 as? NIOHTTP2Errors.StreamClosed else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
            XCTAssertEqual(err.errorCode, .protocolError)
        }
        XCTAssertThrowsError(try headersPromise.futureResult.wait()) {
            guard let err = $0 as? NIOHTTP2Errors.StreamClosed else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
            XCTAssertEqual(err.errorCode, .protocolError)
        }
    }

    func testWritesForUnknownStreamsFail() {
        let streamOne = HTTP2StreamID(1)

        let frame = self.createDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertThrowsError(try self.buffer.processOutboundFrame(frame, promise: nil)) {
            guard let err = $0 as? NIOHTTP2Errors.NoSuchStream else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
        }
    }

    func testOverlargeFramesAreSplitOnMaxFrameSizeByteBuffer() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 1<<16)
        self.buffer.connectionWindowSize = 1<<24

        var dataFrame = self.createDataFrame(streamOne, byteBufferSize: (1 << 16) + 1)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        XCTAssertEqual(0, self.receivedFrames().count)

        self.buffer.maxFrameSize = 1<<15
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([dataFrame.sliceDataFrame(length: 1<<15), dataFrame.sliceDataFrame(length: 1<<15)])

        // Update the window.
        self.buffer.updateWindowOfStream(streamOne, newSize: 20)
        self.receivedFrames().assertFramesMatch([dataFrame])
    }

    func testOverlargeFramesAreSplitOnMaxFrameSizeFileRegion() {
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 1<<16)
        self.buffer.connectionWindowSize = 1<<24

        var dataFrame = self.createDataFrame(streamOne, fileRegionSize: (1 << 16) + 1)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        XCTAssertEqual(0, self.receivedFrames().count)

        self.buffer.maxFrameSize = 1<<15
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([dataFrame.sliceDataFrame(length: 1<<15), dataFrame.sliceDataFrame(length: 1<<15)], dataFileRegionToByteBuffer: false)

        // Update the window.
        self.buffer.updateWindowOfStream(streamOne, newSize: 20)
        self.receivedFrames().assertFramesMatch([dataFrame], dataFileRegionToByteBuffer: false)
    }

    func testChangingStreamWindowSizeToZeroAndBack() {
        // This test checks that updating the window size to zero on a flushable stream makes it no longer flushable.
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 0)

        let dataFrame = self.createDataFrame(streamOne, byteBufferSize: 15)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        XCTAssertEqual(0, self.receivedFrames().count)

        // The stream has data to write but the window size is zero, so it won't write.
        self.buffer.flushReceived()

        self.buffer.updateWindowOfStream(streamOne, newSize: 15)
        self.buffer.updateWindowOfStream(streamOne, newSize: 0)

        // Check the stream has been marked unflushable.
        self.buffer.flushReceived()
        XCTAssertEqual(0, self.receivedFrames().count)

        self.buffer.updateWindowOfStream(streamOne, newSize: 15)
        self.buffer.flushReceived()

        self.receivedFrames().assertFramesMatch([dataFrame], dataFileRegionToByteBuffer: false)
    }

    func testStreamWindowChanges() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)
        self.buffer.streamCreated(streamThree, initialWindowSize: 15)

        var oneFrame = self.createDataFrame(streamOne, byteBufferSize: 30)
        let threeFrame = self.createDataFrame(streamThree, byteBufferSize: 15)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(oneFrame, promise: nil).assertNothing())
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(threeFrame, promise: nil).assertNothing())
        XCTAssertNil(self.buffer.nextFlushedWritableFrame())

        // Let the window be consumed.
        self.buffer.flushReceived()
        self.receivedFrames().sorted(by: { $0.streamID < $1.streamID }).assertFramesMatch([oneFrame.sliceDataFrame(length: 15), threeFrame])

        // Ok, now we can increase the window size for all streams. This makes more data available.
        self.buffer.initialWindowSizeChanged(10)
        self.receivedFrames().assertFramesMatch([oneFrame.sliceDataFrame(length: 10)])

        let secondThreeFrame = self.createDataFrame(streamThree, byteBufferSize: 5)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(secondThreeFrame, promise: nil).assertNothing())
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([secondThreeFrame])

        // Now we shrink the window.
        self.buffer.initialWindowSizeChanged(-10)

        // And attempt to send another frame on stream three. This should be buffered.
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(secondThreeFrame, promise: nil).assertNothing())
        self.buffer.flushReceived()
        XCTAssertNil(self.buffer.nextFlushedWritableFrame())
    }

    func testRejectsPrioritySelfDependency() {
        XCTAssertThrowsError(try self.buffer.priorityUpdate(streamID: 1, priorityData: .init(exclusive: false, dependency: 1, weight: 36))) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.priorityCycle(streamID: 1))
        }
        XCTAssertThrowsError(try self.buffer.priorityUpdate(streamID: 1, priorityData: .init(exclusive: true, dependency: 1, weight: 36))) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.PriorityCycle, NIOHTTP2Errors.priorityCycle(streamID: 1))
        }
    }

    func testFlushableStreamStopsBeingFlushableIfTheWindowGoesAway() throws {
        // This test checks that updating the window size to zero on a flushable stream makes it no longer flushable.
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        let dataFrame = self.createDataFrame(streamOne, byteBufferSize: 15)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        XCTAssertEqual(0, self.receivedFrames().count)

        // Flush the stream. Note that we have not yet asked for frames, so nothing has been written.
        self.buffer.flushReceived()

        // Now drop the window.
        self.buffer.updateWindowOfStream(streamOne, newSize: 0)

        // Check the stream has been marked unflushable.
        self.buffer.flushReceived()
        XCTAssertEqual(0, self.receivedFrames().count)

        self.buffer.updateWindowOfStream(streamOne, newSize: 15)
        self.buffer.flushReceived()

        self.receivedFrames().assertFramesMatch([dataFrame], dataFileRegionToByteBuffer: false)
    }

    func testFlushableStreamStopsBeingFlushableIfTheWindowIsShrunkByTheRemotePeer() throws {
        // This test checks that updating the window size to zero on a flushable stream makes it no longer flushable.
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        let dataFrame = self.createDataFrame(streamOne, byteBufferSize: 15)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        XCTAssertEqual(0, self.receivedFrames().count)

        // Flush the stream. Note that we have not yet asked for frames, so nothing has been written.
        self.buffer.flushReceived()

        // Now drop the window by way of initial stream.
        self.buffer.initialWindowSizeChanged(-15)

        // Check the stream has been marked unflushable.
        self.buffer.flushReceived()
        XCTAssertEqual(0, self.receivedFrames().count)

        self.buffer.updateWindowOfStream(streamOne, newSize: 15)
        self.buffer.flushReceived()

        self.receivedFrames().assertFramesMatch([dataFrame], dataFileRegionToByteBuffer: false)
    }

    func testZeroSizedWritesAreStillAllowedWhenTheWindowIsZero() throws {
        // This test checks that zero sized writes can still get through when the window is zero.
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 0)

        let dataFrame = self.createDataFrame(streamOne, byteBufferSize: 0)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        XCTAssertEqual(0, self.receivedFrames().count)

        // Flush the stream. Note that we have not yet asked for frames, so nothing has been written.
        self.buffer.flushReceived()

        // Check the write can still go ahead.
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([dataFrame], dataFileRegionToByteBuffer: false)
    }

    func testZeroSizedWritesAreStillAllowedIfTheWindowChangesSize() throws {
        // This test checks that zero sized writes can still get through when the window is changed to zero after flush.
        let streamOne = HTTP2StreamID(1)
        self.buffer.streamCreated(streamOne, initialWindowSize: 15)

        let dataFrame = self.createDataFrame(streamOne, byteBufferSize: 0)
        XCTAssertNoThrow(try self.buffer.processOutboundFrame(dataFrame, promise: nil).assertNothing())
        XCTAssertEqual(0, self.receivedFrames().count)

        // Flush the stream. Note that we have not yet asked for frames, so nothing has been written.
        self.buffer.flushReceived()

        // Now drop the window.
        self.buffer.updateWindowOfStream(streamOne, newSize: 0)

        // Check the write can still go ahead.
        self.buffer.flushReceived()
        self.receivedFrames().assertFramesMatch([dataFrame], dataFileRegionToByteBuffer: false)
    }
}


/// Various helpers that make tests easier to understand.
extension OutboundFlowControlBufferTests {
    func createDataFrame(_ streamID: HTTP2StreamID, byteBufferSize: Int, endStream: Bool = false) -> HTTP2Frame {
        var buffer = ByteBufferAllocator().buffer(capacity: byteBufferSize)
        buffer.writeBytes(repeatElement(UInt8(0xff), count: byteBufferSize))
        return HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(buffer), endStream: endStream)))
    }

    func createDataFrame(_ streamID: HTTP2StreamID, fileRegionSize: Int, endStream: Bool = false) -> HTTP2Frame {
        // We create a deliberately-invalid closed file handle, as we'll never actually use it.
        let handle = NIOFileHandle(descriptor: -1)
        XCTAssertNoThrow(try handle.takeDescriptorOwnership())
        let region = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: fileRegionSize)
        return HTTP2Frame(streamID: streamID, payload: .data(.init(data: .fileRegion(region), endStream: endStream)))
    }
}


extension IOData {
    mutating func readSlice(length: Int) -> IOData {
        switch self {
        case .byteBuffer(var buf):
            let slice = buf.readSlice(length: length)!
            self = .byteBuffer(buf)
            return .byteBuffer(slice)
        case .fileRegion(var region):
            let slice = FileRegion(fileHandle: region.fileHandle, readerIndex: region.readerIndex, endIndex: region.readerIndex + length)
            region.moveReaderIndex(forwardBy: length)
            self = .fileRegion(region)
            return .fileRegion(slice)
        }
    }
}


extension HTTP2Frame {
    mutating func sliceDataFrame(length: Int) -> HTTP2Frame {
        guard case .data(var dataPayload) = self.payload else {
            preconditionFailure("Attempted to slice non-data frame")
        }

        // Synthesise a new frame by slicing the body.
        let newFrameData = dataPayload.data.readSlice(length: length)
        self.payload = .data(dataPayload)
        return HTTP2Frame(streamID: self.streamID, payload: .data(.init(data: newFrameData)))
    }
}
