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

import NIOCore
import NIOHPACK
import XCTest

@testable import NIOHTTP2

final class ControlFrameBufferTests: XCTestCase {
    func testByDefaultAllFramesPassThroughWhenChannelIsWritable() throws {
        var buffer = ControlFrameBuffer(maximumBufferSize: 1024)

        XCTAssertNoThrow(try buffer.processOutboundFrame(.data, promise: nil, channelWritable: true).assertForward())
        XCTAssertNoThrow(try buffer.processOutboundFrame(.headers, promise: nil, channelWritable: true).assertForward())
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.priority, promise: nil, channelWritable: true).assertForward()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.rstStream, promise: nil, channelWritable: true).assertForward()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.settings, promise: nil, channelWritable: true).assertForward()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.pushPromise, promise: nil, channelWritable: true).assertForward()
        )
        XCTAssertNoThrow(try buffer.processOutboundFrame(.ping, promise: nil, channelWritable: true).assertForward())
        XCTAssertNoThrow(try buffer.processOutboundFrame(.goAway, promise: nil, channelWritable: true).assertForward())
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.windowUpdate, promise: nil, channelWritable: true).assertForward()
        )
        XCTAssertNoThrow(try buffer.processOutboundFrame(.altSvc, promise: nil, channelWritable: true).assertForward())
        XCTAssertNoThrow(try buffer.processOutboundFrame(.origin, promise: nil, channelWritable: true).assertForward())

        buffer.flushReceived()

        XCTAssertNil(buffer.nextFlushedWritableFrame())
    }

    func testByDefaultControlFramesAreBufferedWhenNotWritable() throws {
        // We won't pass a DATA frame here, as if such a frame reaches the control buffer while not writable
        // we'll trip an assert.
        var buffer = ControlFrameBuffer(maximumBufferSize: 1024)

        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.headers, promise: nil, channelWritable: false).assertNothing()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.priority, promise: nil, channelWritable: false).assertNothing()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.rstStream, promise: nil, channelWritable: false).assertNothing()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.settings, promise: nil, channelWritable: false).assertNothing()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.pushPromise, promise: nil, channelWritable: false).assertNothing()
        )
        XCTAssertNoThrow(try buffer.processOutboundFrame(.ping, promise: nil, channelWritable: false).assertNothing())
        XCTAssertNoThrow(try buffer.processOutboundFrame(.goAway, promise: nil, channelWritable: false).assertNothing())
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.windowUpdate, promise: nil, channelWritable: false).assertNothing()
        )
        XCTAssertNoThrow(try buffer.processOutboundFrame(.altSvc, promise: nil, channelWritable: false).assertNothing())
        XCTAssertNoThrow(try buffer.processOutboundFrame(.origin, promise: nil, channelWritable: false).assertNothing())

        // No flushed frames.
        XCTAssertNil(buffer.nextFlushedWritableFrame())

        buffer.flushReceived()

        // The frames come out in order.
        var flushedFrames: [HTTP2Frame] = []
        while let flushedFrame = buffer.nextFlushedWritableFrame() {
            flushedFrames.append(flushedFrame.frame)
        }
        flushedFrames.assertFramesMatch([
            .headers, .priority, .rstStream, .settings, .pushPromise, .ping, .goAway, .windowUpdate, .altSvc, .origin,
        ])
    }

    func testControlFramesWillQueueEvenIfWritable() throws {
        // We'll queue a HEADERS frame.
        var buffer = ControlFrameBuffer(maximumBufferSize: 1024)
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.headers, promise: nil, channelWritable: false).assertNothing()
        )

        // Now, further control frames will buffer, even if writable.
        XCTAssertNoThrow(try buffer.processOutboundFrame(.headers, promise: nil, channelWritable: true).assertNothing())
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.priority, promise: nil, channelWritable: true).assertNothing()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.rstStream, promise: nil, channelWritable: true).assertNothing()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.settings, promise: nil, channelWritable: true).assertNothing()
        )
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.pushPromise, promise: nil, channelWritable: true).assertNothing()
        )
        XCTAssertNoThrow(try buffer.processOutboundFrame(.ping, promise: nil, channelWritable: true).assertNothing())
        XCTAssertNoThrow(try buffer.processOutboundFrame(.goAway, promise: nil, channelWritable: true).assertNothing())
        XCTAssertNoThrow(
            try buffer.processOutboundFrame(.windowUpdate, promise: nil, channelWritable: true).assertNothing()
        )
        XCTAssertNoThrow(try buffer.processOutboundFrame(.altSvc, promise: nil, channelWritable: true).assertNothing())
        XCTAssertNoThrow(try buffer.processOutboundFrame(.origin, promise: nil, channelWritable: true).assertNothing())

        buffer.flushReceived()

        var flushedFrames: [HTTP2Frame] = []
        while let flushedFrame = buffer.nextFlushedWritableFrame() {
            flushedFrames.append(flushedFrame.frame)
        }
        flushedFrames.assertFramesMatch([
            .headers, .headers, .priority, .rstStream, .settings, .pushPromise, .ping, .goAway, .windowUpdate, .altSvc,
            .origin,
        ])
    }

    func testExcessiveBufferingLeadsToErrors() throws {
        var buffer = ControlFrameBuffer(maximumBufferSize: 1024)

        for _ in 0..<1024 {
            XCTAssertNoThrow(
                try buffer.processOutboundFrame(.headers, promise: nil, channelWritable: false).assertNothing()
            )
        }
        XCTAssertThrowsError(try buffer.processOutboundFrame(.headers, promise: nil, channelWritable: false)) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.ExcessiveOutboundFrameBuffering,
                NIOHTTP2Errors.excessiveOutboundFrameBuffering()
            )
        }
    }
}

extension HTTP2Frame {
    fileprivate static var data: HTTP2Frame {
        HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(.empty))))
    }

    fileprivate static var headers: HTTP2Frame {
        HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders())))
    }

    fileprivate static var priority: HTTP2Frame {
        HTTP2Frame(streamID: 1, payload: .priority(.init(exclusive: true, dependency: 0, weight: 32)))
    }

    fileprivate static var rstStream: HTTP2Frame {
        HTTP2Frame(streamID: 1, payload: .rstStream(.protocolError))
    }

    fileprivate static var settings: HTTP2Frame {
        HTTP2Frame(streamID: .rootStream, payload: .settings(.ack))
    }

    fileprivate static var pushPromise: HTTP2Frame {
        HTTP2Frame(streamID: 1, payload: .pushPromise(.init(pushedStreamID: 2, headers: HPACKHeaders())))
    }

    fileprivate static var ping: HTTP2Frame {
        HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(), ack: false))
    }

    fileprivate static var goAway: HTTP2Frame {
        HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: .maxID, errorCode: .protocolError, opaqueData: nil)
        )
    }

    fileprivate static var windowUpdate: HTTP2Frame {
        HTTP2Frame(streamID: 1, payload: .windowUpdate(windowSizeIncrement: 1))
    }

    fileprivate static var altSvc: HTTP2Frame {
        HTTP2Frame(streamID: .rootStream, payload: .alternativeService(origin: nil, field: nil))
    }

    fileprivate static var origin: HTTP2Frame {
        HTTP2Frame(streamID: .rootStream, payload: .origin([]))
    }
}

extension ByteBuffer {
    fileprivate static var empty: ByteBuffer {
        ByteBufferAllocator().buffer(capacity: 0)
    }
}
