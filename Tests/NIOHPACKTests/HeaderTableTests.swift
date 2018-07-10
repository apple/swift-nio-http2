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
import NIO
@testable import NIOHPACK

func XCTAssertEqualTuple<T1: Equatable, T2: Equatable>(_ expression1: @autoclosure () throws -> (T1, T2), _ expression2: @autoclosure () throws -> (T1, T2), _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    let ex1: (T1, T2)
    let ex2: (T1, T2)
    do {
        ex1 = try expression1()
        ex2 = try expression2()
    }
    catch {
        XCTFail("Unexpected exception: \(error) \(message())", file: file, line: line)
        return
    }
    
    XCTAssertEqual(ex1.0, ex2.0, message(), file: file, line: line)
    XCTAssertEqual(ex1.1, ex2.1, message(), file: file, line: line)
}

class HeaderTableTests: XCTestCase {

    func testStaticHeaderTable() {
        let table = IndexedHeaderTable()
        
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
        var table = IndexedHeaderTable(maxDynamicTableSize: 1024)
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
        table.maxDynamicTableLength = 128
        XCTAssertEqual(table.dynamicTableLength, 164 - 57)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "custom-key", value: "custom-value")!)
        XCTAssertEqualTuple((62, false), table.firstHeaderMatch(for: "custom-key", value: "other-value")!)
        XCTAssertEqualTuple((63, true), table.firstHeaderMatch(for: "cache-control", value: "no-cache")!)
        XCTAssertEqualTuple((1, false), table.firstHeaderMatch(for: ":authority", value: "www.example.com")!)   // will find the header name in static table
        
        table.maxDynamicTableLength = 64
        XCTAssertEqual(table.dynamicTableLength, 164 - 110)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "custom-key", value: "custom-value")!)
        XCTAssertEqualTuple((62, false), table.firstHeaderMatch(for: "custom-key", value: "other-value")!)
        XCTAssertEqualTuple((24, false), table.firstHeaderMatch(for: "cache-control", value: "no-cache")!)  // will find the header name in static table
        XCTAssertEqualTuple((1, false), table.firstHeaderMatch(for: ":authority", value: "www.example.com")!)   // will find the header name in static table
        
        table.maxDynamicTableLength = 164 - 110    // should cause no evictions
        XCTAssertEqual(table.dynamicTableLength, 164 - 110)
        XCTAssertEqualTuple((62, true), table.firstHeaderMatch(for: "custom-key", value: "custom-value")!)
        
        // get code coverage for dynamic table search with no value to match
        // Note that the resulting index is an index into the dynamic table only, so we
        // have to modify it to check that it's what we expect.
        XCTAssertEqualTuple((62 - StaticHeaderTable.count, false), table.dynamicTable.findExistingHeader(named: "custom-key".utf8)!)
        
        // evict final entry
        table.maxDynamicTableLength = table.dynamicTableLength - 1
        XCTAssertEqual(table.dynamicTableLength, 0)
        XCTAssertNil(table.firstHeaderMatch(for: "custom-key", value: "custom-value"))
    }

}
