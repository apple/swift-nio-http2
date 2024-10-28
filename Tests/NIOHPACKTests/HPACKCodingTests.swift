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

class HPACKCodingTests: XCTestCase {

    let allocator = ByteBufferAllocator()

    private func buffer<C: Collection>(wrapping bytes: C) -> ByteBuffer where C.Element == UInt8 {
        var buffer = allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    // HPACK RFC7541 § C.3
    // http://httpwg.org/specs/rfc7541.html#request.examples.without.huffman.coding
    func testRequestHeadersWithoutHuffmanCoding() throws {
        var request1 = buffer(wrapping: [
            0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63,
            0x6f, 0x6d,
        ])
        var request2 = buffer(wrapping: [
            0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 0x6e, 0x6f, 0x2d, 0x63, 0x61, 0x63, 0x68, 0x65,
        ])
        var request3 = buffer(wrapping: [
            0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b, 0x65, 0x79, 0x0c, 0x63,
            0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x76, 0x61, 0x6c, 0x75, 0x65,
        ])

        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
        ])
        let headers2 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache"),
        ])
        let headers3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html"),
            (":authority", "www.example.com"),
            ("custom-key", "custom-value"),
        ])

        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        XCTAssertEqual(decoder.dynamicTableLength, 0)

        let decoded1 = try decoder.decodeHeaders(from: &request1)
        XCTAssertEqual(decoded1, headers1)
        XCTAssertEqual(decoder.dynamicTableLength, 57)
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 62))

        let decoded2 = try decoder.decodeHeaders(from: &request2)
        XCTAssertEqual(decoded2, headers2)
        XCTAssertEqual(decoder.dynamicTableLength, 110)
        XCTAssertEqualTuple(headers2[4], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 63))

        let decoded3 = try decoder.decodeHeaders(from: &request3)
        XCTAssertEqual(decoded3, headers3)
        XCTAssertEqual(decoder.dynamicTableLength, 164)
        XCTAssertEqualTuple(headers3[4], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers2[4], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 64))
    }

    // HPACK RFC7541 § C.4
    // http://httpwg.org/specs/rfc7541.html#request.examples.with.huffman.coding
    func testRequestHeadersWithHuffmanCoding() throws {
        var request1 = buffer(wrapping: [
            0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
        ])
        var request2 = buffer(wrapping: [0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf])
        var request3 = buffer(wrapping: [
            0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25, 0xa8, 0x49,
            0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf,
        ])

        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
        ])
        let headers2 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache"),
        ])
        let headers3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html"),
            (":authority", "www.example.com"),
            ("custom-key", "custom-value"),
        ])

        var encoder = HPACKEncoder(allocator: allocator)

        try encoder.beginEncoding(allocator: allocator)
        try encoder.append(headers: headers1)
        XCTAssertEqual(try encoder.endEncoding(), request1)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 57)
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 62))

        try encoder.beginEncoding(allocator: allocator)
        try encoder.append(headers: headers2)
        XCTAssertEqual(try encoder.endEncoding(), request2)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 110)
        XCTAssertEqualTuple(headers2[4], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 63))

        try encoder.beginEncoding(allocator: allocator)
        try encoder.append(headers: headers3)
        XCTAssertEqual(try encoder.endEncoding(), request3)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 164)
        XCTAssertEqualTuple(headers3[4], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers2[4], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 64))

        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        XCTAssertEqual(decoder.dynamicTableLength, 0)

        let decoded1 = try decoder.decodeHeaders(from: &request1)
        XCTAssertEqual(decoded1, headers1)
        XCTAssertEqual(decoder.dynamicTableLength, 57)
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 62))

        let decoded2 = try decoder.decodeHeaders(from: &request2)
        XCTAssertEqual(decoded2, headers2)
        XCTAssertEqual(decoder.dynamicTableLength, 110)
        XCTAssertEqualTuple(headers2[4], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 63))

        let decoded3 = try decoder.decodeHeaders(from: &request3)
        XCTAssertEqual(decoded3, headers3)
        XCTAssertEqual(decoder.dynamicTableLength, 164)
        XCTAssertEqualTuple(headers3[4], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers2[4], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 64))
    }

    // HPACK RFC7541 § C.5
    // http://httpwg.org/specs/rfc7541.html#response.examples.without.huffman.coding
    func testResponseHeadersWithoutHuffmanCoding() throws {
        var response1 = buffer(wrapping: [
            // :status: 302
            0x48, 0x03, 0x33, 0x30, 0x32,
            // cache-control: private
            0x58, 0x07, 0x70, 0x72, 0x69, 0x76, 0x61, 0x74, 0x65,
            // date: Mon, 21 Oct 2013 20:13:21 GMT
            0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33,
            0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x31, 0x20, 0x47, 0x4d, 0x54,
            // location: https://www.example.com
            0x6e, 0x17, 0x68, 0x74, 0x74, 0x70, 0x73, 0x3a, 0x2f, 0x2f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d,
            0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d,
        ])
        var response2 = buffer(wrapping: [
            // :status: 307
            0x48, 0x03, 0x33, 0x30, 0x37,
            // cache-control: private
            0xc1,
            // date: Mon, 21 Oct 2013 20:13:21 GMT
            0xc0,
            // location: https://www.example.com
            0xbf,
        ])
        var response3 = buffer(wrapping: [
            // :status: 200
            0x88,
            // cache-control: private
            0xc1,
            // date: Mon, 21 Oct 2013 20:13:22 GMT
            0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33,
            0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x32, 0x20, 0x47, 0x4d, 0x54,
            // location: https://www.example.com
            0xc0,
            // content-encoding: gzip
            0x5a, 0x04, 0x67, 0x7a, 0x69, 0x70,
            // set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1
            0x77, 0x38, 0x66, 0x6f, 0x6f, 0x3d, 0x41, 0x53, 0x44, 0x4a, 0x4b, 0x48, 0x51, 0x4b, 0x42, 0x5a, 0x58, 0x4f,
            0x51, 0x57, 0x45, 0x4f, 0x50, 0x49, 0x55, 0x41, 0x58, 0x51, 0x57, 0x45, 0x4f, 0x49, 0x55, 0x3b, 0x20, 0x6d,
            0x61, 0x78, 0x2d, 0x61, 0x67, 0x65, 0x3d, 0x33, 0x36, 0x30, 0x30, 0x3b, 0x20, 0x76, 0x65, 0x72, 0x73, 0x69,
            0x6f, 0x6e, 0x3d, 0x31,
        ])

        let headers1 = HPACKHeaders([
            (":status", "302"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com"),
        ])
        let headers2 = HPACKHeaders([
            (":status", "307"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com"),
        ])
        let headers3 = HPACKHeaders([
            (":status", "200"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:22 GMT"),
            ("location", "https://www.example.com"),
            ("content-encoding", "gzip"),
            ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"),
        ])

        var decoder = HPACKDecoder(allocator: ByteBufferAllocator(), maxDynamicTableSize: 256)
        XCTAssertEqual(decoder.dynamicTableLength, 0)

        let decoded1 = try decoder.decodeHeaders(from: &response1)
        XCTAssertEqual(decoded1, headers1)
        XCTAssertEqual(decoder.dynamicTableLength, 222)
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers1[2], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers1[1], try decoder.headerTable.header(at: 64))
        XCTAssertEqualTuple(headers1[0], try decoder.headerTable.header(at: 65))

        let decoded2 = try decoder.decodeHeaders(from: &response2)
        XCTAssertEqual(decoded2, headers2)
        XCTAssertEqual(decoder.dynamicTableLength, 222)
        XCTAssertEqualTuple(headers2[0], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers1[2], try decoder.headerTable.header(at: 64))
        XCTAssertEqualTuple(headers1[1], try decoder.headerTable.header(at: 65))

        let decoded3 = try decoder.decodeHeaders(from: &response3)
        XCTAssertEqual(decoded3, headers3)
        XCTAssertEqual(decoder.dynamicTableLength, 215)
        XCTAssertEqualTuple(headers3[5], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers3[4], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers3[2], try decoder.headerTable.header(at: 64))
    }

    // HPACK RFC7541 § C.6
    // http://httpwg.org/specs/rfc7541.html#response.examples.with.huffman.coding
    func testResponseHeadersWithHuffmanCoding() throws {
        var response1 = buffer(wrapping: [
            0x48, 0x82, 0x64, 0x02, 0x58, 0x85, 0xae, 0xc3, 0x77, 0x1a, 0x4b, 0x61, 0x96, 0xd0, 0x7a, 0xbe, 0x94, 0x10,
            0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0, 0x82, 0xa6, 0x2d, 0x1b, 0xff, 0x6e,
            0x91, 0x9d, 0x29, 0xad, 0x17, 0x18, 0x63, 0xc7, 0x8f, 0x0b, 0x97, 0xc8, 0xe9, 0xae, 0x82, 0xae, 0x43, 0xd3,
        ])
        var response2 = buffer(wrapping: [
            0x48, 0x83, 0x64, 0x0e, 0xff, 0xc1, 0xc0, 0xbf,
        ])
        var response3 = buffer(wrapping: [
            0x88, 0xc1, 0x61, 0x96, 0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b,
            0x81, 0x66, 0xe0, 0x84, 0xa6, 0x2d, 0x1b, 0xff, 0xc0, 0x5a, 0x83, 0x9b, 0xd9, 0xab, 0x77, 0xad, 0x94, 0xe7,
            0x82, 0x1d, 0xd7, 0xf2, 0xe6, 0xc7, 0xb3, 0x35, 0xdf, 0xdf, 0xcd, 0x5b, 0x39, 0x60, 0xd5, 0xaf, 0x27, 0x08,
            0x7f, 0x36, 0x72, 0xc1, 0xab, 0x27, 0x0f, 0xb5, 0x29, 0x1f, 0x95, 0x87, 0x31, 0x60, 0x65, 0xc0, 0x03, 0xed,
            0x4e, 0xe5, 0xb1, 0x06, 0x3d, 0x50, 0x07,
        ])

        let headers1 = HPACKHeaders([
            (":status", "302"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com"),
        ])
        let headers2 = HPACKHeaders([
            (":status", "307"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com"),
        ])
        let headers3 = HPACKHeaders([
            (":status", "200"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:22 GMT"),
            ("location", "https://www.example.com"),
            ("content-encoding", "gzip"),
            ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"),
        ])

        var encoder = HPACKEncoder(allocator: allocator)

        try encoder.beginEncoding(allocator: allocator)
        try encoder.append(headers: headers1)
        XCTAssertEqual(try encoder.endEncoding(), response1)
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers1[2], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers1[1], try encoder.headerIndexTable.header(at: 64))
        XCTAssertEqualTuple(headers1[0], try encoder.headerIndexTable.header(at: 65))

        try encoder.beginEncoding(allocator: allocator)
        try encoder.append(headers: headers2)
        XCTAssertEqual(try encoder.endEncoding(), response2)
        XCTAssertEqualTuple(headers2[0], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers1[2], try encoder.headerIndexTable.header(at: 64))
        XCTAssertEqualTuple(headers1[1], try encoder.headerIndexTable.header(at: 65))

        try encoder.beginEncoding(allocator: allocator)
        try encoder.append(headers: headers3)
        XCTAssertEqual(try encoder.endEncoding(), response3)
        XCTAssertEqualTuple(headers3[5], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers3[4], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers3[2], try encoder.headerIndexTable.header(at: 64))

        var decoder = HPACKDecoder(allocator: ByteBufferAllocator(), maxDynamicTableSize: 256)
        XCTAssertEqual(decoder.dynamicTableLength, 0)

        let decoded1 = try decoder.decodeHeaders(from: &response1)
        XCTAssertEqual(decoded1, headers1)
        XCTAssertEqual(decoder.dynamicTableLength, 222)
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers1[2], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers1[1], try decoder.headerTable.header(at: 64))
        XCTAssertEqualTuple(headers1[0], try decoder.headerTable.header(at: 65))

        let decoded2 = try decoder.decodeHeaders(from: &response2)
        XCTAssertEqual(decoded2, headers2)
        XCTAssertEqual(decoder.dynamicTableLength, 222)
        XCTAssertEqualTuple(headers2[0], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers1[2], try decoder.headerTable.header(at: 64))
        XCTAssertEqualTuple(headers1[1], try decoder.headerTable.header(at: 65))

        let decoded3 = try decoder.decodeHeaders(from: &response3)
        XCTAssertEqual(decoded3, headers3)
        XCTAssertEqual(decoder.dynamicTableLength, 215)
        XCTAssertEqualTuple(headers3[5], try decoder.headerTable.header(at: 62))
        XCTAssertEqualTuple(headers3[4], try decoder.headerTable.header(at: 63))
        XCTAssertEqualTuple(headers3[2], try decoder.headerTable.header(at: 64))
    }

    func testNonIndexedRequest() throws {
        var request1 = buffer(wrapping: [
            0x82, 0x86, 0x84, 0x01, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
        ])
        var request2 = buffer(wrapping: [
            0x82, 0x86, 0x84, 0x01, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff, 0x0f,
            0x09, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf, 0x00, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f,
            0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf,
        ])
        var request3 = buffer(wrapping: [
            0x82, 0x87, 0x85, 0x11, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff, 0x10,
            0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4,
            0xbf,
        ])

        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
        ])
        let h1NoIndex = (name: ":authority", value: "www.example.com")
        let h2NoIndex = (name: "cache-control", value: "no-cache")

        let headers3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html"),
        ])
        let h3NeverIndex = (name: "custom-key", value: "custom-value")

        var encoder = HPACKEncoder(allocator: allocator)

        try encoder.beginEncoding(allocator: allocator)
        XCTAssertNoThrow(try encoder.append(headers: headers1))
        try encoder.appendNonIndexed(header: h1NoIndex.name, value: h1NoIndex.value)
        XCTAssertEqual(try encoder.endEncoding(), request1)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 0)

        try encoder.beginEncoding(allocator: allocator)
        XCTAssertNoThrow(try encoder.append(headers: headers1))
        try encoder.appendNonIndexed(header: h1NoIndex.name, value: h1NoIndex.value)
        try encoder.appendNonIndexed(header: h2NoIndex.name, value: h2NoIndex.value)
        try encoder.appendNonIndexed(header: h3NeverIndex.name, value: h3NeverIndex.value)
        XCTAssertEqual(try encoder.endEncoding(), request2)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 0)

        try encoder.beginEncoding(allocator: allocator)
        XCTAssertNoThrow(try encoder.append(headers: headers3))
        try encoder.appendNeverIndexed(header: h1NoIndex.name, value: h1NoIndex.value)
        try encoder.appendNeverIndexed(header: h3NeverIndex.name, value: h3NeverIndex.value)
        XCTAssertEqual(try encoder.endEncoding(), request3)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 0)

        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        XCTAssertEqual(decoder.dynamicTableLength, 0)

        let fullHeaders1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
        ])
        let fullHeaders2 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache"),
            ("custom-key", "custom-value"),
        ])
        let fullHeaders3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html"),
            (":authority", "www.example.com"),
            ("custom-key", "custom-value"),
        ])

        let decoded1 = try decoder.decodeHeaders(from: &request1)
        XCTAssertEqual(decoded1, fullHeaders1)
        XCTAssertEqual(decoder.dynamicTableLength, 0)

        let decoded2 = try decoder.decodeHeaders(from: &request2)
        XCTAssertEqual(decoded2, fullHeaders2)
        XCTAssertEqual(decoder.dynamicTableLength, 0)

        let decoded3 = try decoder.decodeHeaders(from: &request3)
        XCTAssertEqual(decoded3, fullHeaders3)
        XCTAssertEqual(decoder.dynamicTableLength, 0)
    }

    func testInlineDynamicTableResize() throws {
        var request1 = buffer(wrapping: [
            0x3f, 0x32, 0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4,
            0xff,
        ])
        let request2 = buffer(wrapping: [
            0x3f, 0x21, 0x3f, 0x32, 0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab,
            0x90, 0xf4, 0xff,
        ])
        var request3 = buffer(wrapping: [
            0x3f, 0xe1, 0x20, 0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90,
            0xf4, 0xff,
        ])
        var request4 = buffer(wrapping: [
            0x82, 0x86, 0x3f, 0x32, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4,
            0xff,
        ])

        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
        ])

        let oddMaxTableSize = 81

        var encoder = HPACKEncoder(allocator: allocator)
        XCTAssertNotEqual(encoder.allowedDynamicTableSize, oddMaxTableSize)

        // adding these all manually to ensure our table size insert happens
        try encoder.setDynamicTableSize(oddMaxTableSize)
        try encoder.beginEncoding(allocator: allocator)
        XCTAssertNoThrow(try encoder.append(header: ":method", value: "GET"))
        XCTAssertNoThrow(try encoder.append(header: ":scheme", value: "http"))
        XCTAssertNoThrow(try encoder.append(header: ":path", value: "/"))
        XCTAssertNoThrow(try encoder.append(header: ":authority", value: "www.example.com"))

        XCTAssertEqual(try encoder.endEncoding(), request1)
        XCTAssertEqual(encoder.dynamicTableSize, 57)
        XCTAssertEqual(encoder.allowedDynamicTableSize, oddMaxTableSize)
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 62))

        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        // not enough to store the value we expect it to eventually store, but enough for the initial run
        decoder.maxDynamicTableLength = oddMaxTableSize
        let decoded: HPACKHeaders
        do {
            decoded = try decoder.decodeHeaders(from: &request1)
        } catch {
            XCTFail("Failed to decode header set containing dynamic-table-resize command: \(error)")
            return
        }

        XCTAssertEqual(decoded, headers1)
        XCTAssertEqual(decoder.maxDynamicTableLength, oddMaxTableSize)
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 62))

        // Now, ensure some special cases.
        request1.moveReaderIndex(to: 0)  // make the data available again in our sample buffer

        // 1 - if we try to change the size mid-buffer, it'll throw an error.
        try encoder.setDynamicTableSize(4096)
        // consume the table size change
        try encoder.beginEncoding(allocator: ByteBufferAllocator())
        _ = try encoder.endEncoding()
        encoder.headerIndexTable.dynamicTable.clear()

        try encoder.beginEncoding(allocator: allocator)
        XCTAssertNoThrow(try encoder.append(header: ":method", value: "GET"))
        XCTAssertNoThrow(try encoder.append(header: ":scheme", value: "http"))
        XCTAssertNoThrow(try encoder.append(header: ":path", value: "/"))
        XCTAssertThrowsError(try encoder.setDynamicTableSize(oddMaxTableSize))  // should throw
        XCTAssertNoThrow(try encoder.append(header: ":authority", value: "www.example.com"))

        // No resize information, but the rest of the block will be there
        XCTAssertEqual(try encoder.endEncoding(), request1.getSlice(at: 2, length: request1.readableBytes - 2))

        try encoder.setDynamicTableSize(4096)
        // consume the table size change
        try encoder.beginEncoding(allocator: ByteBufferAllocator())
        _ = try encoder.endEncoding()
        encoder.headerIndexTable.dynamicTable.clear()

        // 2 - We can set multiple sizes, and both the smallest and the latest will be sent.
        try encoder.setDynamicTableSize(64)
        try encoder.setDynamicTableSize(75)
        try encoder.setDynamicTableSize(oddMaxTableSize)  // 81

        try encoder.beginEncoding(allocator: allocator)
        XCTAssertNoThrow(try encoder.append(header: ":method", value: "GET"))
        XCTAssertNoThrow(try encoder.append(header: ":scheme", value: "http"))
        XCTAssertNoThrow(try encoder.append(header: ":path", value: "/"))
        XCTAssertNoThrow(try encoder.append(header: ":authority", value: "www.example.com"))

        XCTAssertEqual(try encoder.endEncoding(), request2)

        // 3 - Encoder will throw if the requested size exceeds the maximum value.
        // NB: current size is 81 bytes.
        encoder.headerIndexTable.dynamicTable.clear()

        XCTAssertThrowsError(try decoder.decodeHeaders(from: &request3)) { error in
            XCTAssertTrue(error is NIOHPACKErrors.InvalidDynamicTableSize)
        }

        // 4 - Decoder will not accept a table size update unless it appears at the start of a header block.
        decoder.headerTable.dynamicTable.clear()

        XCTAssertThrowsError(try decoder.decodeHeaders(from: &request4)) { error in
            XCTAssertTrue(error is NIOHPACKErrors.IllegalDynamicTableSizeChange)
        }
    }

    func testHPACKHeadersDescription() throws {
        let headerList1: [(String, String)] = [
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
        ]
        let headerList2: [(String, String)] = [
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache"),
        ]
        let headerList3: [(HPACKIndexing, String, String)] = [
            (.indexable, ":method", "POST"),
            (.indexable, ":scheme", "https"),
            (.indexable, ":path", "/send.html"),
            (.indexable, ":authority", "www.example.com"),
            (.indexable, "custom-key", "custom-value"),
            (.nonIndexable, "content-length", "42"),
        ]

        let headers1 = HPACKHeaders(headerList1)
        let headers2 = HPACKHeaders(headerList2)
        let headers3 = HPACKHeaders(fullHeaders: headerList3)

        let description1 = headers1.description
        let expected1 = headerList1.map { (HPACKIndexing.indexable, $0.0, $0.1) }.description
        XCTAssertEqual(description1, expected1)

        let description2 = headers2.description
        let expected2 = headerList2.map { (HPACKIndexing.indexable, $0.0, $0.1) }.description
        XCTAssertEqual(description2, expected2)

        let description3 = headers3.description
        let expected3 = headerList3.description  // already contains indexing where we'd expect
        XCTAssertEqual(description3, expected3)
    }

    func testHPACKHeadersSubscript() throws {
        let headers = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache"),
            ("custom-key", "value-1,value-2"),
            ("set-cookie", "abcdefg,hijklmn,opqrst"),
            ("custom-key", "value-3"),
        ])

        XCTAssertEqual(headers[":method"], ["GET"])
        XCTAssertEqual(headers[":authority"], ["www.example.com"])
        XCTAssertTrue(headers.contains(name: "cache-control"))
        XCTAssertTrue(headers.contains(name: "Cache-Control"))
        XCTAssertFalse(headers.contains(name: "content-length"))

        XCTAssertEqual(headers["custom-key"], ["value-1,value-2", "value-3"])
        XCTAssertEqual(headers[canonicalForm: "custom-key"], ["value-1", "value-2", "value-3"])

        XCTAssertEqual(headers["set-cookie"], ["abcdefg,hijklmn,opqrst"])
        XCTAssertEqual(headers[canonicalForm: "set-cookie"], ["abcdefg,hijklmn,opqrst"])
    }

    func testHPACKHeadersCanonicalFormStripsWhitespace() throws {
        let headers: HPACKHeaders = [
            "no-whitespace": "foo,bar",
            "sp": " foo ,  bar  ",
            "htab": "\tfoo\t,\t\tbar\t\t",
            "sp-and-htab": " \t foo  \t\t,\t bar\t ",
        ]

        let expected = ["foo", "bar"]
        XCTAssertEqual(headers[canonicalForm: "no-whitespace"], expected)
        XCTAssertEqual(headers[canonicalForm: "sp"], expected)
        XCTAssertEqual(headers[canonicalForm: "htab"], expected)
        XCTAssertEqual(headers[canonicalForm: "sp-and-htab"], expected)
    }

    func testHPACKHeadersCanonicalFormDropsEmptyStrings() throws {
        let headers: HPACKHeaders = [
            "no-whitespace": "foo,,bar",
            "with-whitespace": "foo, ,bar",
        ]
        let expected = ["foo", "bar"]
        XCTAssertEqual(headers[canonicalForm: "no-whitespace"], expected)
        XCTAssertEqual(headers[canonicalForm: "with-whitespace"], expected)
    }

    func testHPACKHeadersCanonicalFormSetCookie() throws {
        let shouldNotBeSplitOrStripped = "should, not , be , split, or, stripped"
        let headers: HPACKHeaders = ["set-cookie": shouldNotBeSplitOrStripped]

        XCTAssertEqual(headers[canonicalForm: "set-cookie"], [shouldNotBeSplitOrStripped])
        XCTAssertEqual(headers[canonicalForm: "Set-Cookie"], [shouldNotBeSplitOrStripped])
    }

    func testHPACKHeadersFirst() throws {
        let headers = HPACKHeaders([
            (":method", "GET"),
            ("foo", "bar"),
            ("foo", "baz"),
            ("custom-key", "value-1,value-2"),
        ])

        XCTAssertEqual(headers.first(name: ":method"), "GET")
        XCTAssertEqual(headers.first(name: "Foo"), "bar")
        XCTAssertEqual(headers.first(name: "custom-key"), "value-1,value-2")
        XCTAssertNil(headers.first(name: "not-present"))
    }

    func testHPACKHeadersExpressedByDictionaryLiteral() throws {
        let headers: HPACKHeaders = [
            ":method": "GET",
            ":scheme": "http",
            ":path": "/",
            ":authority": "www.example.com",
            "cache-control": "no-cache",
            "custom-key": "value-1,value-2",
            "set-cookie": "abcdefg,hijklmn,opqrst",
            "custom-key": "value-3",
        ]

        let headers2 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache"),
            ("custom-key", "value-1,value-2"),
            ("set-cookie", "abcdefg,hijklmn,opqrst"),
            ("custom-key", "value-3"),
        ])

        XCTAssertEqual(headers, headers2)
    }

    func testHPACKHeadersAddingSequenceOfPairs() {
        var headers = HPACKHeaders()
        headers.add(contentsOf: [("foo", "bar"), ("bar", "qux")])

        XCTAssertEqual(["bar"], headers["foo"])
        XCTAssertEqual(["qux"], headers["bar"])
    }

    func testHPACKHeadersAddingOtherHPACKHeaders() {
        var headers1 = HPACKHeaders([("foo", "bar"), ("bar", "qux")])
        let headers2 = HPACKHeaders([("bar", "baz"), ("baz", "bazzy")])
        headers1.add(contentsOf: headers2)

        XCTAssertEqual(["bar"], headers1["foo"])
        XCTAssertEqual(["qux", "baz"], headers1["bar"])
        XCTAssertEqual(["bazzy"], headers1["baz"])
    }

    func testHPACKHeadersRemove() {
        var headers = HPACKHeaders()
        headers.add(name: "foo", value: "bar")
        headers.add(name: "foo", value: "baz")
        XCTAssertEqual(headers.count, 2)

        headers.remove(name: "foo")
        XCTAssertEqual(headers.count, 0)
        XCTAssertTrue(headers.isEmpty)
    }

    func testHPACKHeadersReplaceOrAdd() {
        var headers = HPACKHeaders()

        headers.replaceOrAdd(name: "foo", value: "bar")
        XCTAssertEqual(headers["foo"], ["bar"])
        XCTAssertEqual(headers.count, 1)

        headers.replaceOrAdd(name: "foo", value: "baz")
        XCTAssertEqual(headers["foo"], ["baz"])
        XCTAssertEqual(headers.count, 1)
    }

    func testHPACKHeadersReserveCapacity() {
        var headers = HPACKHeaders()
        XCTAssertEqual(headers.capacity, 0)

        headers.reserveCapacity(5)
        XCTAssertGreaterThanOrEqual(headers.capacity, 5)
    }

    func testHPACKHeadersWithZeroIndex() throws {
        var request = buffer(wrapping: [0x80])
        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())

        XCTAssertThrowsError(try decoder.decodeHeaders(from: &request)) { error in
            XCTAssertEqual(error as? NIOHPACKErrors.ZeroHeaderIndex, NIOHPACKErrors.ZeroHeaderIndex())
        }
    }

    func testHPACKDecoderRespectsMaxHeaderListSize() throws {
        // We're just going to spam out a hilariously large header block by spamming lots of ":method: GET" headers. Each of these
        // consumes 42 bytes of the max header list size, so if we repeat it 1000 times we'll create an 42kB header field block while consuming only
        // 1kB. This should be rejected by the decoder.
        var request = buffer(wrapping: repeatElement(0x82, count: 1000))
        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        XCTAssertEqual(decoder.maxHeaderListSize, 16 * 1024)

        XCTAssertThrowsError(try decoder.decodeHeaders(from: &request)) { error in
            XCTAssertEqual(
                error as? NIOHPACKErrors.MaxHeaderListSizeViolation,
                NIOHPACKErrors.MaxHeaderListSizeViolation()
            )
        }

        // Decoding a header block that is smaller than the max header list size is fine.
        decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        decoder.maxHeaderListSize = 42 * 1000
        let decoded = try decoder.decodeHeaders(from: &request)
        XCTAssertEqual(decoded, HPACKHeaders(Array(repeatElement((":method", "GET"), count: 1000))))
    }

    func testDifferentlyCasedHPACKHeadersAreNotEqual() {
        let variants: [HPACKHeaders] = [
            HPACKHeaders([("foo", "foox")]), HPACKHeaders([("Foo", "foo")]),
            HPACKHeaders([("foo", "Foo")]), HPACKHeaders([("Foo", "Foo")]),
        ]

        for v1 in variants.indices {
            for v2 in variants.indices {
                guard v1 != v2 else {
                    continue
                }
                XCTAssertNotEqual(variants[v1], variants[v2], "indices \(v1) and \(v2)")
            }
        }
    }

    func testHPACKHeadersDontSearchForFullMatchesForNonIndexedHeaders() {
        var encoder = HPACKEncoder(allocator: .init())
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)

        // We're going to begin by encoding a small header block containing just a Date header.
        // This will be placed into the header table, and will use an indexed name but a literal value.
        let firstHeaders = HPACKHeaders([("date", "Tue, 12 Nov 2019 09:48:43 GMT")])
        XCTAssertNoThrow(try encoder.encode(headers: firstHeaders, to: &buffer))
        XCTAssertEqual(
            Array(buffer.readableBytesView),
            [
                0x61, 0x96, 0xdf, 0x69, 0x7e, 0x94, 0x08, 0x94, 0xd2, 0x7e, 0xea, 0x08, 0x01, 0x7d, 0x40, 0x3f, 0x71,
                0xa7, 0xae, 0x34, 0xca, 0x98, 0xb4, 0x6f,
            ]
        )

        // Now we're going to try to send that header again. This should be indexed fully, and sent trivially.
        buffer.clear()
        XCTAssertNoThrow(try encoder.encode(headers: firstHeaders, to: &buffer))
        XCTAssertEqual(Array(buffer.readableBytesView), [0xBE])

        // Now we're going to try once more, but this time ask for the Date header to be non-indexed. This should
        // give us the same results as the first time, but with a very slightly different first byte. Note that it
        // will not get the entry from the dynamic table, but will prefer the name from the static table instead.
        var secondHeaders = HPACKHeaders()
        secondHeaders.add(name: "date", value: "Tue, 12 Nov 2019 09:48:43 GMT", indexing: .nonIndexable)
        buffer.clear()
        XCTAssertNoThrow(try encoder.encode(headers: secondHeaders, to: &buffer))
        XCTAssertEqual(
            Array(buffer.readableBytesView),
            [
                0x0F, 0x12, 0x96, 0xdf, 0x69, 0x7e, 0x94, 0x08, 0x94, 0xd2, 0x7e, 0xea, 0x08, 0x01, 0x7d, 0x40, 0x3f,
                0x71, 0xa7, 0xae, 0x34, 0xca, 0x98, 0xb4, 0x6f,
            ]
        )
    }
}
