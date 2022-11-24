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
import NIOHPACK
@testable import NIOHTTP2

class ContentLengthVerifierTests: XCTestCase {
    func testDuplicatedLengthHeadersPermitted() throws {
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))
        var verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("content-length", "1834")])
        verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("content-length", "1834")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))
        verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "1834")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))
        verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers))
        XCTAssertEqual(1834, verifier.expectedContentLength)
    }

    func testDuplicatedConflictingLengthHeadersThrow() throws {
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "4381")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers))
    }

    func testNumericallyEquivalentButConflictingLengthHeadersThrow() throws {
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "01834")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers))
    }
}
