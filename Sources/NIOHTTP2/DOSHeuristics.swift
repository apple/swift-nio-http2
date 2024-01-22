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

    private var resetFrameRateControlStateMachine: HTTP2ResetFrameRateControlStateMachine

    internal init(maximumSequentialEmptyDataFrames: Int, maximumResetFrameCount: Int, resetFrameCounterWindow: TimeAmount, clock: DeadlineClock = RealNIODeadlineClock()) {
        precondition(maximumSequentialEmptyDataFrames >= 0,
                     "maximum sequential empty data frames must be positive, got \(maximumSequentialEmptyDataFrames)")
        self.maximumSequentialEmptyDataFrames = maximumSequentialEmptyDataFrames
        self.receivedEmptyDataFrames = 0
        self.resetFrameRateControlStateMachine = .init(countThreshold: maximumResetFrameCount, timeWindow: resetFrameCounterWindow, clock: clock)
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
            switch self.resetFrameRateControlStateMachine.resetReceived() {
            case .rateTooHigh:
                throw NIOHTTP2Errors.excessiveRSTFrames()
            case .noneReceived, .ratePermitted:
                // no risk
                ()
            }
        case .alternativeService, .goAway, .origin, .ping, .priority, .pushPromise, .settings, .windowUpdate:
            // Currently we don't assess these for DoS risk.
            ()
        }

        if self.receivedEmptyDataFrames > self.maximumSequentialEmptyDataFrames {
            throw NIOHTTP2Errors.excessiveEmptyDataFrames()
        }
    }
}

extension DOSHeuristics {
    // protect against excessive numbers of stream RST frames being issued
    struct HTTP2ResetFrameRateControlStateMachine {

        enum ResetFrameRateControlState: Hashable {
            case noneReceived
            case ratePermitted
            case rateTooHigh
        }

        private let countThreshold: Int
        private let timeWindow: TimeAmount
        private let clock: DeadlineClock

        private var resetTimestamps: Deque<NIODeadline>
        private var _state: ResetFrameRateControlState = .noneReceived

        init(countThreshold: Int, timeWindow: TimeAmount, clock: DeadlineClock = RealNIODeadlineClock()) {
            self.countThreshold = countThreshold
            self.timeWindow = timeWindow
            self.clock = clock

            self.resetTimestamps = .init(minimumCapacity: self.countThreshold)
        }

        mutating func resetReceived() -> ResetFrameRateControlState {
            self.garbageCollect()
            self.resetTimestamps.append(self.clock.now())
            self.evaluateState()
            return self._state
        }

        private mutating func garbageCollect() {
            let now = self.clock.now()
            while let first = self.resetTimestamps.first, now - first > self.timeWindow {
                _ = self.resetTimestamps.popFirst()
            }
        }

        private mutating func evaluateState() {
            switch self._state {
            case .noneReceived:
                self._state = .ratePermitted
            case .ratePermitted:
                if self.resetTimestamps.count > self.countThreshold {
                    self._state = .rateTooHigh
                }
            case .rateTooHigh:
                break // no-op, there is no way to de-escalate from an excessive rate
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
