//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
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
}
