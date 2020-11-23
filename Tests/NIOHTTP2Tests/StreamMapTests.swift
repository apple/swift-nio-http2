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

final class StreamMapTests: XCTestCase {
    func testContainsSmall() throws {
        var map = StreamMap<StreamData>()

        // Stuff some stream IDs in. We need even _and_ odd stream IDs, and gaps.
        for number in stride(from: 1, to: 1000, by: 3) {
            map.insert(StreamData(number))
        }

        for number in 1..<1000 {
            let contains = map.contains(streamID: HTTP2StreamID(number))
            if number % 3 == 1 {
                XCTAssertTrue(contains)
            } else {
                XCTAssertFalse(contains)
            }
        }
    }

    func testContainsLarge() throws {
        var map = StreamMap<StreamData>()

        // Stuff some stream IDs in. We need even _and_ odd stream IDs, and gaps.
        for number in stride(from: 1, to: 10000, by: 3) {
            map.insert(StreamData(number))
        }

        for number in 1..<10000 {
            let contains = map.contains(streamID: HTTP2StreamID(number))
            if number % 3 == 1 {
                XCTAssertTrue(contains)
            } else {
                XCTAssertFalse(contains)
            }
        }
    }

    func testCanForEach() throws {
        var map = StreamMap<StreamData>()

        // Stuff some stream IDs in.
        for number in 1..<100 {
            map.insert(StreamData(number))
        }

        var result = Array<Int32>()
        map.forEachValue {
            result.append($0.streamID.networkStreamID)
        }

        XCTAssertEqual(result.sorted(), Array(1..<100))
    }

    func testCanMutatingForEach() throws {
        var map = StreamMap<StreamDataWithValue<Int>>()

        // Stuff some stream data in.
        for number in 1..<100 {
            map.insert(StreamDataWithValue(number, value: number))
        }

        var result = Array<Int>()
        map.forEachValue {
            result.append($0.value)
        }

        XCTAssertEqual(result.sorted(), Array(1..<100))

        // Modify the data
        map.mutatingForEachValue {
            $0.value *= 2
        }

        // Check the modifications stuck.
        result.removeAll(keepingCapacity: true)
        map.forEachValue {
            result.append($0.value)
        }

        XCTAssertEqual(result.sorted(), Array(1..<100).map { $0 * 2 })
    }

    func testCanFindElements() throws {
        var map = StreamMap<StreamDataWithValue<Int>>()

        // Stuff some stream data in.
        for number in 1..<100 {
            map.insert(StreamDataWithValue(number, value: number))
        }

        XCTAssertEqual(map.elements(initiatedBy: .client).map { $0.value }, Array(stride(from: 1, to: 100, by: 2)))
        XCTAssertEqual(map.elements(initiatedBy: .server).map { $0.value }, Array(stride(from: 2, to: 100, by: 2)))
    }

    func testRemoval() throws {
        var map = StreamMap<StreamData>()

        // Stuff some stream IDs in. We need even _and_ odd stream IDs, and gaps.
        for number in 1..<100 {
            map.insert(StreamData(number))
        }

        // Delete a few.
        for number in stride(from: 1, to: 100, by: 3) {
            let removed = map.removeValue(forStreamID: HTTP2StreamID(number))
            XCTAssertEqual(removed?.streamID, HTTP2StreamID(number))
        }

        // Now validate what's there.
        var result = Array<Int32>()
        map.forEachValue {
            result.append($0.streamID.networkStreamID)
        }

        XCTAssertEqual(result.sorted(), Array(1..<100).filter { $0 % 3 != 1 })

        // Now try to remove the ones we already removed. Nothing should be returned.
        for number in stride(from: 1, to: 100, by: 3) {
            let removed = map.removeValue(forStreamID: HTTP2StreamID(number))
            XCTAssertNil(removed)
        }
    }

    func testModifySpecificValue() throws {
        var map = StreamMap<StreamDataWithValue<Bool>>()

        // Stuff some stream data in.
        for number in 1..<100 {
            map.insert(StreamDataWithValue(number, value: true))
        }

        // Now let's flip some bools.
        for number in stride(from: 1, to: 100, by: 5) {
            let result: Bool? = map.modify(streamID: HTTP2StreamID(number)) {
                let oldValue = $0.value
                $0.value = false
                return oldValue
            }
            XCTAssertEqual(result, true)
        }

        // Check all the values.
        var result = Array<StreamDataWithValue<Bool>>()
        map.forEachValue {
            result.append($0)
        }
        XCTAssertEqual(result.sorted(by: { $0.streamID < $1.streamID }).map { $0.value },
                       Array(1..<100).map { $0 % 5 == 1 ? false : true })

        // Modifying something that isn't present should do nothing and not execute the block.
        // We do this once for the server-side and once for the client-side.
        XCTAssertNil(map.modify(streamID: 101) { _ in XCTFail("must not execute") })
        XCTAssertNil(map.modify(streamID: 102) { _ in XCTFail("must not execute") })
    }
}

struct StreamData: PerStreamData {
    var streamID: HTTP2StreamID

    init(_ rawNumber: Int) {
        self.streamID = HTTP2StreamID(rawNumber)
    }
}

struct StreamDataWithValue<Value>: PerStreamData {
    var streamID: HTTP2StreamID

    var value: Value

    init(_ rawNumber: Int, value: Value) {
        self.streamID = HTTP2StreamID(rawNumber)
        self.value = value
    }
}
