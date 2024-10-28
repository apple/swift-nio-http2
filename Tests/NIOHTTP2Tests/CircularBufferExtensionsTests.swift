//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
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

final class CircularBufferExtensionsTests: XCTestCase {
    func testPrependFromEmpty() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.prependWithoutExpanding(1)
        XCTAssertEqual(Array(buffer), [1])
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependWithSpace() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: [1, 2, 3])
        buffer.prependWithoutExpanding(4)
        XCTAssertEqual(Array(buffer), [4, 1, 2, 3])
        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependWithExactlyEnoughSpace() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: 1..<15)
        buffer.prependWithoutExpanding(15)
        XCTAssertEqual(Array(buffer), [15, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependWithoutEnoughSpace() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: 1..<16)
        XCTAssertEqual(Array(buffer), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)

        buffer.prependWithoutExpanding(17)
        XCTAssertEqual(Array(buffer), [17, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependContentsOfWithLotsOfSpace() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(Array(buffer), [1, 2, 3])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.effectiveCapacity, 15)

        buffer.prependWithoutExpanding(contentsOf: [4, 5, 6])
        XCTAssertEqual(Array(buffer), [6, 5, 4, 1, 2, 3])
        XCTAssertEqual(buffer.count, 6)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependContentsOfWithExactlyTheSpace() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(Array(buffer), [1, 2, 3])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.effectiveCapacity, 15)

        buffer.prependWithoutExpanding(contentsOf: Array(4..<16))
        XCTAssertEqual(Array(buffer), [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 1, 2, 3])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependContentsOfWithEnoughSpaceIfWeRemoveAnElement() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(Array(buffer), [1, 2, 3])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.effectiveCapacity, 15)

        buffer.prependWithoutExpanding(contentsOf: Array(4..<17))
        XCTAssertEqual(Array(buffer), [16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 1, 2])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependContentsOfWithEnoughSpaceIfWeRemoveEverything() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(Array(buffer), [1, 2, 3])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.effectiveCapacity, 15)

        buffer.prependWithoutExpanding(contentsOf: Array(4..<19))
        XCTAssertEqual(Array(buffer), [18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependContentsOfWithoutEnoughSpaceButContainingElements() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(Array(buffer), [1, 2, 3])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.effectiveCapacity, 15)

        buffer.prependWithoutExpanding(contentsOf: Array(4..<32))
        XCTAssertEqual(Array(buffer), [31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependContentsOfWithExactlyTheSpaceFromEmpty() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.prependWithoutExpanding(contentsOf: Array(1..<16))
        XCTAssertEqual(Array(buffer), [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }

    func testPrependContentsOfWithoutEnoughSpaceFromEmpty() {
        var buffer = CircularBuffer<Int>(initialCapacity: 16)
        buffer.prependWithoutExpanding(contentsOf: Array(1..<32))
        XCTAssertEqual(Array(buffer), [31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17])
        XCTAssertEqual(buffer.count, 15)
        XCTAssertEqual(buffer.effectiveCapacity, 15)
    }
}
