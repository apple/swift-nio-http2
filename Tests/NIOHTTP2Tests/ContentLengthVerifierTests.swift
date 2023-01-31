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
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "4381")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeadersMismatch)
        }
    }

    func testNumericallyEquivalentButConflictingLengthHeadersThrow() throws {
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(1834, verifier.expectedContentLength)

        headers.add(contentsOf: [("Content-Length", "01834")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeadersMismatch)
        }
    }

    func testNegativeLengthHeaderThrows() throws {
        let headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "-1"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderNegative)
        }
    }

    func testMinIntLengthHeaderDoesntPanic() throws {
        let headers = HPACKHeaders([("Host", "apple.com"), ("content-length", String(Int.min)), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderNegative)
        }
    }

    func testMaxIntLengthHeaderDoesntPanic() throws {
        let headers = HPACKHeaders([("Host", "apple.com"), ("content-length", String(Int.max)), ("User-Agent", "myCoolClient/1.0")])
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: nil))
        XCTAssertEqual(Int.max, verifier.expectedContentLength)
    }

    func testInvalidLengthHeaderValuesThrow() throws {
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "0xFF"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderMalformedValue)
        }

        // Int.min - 1
        headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "-9223372036854775809"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderMalformedValue)
        }

        // Int.max + 1
        headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "9223372036854775809"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers, requestMethod: nil)) { error in
            XCTAssertTrue(error is NIOHTTP2Errors.ContentLengthHeaderMalformedValue)
        }
    }

    func testContentLengthVerifier_whenRequestMethod() throws {
        let headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0"), (":status", "304")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers, requestMethod: "GET"))
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: "GET"))
        XCTAssertEqual(0, verifier.expectedContentLength)
    }


    func testContentLengthVerifier_whenRequestMethodofHead() throws {
        let headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers, requestMethod: "HEAD"))
        let verifier = try assertNoThrowWithValue(try ContentLengthVerifier(headers, requestMethod: "HEAD"))
        XCTAssertEqual(0, verifier.expectedContentLength)
    }



//    want top to bottom testing
//    want to confirm it does the right thing wiht the right inputs

//    when we are running the whole stack, everyone is keeping track of what the correct content length is

//    function in the radar that doesn't work 
//    func testHeadAsVerb() throws {
//        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
//        defer { try! client.syncShutdown() }
//        do {
//            var req = HTTPClientRequest(url: "https://service.results.apple.com/api/v0/result/test")
//
//            // ### This is the important bit ####
//            req.method = .HEAD
//
//            _ = try await client.execute(req, timeout: .seconds(10))
//        } catch {
//            XCTFail(">\(error)")
//        }
//    }
}
