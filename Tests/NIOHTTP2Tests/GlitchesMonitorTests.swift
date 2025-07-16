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

import XCTest

@testable import NIOHTTP2

class GlitchesMonitorTests: XCTestCase {
    func testProcessStreamError() throws {
        let maxGlitches: Int = 10
        var monitor = GlitchesMonitor(maximumGlitches: maxGlitches)

        // We accept up to `maxGlitches` glitches without erroring...
        for _ in 1...maxGlitches {
            XCTAssertNoThrow(try monitor.processStreamError())
        }

        // But any more glitches after that, we fail.
        for _ in 1...5 {
            XCTAssertThrowsError(try monitor.processStreamError()) { error in
                XCTAssertNotNil(error as? NIOHTTP2Errors.ExcessiveNumberOfGlitches)
            }
        }
    }
}
