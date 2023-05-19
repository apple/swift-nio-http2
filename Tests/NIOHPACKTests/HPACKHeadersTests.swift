//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOCore
import NIOHPACK
import NIOHTTP1

final class HPACKHeadersTests: XCTestCase {
    func testHPACKHeadersAreHashable() throws {
        let firstHeaders = HPACKHeaders([
            (":foo", "bar"),
            (":bar", "baz"),
            ("boz", "box"),
            ("fox", "fro"),
        ])
        // The same as firstHeaders but in a different order.
        let secondHeaders = HPACKHeaders([
            (":bar", "baz"),
            (":foo", "bar"),
            ("fox", "fro"),
            ("boz", "box"),
        ])
        // Differs by one name from firstHeaders
        let thirdHeaders = HPACKHeaders([
            (":foo", "bar"),
            (":bar", "baz"),
            ("boz", "box"),
            ("fax", "fro"),
        ])
        // Differs by one value from firstHeaders
        let fourthHeaders = HPACKHeaders([
            (":foo", "bar"),
            (":bar", "baz"),
            ("boz", "box"),
            ("fox", "fra"),
        ])

        // First, confirm all things hash to themselves. This proves basic hashing correctness.
        XCTAssertEqual(
            Set([firstHeaders, firstHeaders]),
            Set([firstHeaders])
        )
        XCTAssertEqual(
            Set([secondHeaders, secondHeaders]),
            Set([secondHeaders])
        )
        XCTAssertEqual(
            Set([thirdHeaders, thirdHeaders]),
            Set([thirdHeaders])
        )
        XCTAssertEqual(
            Set([fourthHeaders, fourthHeaders]),
            Set([fourthHeaders])
        )

        // Next, prove we can discriminate between different things. Here, importantly, secondHeaders is removed, as
        // it hashes equal to firstHeaders.
        XCTAssertEqual(
            Set([firstHeaders, secondHeaders, thirdHeaders, fourthHeaders]),
            Set([firstHeaders, thirdHeaders, fourthHeaders])
        )
    }

    func testNormalizationOfHTTPHeaders() {
        let httpHeaders: HTTPHeaders = [
            "connection": "keepalive",
            "connection": "remove-me, and-me",
            "connection": "also-me-please",
            "remove-me": "",
            "and-me": "",
            "also-me-please": "",
            "but-not-me": "",
            "keep-alive": "remove-me",
            "proxy-connection": "me too",
            "transfer-encoding": "me three"
        ]

        let normalized = HPACKHeaders(httpHeaders: httpHeaders, normalizeHTTPHeaders: true)
        let expected: HPACKHeaders = [
            "but-not-me": ""
        ]

        XCTAssertEqual(normalized, expected)
    }

    func testNormalizationOfHTTPHeadersWithManyConnectionHeaderValues() {
        var httpHeaders: HTTPHeaders = [
            "keep-alive": "remove-me",
            "proxy-connection": "me too",
            "transfer-encoding": "me three",
            "but-not-me": "",
        ]

        // Add a bunch of connection headers to remove. We add a large number because the
        // implementation of the normalizing init branches on the number of connection header
        // values.
        for i in 0 ..< 512 {
            let toRemove = "value-\(i)"
            httpHeaders.add(name: "connection", value: toRemove)
            httpHeaders.add(name: toRemove, value: "")
        }

        let normalized = HPACKHeaders(httpHeaders: httpHeaders, normalizeHTTPHeaders: true)
        let expected: HPACKHeaders = [
            "but-not-me": ""
        ]

        XCTAssertEqual(normalized, expected)
    }

    func testValuesSequence() {
        let headers: HPACKHeaders = [
            "foo": "bar",
            "bar": "foo",
            "foo": "baz",
            "foo": "bar,baz",
            "foo": " bar ,baz ,,",
            "bar": "foo"
        ]

        let values = headers.values(forHeader: "foo", canonicalForm: false)
        var iterator = values.makeIterator()
        XCTAssertEqual(iterator.next(), "bar")
        XCTAssertEqual(iterator.next(), "baz")
        XCTAssertEqual(iterator.next(), "bar,baz")
        XCTAssertEqual(iterator.next(), " bar ,baz ,,")
        XCTAssertNil(iterator.next())
        XCTAssertNil(iterator.next()) // Still nil
    }

    func testValuesSequenceInCanonicalForm() {
        let headers: HPACKHeaders = [
            "foo": "bar",
            "bar": "foo",
            "foo": "baz",
            "foo": "bar,baz",
            "foo": " bar ,baz ,,",
            "bar": "foo"
        ]

        let values = headers.values(forHeader: "foo", canonicalForm: true)
        var iterator = values.makeIterator()
        XCTAssertEqual(iterator.next(), "bar")
        XCTAssertEqual(iterator.next(), "baz")
        XCTAssertEqual(iterator.next(), "bar")
        XCTAssertEqual(iterator.next(), "baz")
        XCTAssertEqual(iterator.next(), "bar")
        XCTAssertEqual(iterator.next(), "baz")
        XCTAssertNil(iterator.next())
        XCTAssertNil(iterator.next()) // Still nil
    }

    func testValuesSequenceIgnoresCanonicalFormForSetCookie() {
        let expected = [
            "haha,you,wont,split,me,im,set-cookie",
            "but we should still get multiple values"
        ]

        var headers = HPACKHeaders()
        for value in expected {
            headers.add(name: "set-cookie", value: value)
        }

        for name in ["set-cookie", "Set-Cookie"] {
            for canonical in [true, false] {
                let values = Array(headers.values(forHeader: name, canonicalForm: canonical))
                XCTAssertEqual(values, expected.map { $0[...] })
            }
        }
    }

    func testRemoveAll() {
        let original: HPACKHeaders = [
            "foo": "bar",
            "bar": "foo",
            "foo": "baz",
            "foo": "bar,baz",
            "foo": " bar ,baz ,,",
            "bar": "foo"
        ]

        let originalCapacity = original.capacity
        var keepCapacity = original
        XCTAssertEqual(keepCapacity.count, 6)
        XCTAssertEqual(keepCapacity.capacity, originalCapacity)
        keepCapacity.removeAll(keepingCapacity: true)
        XCTAssertEqual(keepCapacity.count, 0)
        XCTAssertEqual(keepCapacity.capacity, originalCapacity)

        var lowerCapacity = original
        XCTAssertEqual(lowerCapacity.count, 6)
        XCTAssertEqual(lowerCapacity.capacity, originalCapacity)
        lowerCapacity.removeAll(keepingCapacity: false)
        XCTAssertEqual(lowerCapacity.count, 0)
        XCTAssertEqual(lowerCapacity.capacity, 0)
    }
}
