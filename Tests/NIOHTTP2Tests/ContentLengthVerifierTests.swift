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

import NIOHPACK
import XCTest

@testable import NIOHTTP2

class ContentLengthVerifierTests: XCTestCase {
    func testDuplicatedLengthHeadersPermitted() throws {
        var headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0"),
        ])
        XCTAssertNoThrow(try ContentLengthVerifier(headers, requestMethod: nil))
        var verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("content-length", "1834")])
        verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("content-length", "1834")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers, requestMethod: nil))
        verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "1834")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers, requestMethod: nil))
        verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)
    }

    func testDuplicatedConflictingLengthHeadersThrow() throws {
        var headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0"),
        ])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "4381")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeadersMismatch)
        }
    }

    func testNumericallyEquivalentButConflictingLengthHeadersThrow() throws {
        var headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0"),
        ])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "01834")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeadersMismatch)
        }
    }

    func testNegativeLengthHeaderThrows() throws {
        let headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "-1"), ("User-Agent", "myCoolClient/1.0"),
        ])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderNegative)
        }
    }

    func testMinIntLengthHeaderDoesntPanic() throws {
        let headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", String(Int.min)), ("User-Agent", "myCoolClient/1.0"),
        ])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderNegative)
        }
    }

    func testMaxIntLengthHeaderDoesntPanic() throws {
        let headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", String(Int.max)), ("User-Agent", "myCoolClient/1.0"),
        ])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(Int.max, verifier.expectedContentLength)
    }

    func testInvalidLengthHeaderValuesThrow() throws {
        var headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "0xFF"), ("User-Agent", "myCoolClient/1.0"),
        ])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderMalformedValue)
        }

        // Int.min - 1
        headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "-9223372036854775809"), ("User-Agent", "myCoolClient/1.0"),
        ])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderMalformedValue)
        }

        // Int.max + 1
        headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "9223372036854775809"), ("User-Agent", "myCoolClient/1.0"),
        ])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderMalformedValue)
        }
    }

    func testContentLengthVerifier_whenResponseStatusIs304() throws {
        let headers = HPACKHeaders([
            (":status", "304"), ("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0"),
        ])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: "GET"))
        XCTAssertEqual(0, verifier.expectedContentLength)
    }

    func testContentLengthVerifier_whenRequestMethodIsHead() throws {
        let headers = HPACKHeaders([
            ("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0"),
        ])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: "HEAD"))
        XCTAssertEqual(0, verifier.expectedContentLength)
    }
}
