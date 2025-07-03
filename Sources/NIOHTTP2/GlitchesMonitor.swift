//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

package struct GlitchesMonitor {
    package static var defaultMaxGlitches: Int { 200 }
    private var stateMachine: GlitchesMonitorStateMachine

    package init(maxGlitches: Int = GlitchesMonitor.defaultMaxGlitches) {
        self.stateMachine = GlitchesMonitorStateMachine(maxGlitches: maxGlitches)
    }

    package mutating func processStreamError() throws {
        switch self.stateMachine.recordEvent() {
        case .belowLimit:
            ()

        case .exceededLimit:
            throw NIOHTTP2Errors.excessiveNumberOfGlitches()
        }
    }
}

extension GlitchesMonitor {
    private struct GlitchesMonitorStateMachine {
        enum State {
            case monitoring(numberOfGlitches: Int)
            case glitchesExceeded
        }

        private var state: State
        private let maxGlitches: Int

        init(maxGlitches: Int) {
            precondition(maxGlitches >= 0)
            self.state = .monitoring(numberOfGlitches: 0)
            self.maxGlitches = maxGlitches
        }

        enum RecordEventAction {
            case belowLimit
            case exceededLimit
        }

        mutating func recordEvent() -> RecordEventAction {
            switch self.state {
            case .monitoring(let numberOfGlitches):
                if numberOfGlitches < self.maxGlitches {
                    self.state = .monitoring(numberOfGlitches: numberOfGlitches &+ 1)
                    return .belowLimit
                } else {
                    self.state = .glitchesExceeded
                    return .exceededLimit
                }

            case .glitchesExceeded:
                return .exceededLimit
            }
        }
    }
}
