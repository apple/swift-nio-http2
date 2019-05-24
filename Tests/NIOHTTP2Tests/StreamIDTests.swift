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

import XCTest
import NIOHTTP2


final class StreamIDTests: XCTestCase {
    func testStreamIDsAreStrideable() {
        XCTAssertEqual(Array(HTTP2StreamID(1)..<HTTP2StreamID(30)), Array(stride(from: HTTP2StreamID(1), to: HTTP2StreamID(30), by: 1)))
        XCTAssertEqual([10, 9, 8, 7, 6, 5, 4, 3, 2, 1], Array(stride(from: HTTP2StreamID(10), through: HTTP2StreamID(1), by: -1)))
        XCTAssertEqual([1, 3, 5, 7, 9], Array(stride(from: HTTP2StreamID(1), to: HTTP2StreamID(10), by: 2)))
    }
}
