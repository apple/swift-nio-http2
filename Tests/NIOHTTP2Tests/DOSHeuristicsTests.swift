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
import Testing

@testable import NIOHTTP2

struct DOSHeuristicsTests {
    private func makeDOSHeuristics(
        maximumSequentialEmptyDataFrames: Int = 100,
        resetFrameRateLimit: RateLimitConfiguration = .init(maximumCount: 200, counterWindow: .seconds(30)),
        streamErrorRateLimit: RateLimitConfiguration = .init(maximumCount: 200, counterWindow: .seconds(30)),
        controlFrameRateLimit: RateLimitConfiguration = .init(maximumCount: 200, counterWindow: .seconds(30)),
    ) -> (DOSHeuristics<TestClock>, TestClock) {
        let testClock = TestClock()
        let dosHeuristics = DOSHeuristics(
            maximumSequentialEmptyDataFrames: maximumSequentialEmptyDataFrames,
            resetFrameRateLimit: resetFrameRateLimit,
            streamErrorRateLimit: streamErrorRateLimit,
            controlFrameRateLimit: controlFrameRateLimit,
            clock: testClock
        )
        return (dosHeuristics, testClock)
    }

    private let controlFrames: [HTTP2Frame] = [
        HTTP2Frame(streamID: 0, payload: .alternativeService(origin: nil, field: nil)),
        HTTP2Frame(streamID: 0, payload: .origin([])),
        HTTP2Frame(streamID: 0, payload: .settings(.settings([]))),
        HTTP2Frame(streamID: 0, payload: .ping(.init(), ack: false)),
        HTTP2Frame(streamID: 1, payload: .priority(.init(exclusive: true, dependency: 500, weight: 0))),
    ]

    @Test
    func testRSTFramePermittedRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            resetFrameRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30))
        )

        // more resets than allowed, but slow enough to be okay
        for i in 0..<300 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .seconds(1))
        }
    }

    @Test
    func testRSTFrameExcessiveRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            resetFrameRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30))
        )

        // up to the limit
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        #expect(throws: NIOHTTP2Errors.ExcessiveRSTFrames.self) {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(201), payload: .rstStream(.cancel)))
        }
    }

    @Test
    func testRateLimitGarbageCollects() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            resetFrameRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30)),
            streamErrorRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30)),
            controlFrameRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30))
        )

        let resetStreamFrame = HTTP2Frame.FramePayload.rstStream(.cancel)
        let controlFrame = HTTP2Frame.FramePayload.settings(.settings([]))

        // up to the limit
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: resetStreamFrame))
            try dosHeuristics.processStreamError()
            try dosHeuristics.process(.init(streamID: 0, payload: controlFrame))

            testClock.advance(by: .milliseconds(1))
        }

        // clear out counter
        testClock.advance(by: .seconds(30))

        // up to the limit
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: resetStreamFrame))
            try dosHeuristics.processStreamError()
            try dosHeuristics.process(.init(streamID: 0, payload: controlFrame))

            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        #expect(throws: NIOHTTP2Errors.ExcessiveRSTFrames.self) {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(401), payload: resetStreamFrame))
        }
        #expect(throws: NIOHTTP2Errors.ExcessiveStreamErrors.self) {
            try dosHeuristics.processStreamError()
        }
        #expect(throws: NIOHTTP2Errors.ExcessiveControlFrames.self) {
            try dosHeuristics.process(.init(streamID: 0, payload: controlFrame))
        }
    }

    @Test
    func testRSTFrameExcessiveRateConfigurableCount() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            resetFrameRateLimit: .init(maximumCount: 400, counterWindow: .seconds(30))
        )

        // up to the limit
        for i in 0..<400 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .milliseconds(1))
        }

        // over the limit
        #expect(throws: NIOHTTP2Errors.ExcessiveRSTFrames.self) {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(401), payload: .rstStream(.cancel)))
        }
    }

    @Test
    func testRSTFrameExcessiveRateConfigurableWindow() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            resetFrameRateLimit: .init(maximumCount: 200, counterWindow: .seconds(3600))
        )

        // up to the limit, previously slow enough to be okay but not with this window
        for i in 0..<200 {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(i), payload: .rstStream(.cancel)))
            testClock.advance(by: .seconds(1))
        }

        // over the limit
        #expect(throws: NIOHTTP2Errors.ExcessiveRSTFrames.self) {
            try dosHeuristics.process(.init(streamID: HTTP2StreamID(201), payload: .rstStream(.cancel)))
        }
    }

    @Test
    func testStreamErrorPermittedRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            streamErrorRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30))
        )

        // More stream errors than allowed, but slow enough to be okay
        for _ in 0..<300 {
            try dosHeuristics.processStreamError()
            testClock.advance(by: .seconds(1))
        }
    }

    @Test
    func testStreamErrorExcessiveRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            streamErrorRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30))
        )

        // Up to the limit
        for _ in 0..<200 {
            try dosHeuristics.processStreamError()
            testClock.advance(by: .milliseconds(1))
        }

        // Over the limit
        #expect(throws: NIOHTTP2Errors.ExcessiveStreamErrors.self) {
            try dosHeuristics.processStreamError()
        }
    }

    @Test
    func testControlFramePermittedRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            controlFrameRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30))
        )

        // More control frames than allowed, but slow enough to be okay
        for _ in 0..<60 {
            for controlFrame in self.controlFrames {
                try dosHeuristics.process(controlFrame)
            }
            testClock.advance(by: .seconds(1))
        }
    }

    @Test
    func testControlFrameExcessiveRate() throws {
        var (dosHeuristics, testClock) = self.makeDOSHeuristics(
            controlFrameRateLimit: .init(maximumCount: 200, counterWindow: .seconds(30))
        )

        // Up to the limit
        for _ in 0..<40 {
            for controlFrame in self.controlFrames {
                try dosHeuristics.process(controlFrame)
            }
            testClock.advance(by: .milliseconds(1))
        }

        // Over the limit
        #expect(throws: NIOHTTP2Errors.ExcessiveControlFrames.self) {
            try dosHeuristics.process(self.controlFrames[0])
        }
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
