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

import NIOCore
import XCTest

@testable import NIOHTTP2

final class DOSHeuristicsTests: XCTestCase {
    private func makeDOSHeuristics(
        maximumSequentialEmptyDataFrames: Int = 100,
        maximumResetFrameCount: Int = 200,
        resetFrameCounterWindow: TimeAmount = .seconds(30),
        maximumStreamErrorCount: Int = 200,
        streamErrorCounterWindow: TimeAmount = .seconds(30)
    ) -> (DOSHeuristics<TestClock>, TestClock) {
        let testClock = TestClock()
        let dosHeuristics = DOSHeuristics(
            maximumSequentialEmptyDataFrames: maximumSequentialEmptyDataFrames,
            maximumResetFrameCount: maximumResetFrameCount,
            resetFrameCounterWindow: resetFrameCounterWindow,
            maximumStreamErrorCount: maximumStreamErrorCount,
            streamErrorCounterWindow: streamErrorCounterWindow,
            clock: testClock
        )
        return (dosHeuristics, testClock)
    }

    func testRSTFramePermittedRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumResetFrameCount: 200,
            resetFrameCounterWindow: .seconds(30)
        )

        // more resets than allowed, but slow enough to be okay
        for i in 0..<300 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .seconds(1))
        }
    }

    func testRSTFrameExcessiveRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumResetFrameCount: 200,
            resetFrameCounterWindow: .seconds(30)
        )

        // up to the limit
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        XCTAssertThrowsError(
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(201), payload: .rstStream(.cancel)))
        )
    }

    func testRSTFrameGarbageCollects() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumResetFrameCount: 200,
            resetFrameCounterWindow: .seconds(30)
        )

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
        XCTAssertThrowsError(
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(401), payload: .rstStream(.cancel)))
        )
    }

    func testRSTFrameExcessiveRateConfigurableCount() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumResetFrameCount: 400,
            resetFrameCounterWindow: .seconds(30)
        )

        // up to the limit
        for i in 0..<400 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        XCTAssertThrowsError(
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(401), payload: .rstStream(.cancel)))
        )
    }

    func testRSTFrameExcessiveRateConfigurableWindow() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumResetFrameCount: 200,
            resetFrameCounterWindow: .seconds(3600)
        )

        // up to the limit, previously slow enough to be okay but not with this window
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .seconds(1))
        }

        // over the limit
        XCTAssertThrowsError(
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(201), payload: .rstStream(.cancel)))
        )
    }

    func testStreamErrorPermittedRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumStreamErrorCount: 200,
            streamErrorCounterWindow: .seconds(30)
        )

        // More stream errors than allowed, but slow enough to be okay
        for _ in 0..<300 {
            try dosHeuristics.processStreamError()
            testClock.advance(by: .seconds(1))
        }
    }

    func testStreamErrorExcessiveRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumStreamErrorCount: 200,
            streamErrorCounterWindow: .seconds(30)
        )

        // Up to the limit
        for _ in 0..<200 {
            try dosHeuristics.processStreamError()
            testClock.advance(by: .milliseconds(1))
        }

        // Over the limit
        XCTAssertThrowsError(
            try dosHeuristics.processStreamError()
        )
    }

    func testStreamErrorGarbageCollects() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            maximumStreamErrorCount: 200,
            streamErrorCounterWindow: .seconds(30)
        )

        // Up to the limit
        for _ in 0..<200 {
            try dosHeuristics.processStreamError()
            testClock.advance(by: .milliseconds(1))
        }

        // Clear out counter
        testClock.advance(by: .seconds(30))

        // Up to the limit
        for _ in 0..<200 {
            try dosHeuristics.processStreamError()
            testClock.advance(by: .milliseconds(1))
        }

        // Over the limit
        XCTAssertThrowsError(try dosHeuristics.processStreamError())
    }
}

class TestClock: NIODeadlineClock {
    private var time: NIODeadline

    func now() -> NIODeadline {
        self.time
    }

    func advance(by delta: TimeAmount) {
        self.time = self.time + delta
    }

    init() {
        self.time = NIODeadline.now()
    }
}
