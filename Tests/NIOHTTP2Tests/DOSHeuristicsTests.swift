//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOCore
@testable import NIOHTTP2

final class DOSHeuristicsTests: XCTestCase {
    func testRSTFramePermittedRate() throws {
        let testClock = TestClock()
        var dosHeuristics = DOSHeuristics(maximumSequentialEmptyDataFrames: 100, maximumResetFrameCount: 200, resetFrameCounterWindow: .seconds(30), clock: testClock)

        // more resets than allowed, but slow enough to be okay
        for i in 0..<300 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .seconds(1))
        }
    }

    func testRSTFrameExcessiveRate() throws {
        let testClock = TestClock()
        var dosHeuristics = DOSHeuristics(maximumSequentialEmptyDataFrames: 100, maximumResetFrameCount: 200, resetFrameCounterWindow: .seconds(30), clock: testClock)

        // up to the limit
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        XCTAssertThrowsError(try dosHeuristics.process(.init(streamID: HTTP2StreamID(201), payload: .rstStream(.cancel))))
    }

    func testRSTFrameGarbageCollects() throws {
        let testClock = TestClock()
        var dosHeuristics = DOSHeuristics(maximumSequentialEmptyDataFrames: 100, maximumResetFrameCount: 200, resetFrameCounterWindow: .seconds(30), clock: testClock)

        // up to the limit
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // clear out counter
        testClock.advance(by: .seconds(30))

        // up to the limit
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        XCTAssertThrowsError(try dosHeuristics.process(.init(streamID: HTTP2StreamID(401), payload: .rstStream(.cancel))))
    }

    func testRSTFrameExcessiveRateConfigurableCount() throws {
        let testClock = TestClock()
        var dosHeuristics = DOSHeuristics(maximumSequentialEmptyDataFrames: 100, maximumResetFrameCount: 400, resetFrameCounterWindow: .seconds(30), clock: testClock)

        // up to the limit
        for i in 0..<400 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        XCTAssertThrowsError(try dosHeuristics.process(.init(streamID: HTTP2StreamID(401), payload: .rstStream(.cancel))))
    }

    func testRSTFrameExcessiveRateConfigurableWindow() throws {
        let testClock = TestClock()
        var dosHeuristics = DOSHeuristics(maximumSequentialEmptyDataFrames: 100, maximumResetFrameCount: 200, resetFrameCounterWindow: .seconds(3600), clock: testClock)

        // up to the limit, previously slow enough to be okay but not with this window
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .seconds(1))
        }

        // over the limit
        XCTAssertThrowsError(try dosHeuristics.process(.init(streamID: HTTP2StreamID(201), payload: .rstStream(.cancel))))
    }
}

class TestClock: NIODeadlineClock {
    private var time: NIODeadline

    func now() -> NIODeadline {
        return self.time
    }

    func advance(by delta: TimeAmount) {
        self.time = self.time + delta
    }

    init() {
        self.time = NIODeadline.now()
    }
}
