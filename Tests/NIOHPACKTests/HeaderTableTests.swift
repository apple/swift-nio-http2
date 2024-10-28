//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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

@testable import NIOHPACK

func XCTAssertEqualTuple<T1: Equatable, T2: Equatable>(
    _ expression1: @autoclosure () throws -> (T1, T2)?,
    _ expression2: @autoclosure () throws -> (T1, T2)?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let ex1: (T1, T2)?
    let ex2: (T1, T2)?
    do {
        ex1 = try expression1()
        ex2 = try expression2()
    } catch {
        XCTFail("Unexpected exception: \(error) \(message())", file: (file), line: line)
        return
    }

    let left1 = ex1?.0
    let right1 = ex2?.0
    let left2 = ex1?.1
    let right2 = ex2?.1

    XCTAssertEqual(left1, right1, message(), file: (file), line: line)
    XCTAssertEqual(left2, right2, message(), file: (file), line: line)
}

class HeaderTableTests: XCTestCase {

    func testStaticHeaderTable() {
        let table = IndexedHeaderTable(allocator: ByteBufferAllocator())

        // headers with matching values
        XCTAssertEqualTuple((2, true), table.firstHeaderMatch(for: ":method", value: "GET")!)
        XCTAssertEqualTuple((3, true), table.firstHeaderMatch(for: ":method", value: "POST")!)
        XCTAssertEqualTuple((4, true), table.firstHeaderMatch(for: ":path", value: "/")!)
        XCTAssertEqualTuple((5, true), table.firstHeaderMatch(for: ":path", value: "/index.html")!)
        XCTAssertEqualTuple((8, true), table.firstHeaderMatch(for: ":status", value: "200")!)
        XCTAssertEqualTuple((13, true), table.firstHeaderMatch(for: ":status", value: "404")!)
        XCTAssertEqualTuple((14, true), table.firstHeaderMatch(for: ":status", value: "500")!)
        XCTAssertEqualTuple((16, true), table.firstHeaderMatch(for: "accept-encoding", value: "gzip, deflate")!)

        // headers with no values in the table
        XCTAssertEqualTuple((15, false), table.firstHeaderMatch(for: "accept-charset", value: "any")!)
        XCTAssertEqualTuple((24, false), table.firstHeaderMatch(for: "cache-control", value: "private")!)

        // header-only matches for table entries with a different value
        XCTAssertEqualTuple((8, false), table.firstHeaderMatch(for: ":status", value: "501")!)
        XCTAssertEqualTuple((4, false), table.firstHeaderMatch(for: ":path", value: "/test/path.html")!)
        XCTAssertEqualTuple((2, false), table.firstHeaderMatch(for: ":method", value: "CONNECT")!)

        // things that aren't in the table at all
        XCTAssertNil(table.firstHeaderMatch(for: "non-existent-key", value: "non-existent-value"))
    }

    func testDynamicTableInsertion() {
        // NB: I'm using the overall table class to verify the expected indices of dynamic table items.
        var table = IndexedHeaderTable(allocator: ByteBufferAllocator(), maxDynamicTableSize: 1024)
        XCTAssertEqual(table.dynamicTableLength, 0)

        XCTAssertNoThrow(try table.add(headerNamed: ":authority", value: "www.example.com"))
        XCTAssertEqual(table.dynamicTableLength, 57)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: ":authority", value: "www.example.com")!)
        XCTAssertEqualTuple((1, false), table.firstHeaderMatch(for: ":authority", value: "www.something-else.com")!)

        XCTAssertNoThrow(try table.add(headerNamed: "cache-control", value: "no-cache"))
        XCTAssertEqual(table.dynamicTableLength, 110)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "cache-control", value: "no-cache")!)
        XCTAssertEqualTuple((63, true), table.firstHeaderMatch(for: ":authority", value: "www.example.com")!)

        // custom key not yet in the table, should return nil
        XCTAssertNil(table.firstHeaderMatch(for: "custom-key", value: "custom-value"))

        XCTAssertNoThrow(try table.add(headerNamed: "custom-key", value: "custom-value"))
        XCTAssertEqual(table.dynamicTableLength, 164)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "custom-key", value: "custom-value")!)
        XCTAssertEqualTuple((62, false), table.firstHeaderMatch(for: "custom-key", value: "other-value")!)
        XCTAssertEqualTuple((63, true), table.firstHeaderMatch(for: "cache-control", value: "no-cache")!)
        XCTAssertEqualTuple((64, true), table.firstHeaderMatch(for: ":authority", value: "www.example.com")!)

        // should evict the first-inserted value (:authority = www.example.com)
        table.dynamicTableAllowedLength = 128
        XCTAssertEqual(table.dynamicTableLength, 164 - 57)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "custom-key", value: "custom-value")!)
        XCTAssertEqualTuple((62, false), table.firstHeaderMatch(for: "custom-key", value: "other-value")!)
        XCTAssertEqualTuple((63, true), table.firstHeaderMatch(for: "cache-control", value: "no-cache")!)
        // will find the header name in static table
        XCTAssertEqualTuple((1, false), table.firstHeaderMatch(for: ":authority", value: "www.example.com")!)

        table.dynamicTableAllowedLength = 64
        XCTAssertEqual(table.dynamicTableLength, 164 - 110)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "custom-key", value: "custom-value")!)
        XCTAssertEqualTuple((62, false), table.firstHeaderMatch(for: "custom-key", value: "other-value")!)
        // will find the header name in static table
        XCTAssertEqualTuple((24, false), table.firstHeaderMatch(for: "cache-control", value: "no-cache")!)
        // will find the header name in static table
        XCTAssertEqualTuple((1, false), table.firstHeaderMatch(for: ":authority", value: "www.example.com")!)

        table.dynamicTableAllowedLength = 164 - 110  // should cause no evictions
        XCTAssertEqual(table.dynamicTableLength, 164 - 110)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "custom-key", value: "custom-value")!)

        // get code coverage for dynamic table search with no value to match
        // Note that the resulting index is an index into the dynamic table only, so we
        // have to modify it to check that it's what we expect.
        if let found = table.dynamicTable.findExistingHeader(named: "custom-key", value: nil) {
            XCTAssertEqualTuple((62 - StaticHeaderTable.count, false), found)
        }

        // evict final entry
        table.dynamicTableAllowedLength = table.dynamicTableLength - 1
        XCTAssertEqual(table.dynamicTableLength, 0)
        XCTAssertNil(table.firstHeaderMatch(for: "custom-key", value: "custom-value"))
    }

    func testHeaderDump() throws {
        var table = IndexedHeaderTable(allocator: ByteBufferAllocator())
        let description = table.dumpHeaders()

        // construct what we expect
        var expected = StaticHeaderTable.enumerated().reduce("") {
            $0 + "\($1.0) - \($1.1.0) : \($1.1.1)\n"
        }

        // there will be a newline at the end, followed by no data for the dynamic table
        expected += "\n"

        XCTAssertEqual(description, expected)

        // add an item to the dynamic table
        try table.add(headerNamed: "custom-key", value: "custom-value")
        expected += "\(StaticHeaderTable.count) - custom-key : custom-value\n"

        let description2 = table.dumpHeaders()
        XCTAssertEqual(description2, expected)
    }

    func testHeaderDescription() throws {
        let table = IndexedHeaderTable(allocator: ByteBufferAllocator())
        let staticDescription = table.staticTable.description
        let staticExpected = StaticHeaderTable.description
        XCTAssertEqual(staticDescription, staticExpected)
    }

    func testDynamicTableEntryCanBeFoundAsPartialMatch() {
        // We're going to insert a header to the dynamic table.
        var table = IndexedHeaderTable(allocator: ByteBufferAllocator(), maxDynamicTableSize: 1024)
        XCTAssertNoThrow(try table.add(headerNamed: "foo", value: "bar"))

        // Now we're going to attempt to find it in three ways. The first is where we care about an exact match and
        // pass a matching value.
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "foo", value: "bar"))

        // Next, ask for a full match with the wrong value. We should get a partial match.
        XCTAssertEqualTuple((62, false), table.firstHeaderMatch(for: "foo", value: "baz"))

        // Next, ask for a partial match where we don't care about the value. We should still get a partial match.
        XCTAssertEqualTuple((62, false), table.firstHeaderMatch(for: "foo", value: nil))
    }
}
