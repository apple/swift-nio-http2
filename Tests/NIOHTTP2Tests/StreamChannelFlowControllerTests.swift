//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
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

final class StreamChannelFlowControllerTests: XCTestCase {
    func testChannelWritabilityChangesFromFlowControl() {
        var controller = StreamChannelFlowController(highWatermark: 10, lowWatermark: 5, parentIsWritable: true)
        XCTAssertTrue(controller.isWritable)

        XCTAssertEqual(controller.bufferedBytes(10), .noChange)
        XCTAssertTrue(controller.isWritable)

        XCTAssertEqual(controller.bufferedBytes(1), .changed(newValue: false))
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.bufferedBytes(10), .noChange)
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.wroteBytes(16), .noChange)
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.wroteBytes(1), .changed(newValue: true))
        XCTAssertTrue(controller.isWritable)

        XCTAssertEqual(controller.wroteBytes(4), .noChange)
        XCTAssertTrue(controller.isWritable)
    }

    func testChannelWritabilityChangesFromParent() {
        var controller = StreamChannelFlowController(highWatermark: 10, lowWatermark: 5, parentIsWritable: true)
        XCTAssertTrue(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(true), .noChange)
        XCTAssertTrue(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(false), .changed(newValue: false))
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(false), .noChange)
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(true), .changed(newValue: true))
        XCTAssertTrue(controller.isWritable)
    }

    func testChannelWritabilityConsidersBothFlowControlAndParent() {
        var controller = StreamChannelFlowController(highWatermark: 10, lowWatermark: 5, parentIsWritable: true)
        XCTAssertTrue(controller.isWritable)

        XCTAssertEqual(controller.bufferedBytes(15), .changed(newValue: false))
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(false), .noChange)
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.wroteBytes(15), .noChange)
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(true), .changed(newValue: true))
        XCTAssertTrue(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(false), .changed(newValue: false))
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.bufferedBytes(15), .noChange)
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.parentWritabilityChanged(true), .noChange)
        XCTAssertFalse(controller.isWritable)

        XCTAssertEqual(controller.wroteBytes(15), .changed(newValue: true))
        XCTAssertTrue(controller.isWritable)
    }
}
