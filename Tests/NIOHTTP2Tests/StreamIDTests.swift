//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOHTTP2
import XCTest

final class StreamIDTests: XCTestCase {
    func testStreamIDsAreStrideable() {
        XCTAssertEqual(
            Array(HTTP2StreamID(1)..<HTTP2StreamID(30)),
            Array(stride(from: HTTP2StreamID(1), to: HTTP2StreamID(30), by: 1))
        )
        XCTAssertEqual(
            [10, 9, 8, 7, 6, 5, 4, 3, 2, 1],
            Array(stride(from: HTTP2StreamID(10), through: HTTP2StreamID(1), by: -1))
        )
        XCTAssertEqual([1, 3, 5, 7, 9], Array(stride(from: HTTP2StreamID(1), to: HTTP2StreamID(10), by: 2)))
    }

    func testIsClientInitiated() {
        XCTAssertFalse(HTTP2StreamID(0).isClientInitiated)
        XCTAssertTrue(HTTP2StreamID(1).isClientInitiated)
        XCTAssertFalse(HTTP2StreamID(2).isClientInitiated)
        XCTAssertTrue(HTTP2StreamID(3).isClientInitiated)
        XCTAssertFalse(HTTP2StreamID(4).isClientInitiated)
    }

    func testIsServerInitiated() {
        XCTAssertFalse(HTTP2StreamID(0).isServerInitiated)
        XCTAssertFalse(HTTP2StreamID(1).isServerInitiated)
        XCTAssertTrue(HTTP2StreamID(2).isServerInitiated)
        XCTAssertFalse(HTTP2StreamID(3).isServerInitiated)
        XCTAssertTrue(HTTP2StreamID(4).isServerInitiated)
    }
}
