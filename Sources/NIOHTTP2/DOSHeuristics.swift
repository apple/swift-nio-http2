//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DequeModule
import NIOCore

/// Implements some simple denial of service heuristics on inbound frames.
struct DOSHeuristics<DeadlineClock: NIODeadlineClock> {
    /// The number of "empty" (zero bytes of useful payload) DATA frames we've received since the
    /// last useful frame.
    ///
    /// We reset this count each time we see END_STREAM, or a HEADERS frame, both of which we count
    /// as doing useful work. We have a small budget for these because we want to tolerate buggy
    /// implementations that occasionally emit empty DATA frames, but don't want to drown in them.
    private var receivedEmptyDataFrames: Int

    /// The maximum number of "empty" data frames we're willing to tolerate.
    private let maximumSequentialEmptyDataFrames: Int

    /// The rate limiter for inbound RST_STREAM frames.
    private var resetFrameRateLimitStateMachine: RateLimitStateMachine

    /// The rate limiter for stream errors.
    private var streamErrorRateLimitStateMachine: RateLimitStateMachine

    /// The rate limiter for inbound PING, SETTINGS, PRIORITY, ALTSVC and ORIGIN frames.
    private var controlFrameRateLimitStateMachine: RateLimitStateMachine

    internal init(
        maximumSequentialEmptyDataFrames: Int,
        resetFrameRateLimit: RateLimitConfiguration,
        streamErrorRateLimit: RateLimitConfiguration,
        controlFrameRateLimit: RateLimitConfiguration,
        clock: DeadlineClock = RealNIODeadlineClock()
    ) {
        precondition(
            maximumSequentialEmptyDataFrames >= 0,
            "maximum sequential empty data frames must be positive, got \(maximumSequentialEmptyDataFrames)"
        )
        self.maximumSequentialEmptyDataFrames = maximumSequentialEmptyDataFrames
        self.receivedEmptyDataFrames = 0
        self.resetFrameRateLimitStateMachine = .init(configuration: resetFrameRateLimit, clock: clock)
        self.streamErrorRateLimitStateMachine = .init(configuration: streamErrorRateLimit, clock: clock)
        self.controlFrameRateLimitStateMachine = .init(configuration: controlFrameRateLimit, clock: clock)
    }
}

extension DOSHeuristics {
    mutating func process(_ frame: HTTP2Frame) throws {
        switch frame.payload {
        case .data(let payload):
            if payload.data.readableBytes == 0 {
                self.receivedEmptyDataFrames += 1
            }

            if payload.endStream {
                self.receivedEmptyDataFrames = 0
            }
        case .headers:
            self.receivedEmptyDataFrames = 0
        case .rstStream:
            switch self.resetFrameRateLimitStateMachine.recordEvent() {
            case .rateTooHigh:
                throw NIOHTTP2Errors.excessiveRSTFrames()
            case .noneReceived, .ratePermitted:
                // no risk
                ()
            }
        case .ping, .settings, .priority, .alternativeService, .origin:
            switch self.controlFrameRateLimitStateMachine.recordEvent() {
            case .rateTooHigh:
                throw NIOHTTP2Errors.excessiveControlFrames()
            case .noneReceived, .ratePermitted:
                // no risk
                ()
            }
        case .goAway, .pushPromise, .windowUpdate:
            // Currently we don't assess these for DoS risk.
            ()
        }

        if self.receivedEmptyDataFrames > self.maximumSequentialEmptyDataFrames {
            throw NIOHTTP2Errors.excessiveEmptyDataFrames()
        }
    }

    mutating func processStreamError() throws {
        switch self.streamErrorRateLimitStateMachine.recordEvent() {
        case .rateTooHigh:
            throw NIOHTTP2Errors.excessiveStreamErrors()
        case .noneReceived, .ratePermitted:
            ()
        }
    }
}

extension DOSHeuristics {
    /// Tracks whether events occur more often than a configured number of times within a time window.
    struct RateLimitStateMachine {
        enum RateState: Hashable {
            case noneReceived
            case ratePermitted
            case rateTooHigh
        }

        private let configuration: RateLimitConfiguration
        private let clock: DeadlineClock

        private var timestamps: Deque<NIODeadline>
        private var _state: RateState = .noneReceived

        init(configuration: RateLimitConfiguration, clock: DeadlineClock = RealNIODeadlineClock()) {
            self.configuration = configuration
            self.clock = clock

            self.timestamps = .init(minimumCapacity: self.configuration.maximumCount)
        }

        mutating func recordEvent() -> RateState {
            self.garbageCollect()
            self.timestamps.append(self.clock.now())
            self.evaluateState()
            return self._state
        }

        private mutating func garbageCollect() {
            let now = self.clock.now()
            while let first = self.timestamps.first, now - first > self.configuration.counterWindow {
                _ = self.timestamps.popFirst()
            }
        }

        private mutating func evaluateState() {
            switch self._state {
            case .noneReceived:
                self._state = .ratePermitted
            case .ratePermitted:
                if self.timestamps.count > self.configuration.maximumCount {
                    self._state = .rateTooHigh
                }
            case .rateTooHigh:
                break  // no-op, there is no way to de-escalate from an excessive rate
            }
        }
    }
}

// Simple mockable clock protocol
protocol NIODeadlineClock {
    func now() -> NIODeadline
}

struct RealNIODeadlineClock: NIODeadlineClock {
    func now() -> NIODeadline {
        NIODeadline.now()
    }
}

struct RateLimitConfiguration {
    /// The number of events permitted within ``counterWindow``.
    var maximumCount: Int

    /// The length of the sliding window over which events are recorded.
    var counterWindow: TimeAmount
}

extension RateLimitConfiguration {
    init(_ configuration: NIOHTTP2Handler.StreamResetFrameRateLimitConfiguration) {
        self.init(maximumCount: configuration.maximumCount, counterWindow: configuration.windowLength)
    }

    init(_ configuration: NIOHTTP2Handler.StreamErrorRateLimitConfiguration) {
        self.init(maximumCount: configuration.maximumCount, counterWindow: configuration.windowLength)
    }

    init(_ configuration: NIOHTTP2Handler.ControlFrameRateLimitConfiguration) {
        self.init(maximumCount: configuration.maximumCount, counterWindow: configuration.windowLength)
    }
}
