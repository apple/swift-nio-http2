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
import NIOHPACK
import XCTest

class HPACKRegressionTests: XCTestCase {

    let allocator = ByteBufferAllocator()

    private func buffer<C: Collection>(wrapping bytes: C) -> ByteBuffer where C.Element == UInt8 {
        var buffer = allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    func testWikipediaHeaders() throws {
        // This is a simplified regression test for a bug we found when hitting Wikipedia.
        var headerBuffer = self.buffer(wrapping: [
            0x20,  // Header table size change to 0, which is the source of the bug.
            0x88,  // :status 200
            0x61, 0x96, 0xdf, 0x69, 0x7e, 0x94, 0x0b, 0x8a, 0x43, 0x5d, 0x8a, 0x08, 0x01, 0x7d, 0x40, 0x3d,
            0x71, 0xa6, 0x6e, 0x32, 0xd2, 0x98, 0xb4, 0x6f,  // An indexable date header, which triggers the bug.
        ])
        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        let decoded = try decoder.decodeHeaders(from: &headerBuffer)
        XCTAssertEqual(decoded, HPACKHeaders([(":status", "200"), ("date", "Tue, 16 Apr 2019 08:43:34 GMT")]))
    }

    func testHPACKDecoderForbidsZeroLengthFieldNames() throws {
        // This test validates the fix for CVE-XXXX: we reject header fields without a header field name.
        let request1 = buffer(wrapping: [
            0x00,  // Literal Header Field without Indexing - New Name
            0x00,  // Empty header field name, no huffman.
            0x01, 0x42,  // Header field value one character long, 'B', no huffman
        ])
        let request2 = buffer(wrapping: [
            0x00,  // Literal Header Field without Indexing - New Name
            0x80,  // Empty header field name with huffman.
            0x01, 0x42,  // Header field value one character long, 'B', no huffman.
        ])
        let request3 = buffer(wrapping: [
            0x40,  // Literal Header Field with Incremental Indexing - New Name
            0x00,  // Empty header field name, no huffman.
            0x01, 0x42,  // Header field value one character long, 'B', no huffman
        ])
        let request4 = buffer(wrapping: [
            0x40,  // Literal Header Field with Incremental Indexing - New Name
            0x80,  // Empty header field name with huffman.
            0x01, 0x42,  // Header field value one character long, 'B', no huffman.
        ])
        let request5 = buffer(wrapping: [
            0x10,  // Literal Header Field Never Indexed - New Name
            0x00,  // Empty header field name, no huffman.
            0x01, 0x42,  // Header field value one character long, 'B', no huffman
        ])
        let request6 = buffer(wrapping: [
            0x10,  // Literal Header Field Never Indexed - New Name
            0x80,  // Empty header field name with huffman.
            0x01, 0x42,  // Header field value one character long, 'B', no huffman.
        ])

        for var request in [request1, request2, request3, request4, request5, request6] {
            var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
            XCTAssertThrowsError(try decoder.decodeHeaders(from: &request)) { error in
                XCTAssertEqual(
                    error as? NIOHPACKErrors.EmptyLiteralHeaderFieldName,
                    NIOHPACKErrors.EmptyLiteralHeaderFieldName()
                )
            }
        }
    }
}
