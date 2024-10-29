//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
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

class InboundWindowManagerTests: XCTestCase {

    func testNewWindowSizeWhenNewSizeIsAtOrAboveTarget() {
        var windowManager = InboundWindowManager(targetSize: 10)
        XCTAssertNil(windowManager.newWindowSize(10))
        XCTAssertNil(windowManager.newWindowSize(11))
    }

    func testNewWindowSizeWhenNewSizeIsAtLeastHalfTarget() {
        var windowManager = InboundWindowManager(targetSize: 10)
        XCTAssertNil(windowManager.newWindowSize(6))
        XCTAssertNil(windowManager.newWindowSize(9))
    }

    func testNewWindowSizeWhenNewSizeIsLessThanOrEqualHalfTarget() {
        var windowManager = InboundWindowManager(targetSize: 10)
        XCTAssertEqual(windowManager.newWindowSize(0), 10)
        XCTAssertEqual(windowManager.newWindowSize(5), 5)
    }

    func testNewWindowSizeWithBufferedBytes() {
        var windowManager = InboundWindowManager(targetSize: 10)

        // The adjusted newSize is 3 (new size 2, buffered 1) which is less than half the target so
        // we need to increment.
        windowManager.bufferedFrameReceived(size: 1)
        XCTAssertEqual(windowManager.newWindowSize(2), 7)

        // The adjusted newSize is 6 (new size 2, buffered 1+3=4) which is more than half the target
        // so no need to increment.
        windowManager.bufferedFrameReceived(size: 3)
        XCTAssertNil(windowManager.newWindowSize(2))

        // The adjusted newSize is 10 (new size 2, buffered 4+4=8) which is equal to the target so
        // no need to increment.
        windowManager.bufferedFrameReceived(size: 4)
        XCTAssertNil(windowManager.newWindowSize(2))

        // The last window size was 2; we're emitting 2 of our 8 buffered bytes so now the adjusted
        // size is 8 (last size 2, buffered 6); no need to increment.
        XCTAssertNil(windowManager.bufferedFrameEmitted(size: 2))

        // Emit another 5 bytes: we're down to 3 (last size 2, buffered 1); we need to increment.
        XCTAssertEqual(windowManager.bufferedFrameEmitted(size: 5), 7)
    }

    func testInitialWindowSizeChanged() {
        var windowManager = InboundWindowManager(targetSize: 10)

        // There's no lastWindow size, so no increment.
        XCTAssertNil(windowManager.initialWindowSizeChanged(delta: 10))

        windowManager.bufferedFrameReceived(size: 3)
        // adjusted size is 8 (new size 5, buffered 3) which is less than half the target (now 20).
        XCTAssertEqual(windowManager.newWindowSize(5), 12)
    }

    func testWindowSizeWhenClosed() {
        var windowManager = InboundWindowManager(targetSize: 10)
        XCTAssertEqual(windowManager.newWindowSize(5), 5)

        windowManager.closed = true
        XCTAssertNil(windowManager.newWindowSize(5))

        windowManager.bufferedFrameReceived(size: 5)
        XCTAssertNil(windowManager.bufferedFrameEmitted(size: 5))
    }
}
