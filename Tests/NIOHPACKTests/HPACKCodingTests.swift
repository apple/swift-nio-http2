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

class HPACKCodingTests: XCTestCase {
    
    let allocator = ByteBufferAllocator()

    private func buffer<C : ContiguousCollection>(wrapping bytes: C) -> ByteBuffer where C.Element == UInt8 {
        var buffer = allocator.buffer(capacity: bytes.count)
        buffer.write(bytes: bytes)
        return buffer
    }
    
    // HPACK RFC7541 § C.3
    // http://httpwg.org/specs/rfc7541.html#request.examples.without.huffman.coding
    func testRequestHeadersWithoutHuffmanCoding() throws {
        var request1 = buffer(wrapping: [0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d])
        var request2 = buffer(wrapping: [0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 0x6e, 0x6f, 0x2d, 0x63, 0x61, 0x63, 0x68, 0x65])
        var request3 = buffer(wrapping: [0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b, 0x65, 0x79, 0x0c, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x76, 0x61, 0x6c, 0x75, 0x65])
        
        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com")
        ])
        let headers2 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache")
        ])
        let headers3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html"),
            (":authority", "www.example.com"),
            ("custom-key", "custom-value")
        ])
        
        var decoder = HPACKDecoder()
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
        var request1 = buffer(wrapping: [0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff])
        var request2 = buffer(wrapping: [0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf])
        var request3 = buffer(wrapping: [0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf])
        
        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com")
        ])
        let headers2 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache")
        ])
        let headers3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html"),
            (":authority", "www.example.com"),
            ("custom-key", "custom-value")
        ])
        
        var encoder = HPACKEncoder(allocator: allocator)
        try encoder.append(headers: headers1)
        XCTAssertEqual(encoder.encodedData, request1)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 57)
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 62))
        
        encoder.reset()
        try encoder.append(headers: headers2)
        XCTAssertEqual(encoder.encodedData, request2)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 110)
        XCTAssertEqualTuple(headers2[4], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 63))
        
        encoder.reset()
        try encoder.append(headers: headers3)
        XCTAssertEqual(encoder.encodedData, request3)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 164)
        XCTAssertEqualTuple(headers3[4], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers2[4], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 64))
        
        var decoder = HPACKDecoder()
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
            0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x31, 0x20, 0x47, 0x4d, 0x54,
            // location: https://www.example.com
            0x6e, 0x17, 0x68, 0x74, 0x74, 0x70, 0x73, 0x3a, 0x2f, 0x2f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d
        ])
        var response2 = buffer(wrapping: [
            // :status: 307
            0x48, 0x03, 0x33, 0x30, 0x37,
            // cache-control: private
            0xc1,
            // date: Mon, 21 Oct 2013 20:13:21 GMT
            0xc0,
            // location: https://www.example.com
            0xbf
        ])
        var response3 = buffer(wrapping: [
            // :status: 200
            0x88,
            // cache-control: private
            0xc1,
            // date: Mon, 21 Oct 2013 20:13:22 GMT
            0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x32, 0x20, 0x47, 0x4d, 0x54,
            // location: https://www.example.com
            0xc0,
            // content-encoding: gzip
            0x5a, 0x04, 0x67, 0x7a, 0x69, 0x70,
            // set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1
            0x77, 0x38, 0x66, 0x6f, 0x6f, 0x3d, 0x41, 0x53, 0x44, 0x4a, 0x4b, 0x48, 0x51, 0x4b, 0x42, 0x5a, 0x58, 0x4f, 0x51, 0x57, 0x45, 0x4f, 0x50, 0x49, 0x55, 0x41, 0x58, 0x51, 0x57, 0x45, 0x4f, 0x49, 0x55, 0x3b, 0x20, 0x6d, 0x61, 0x78, 0x2d, 0x61, 0x67, 0x65, 0x3d, 0x33, 0x36, 0x30, 0x30, 0x3b, 0x20, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x3d, 0x31
        ])
        
        let headers1 = HPACKHeaders([
            (":status", "302"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com")
        ])
        let headers2 = HPACKHeaders([
            (":status", "307"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com")
        ])
        let headers3 = HPACKHeaders([
            (":status", "200"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:22 GMT"),
            ("location", "https://www.example.com"),
            ("content-encoding", "gzip"),
            ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1")
        ])
        
        var decoder = HPACKDecoder(maxDynamicTableSize: 256)
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
            0x48, 0x82, 0x64, 0x02, 0x58, 0x85, 0xae, 0xc3, 0x77, 0x1a, 0x4b, 0x61, 0x96, 0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0, 0x82, 0xa6, 0x2d, 0x1b, 0xff, 0x6e, 0x91, 0x9d, 0x29, 0xad, 0x17, 0x18, 0x63, 0xc7, 0x8f, 0x0b, 0x97, 0xc8, 0xe9, 0xae, 0x82, 0xae, 0x43, 0xd3
        ])
        var response2 = buffer(wrapping: [
            0x48, 0x83, 0x64, 0x0e, 0xff, 0xc1, 0xc0, 0xbf
        ])
        var response3 = buffer(wrapping: [
            0x88, 0xc1, 0x61, 0x96, 0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0, 0x84, 0xa6, 0x2d, 0x1b, 0xff, 0xc0, 0x5a, 0x83, 0x9b, 0xd9, 0xab, 0x77, 0xad, 0x94, 0xe7, 0x82, 0x1d, 0xd7, 0xf2, 0xe6, 0xc7, 0xb3, 0x35, 0xdf, 0xdf, 0xcd, 0x5b, 0x39, 0x60, 0xd5, 0xaf, 0x27, 0x08, 0x7f, 0x36, 0x72, 0xc1, 0xab, 0x27, 0x0f, 0xb5, 0x29, 0x1f, 0x95, 0x87, 0x31, 0x60, 0x65, 0xc0, 0x03, 0xed, 0x4e, 0xe5, 0xb1, 0x06, 0x3d, 0x50, 0x07
        ])
        
        let headers1 = HPACKHeaders([
            (":status", "302"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com")
        ])
        let headers2 = HPACKHeaders([
            (":status", "307"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:21 GMT"),
            ("location", "https://www.example.com")
        ])
        let headers3 = HPACKHeaders([
            (":status", "200"),
            ("cache-control", "private"),
            ("date", "Mon, 21 Oct 2013 20:13:22 GMT"),
            ("location", "https://www.example.com"),
            ("content-encoding", "gzip"),
            ("set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1")
        ])
        
        var encoder = HPACKEncoder(allocator: allocator)
        try encoder.append(headers: headers1)
        XCTAssertEqual(encoder.encodedData, response1)
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers1[2], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers1[1], try encoder.headerIndexTable.header(at: 64))
        XCTAssertEqualTuple(headers1[0], try encoder.headerIndexTable.header(at: 65))
        
        encoder.reset()
        try encoder.append(headers: headers2)
        XCTAssertEqual(encoder.encodedData, response2)
        XCTAssertEqualTuple(headers2[0], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers1[2], try encoder.headerIndexTable.header(at: 64))
        XCTAssertEqualTuple(headers1[1], try encoder.headerIndexTable.header(at: 65))
        
        encoder.reset()
        try encoder.append(headers: headers3)
        XCTAssertEqual(encoder.encodedData, response3)
        XCTAssertEqualTuple(headers3[5], try encoder.headerIndexTable.header(at: 62))
        XCTAssertEqualTuple(headers3[4], try encoder.headerIndexTable.header(at: 63))
        XCTAssertEqualTuple(headers3[2], try encoder.headerIndexTable.header(at: 64))
        
        var decoder = HPACKDecoder(maxDynamicTableSize: 256)
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
        var request1 = buffer(wrapping: [0x82, 0x86, 0x84, 0x01, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff])
        var request2 = buffer(wrapping: [0x82, 0x86, 0x84, 0x01, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff, 0x0f, 0x09, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf, 0x00, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf])
        var request3 = buffer(wrapping: [0x82, 0x87, 0x85, 0x11, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff, 0x10, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf])
        
        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/")
        ])
        let h1NoIndex = (name: ":authority", value: "www.example.com")
        let h2NoIndex = (name: "cache-control", value: "no-cache")
        
        let headers3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html")
        ])
        let h3NeverIndex = (name: "custom-key", value: "custom-value")
        
        var encoder = HPACKEncoder(allocator: allocator)
        XCTAssertNoThrow(try encoder.append(headers: headers1))
        encoder.appendNonIndexed(header: h1NoIndex.name, value: h1NoIndex.value)
        XCTAssertEqual(encoder.encodedData, request1)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 0)
        
        encoder.reset()
        XCTAssertNoThrow(try encoder.append(headers: headers1))
        encoder.appendNonIndexed(header: h1NoIndex.name, value: h1NoIndex.value)
        encoder.appendNonIndexed(header: h2NoIndex.name, value: h2NoIndex.value)
        encoder.appendNonIndexed(header: h3NeverIndex.name, value: h3NeverIndex.value)
        XCTAssertEqual(encoder.encodedData, request2)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 0)
        
        encoder.reset()
        XCTAssertNoThrow(try encoder.append(headers: headers3))
        encoder.appendNeverIndexed(header: h1NoIndex.name, value: h1NoIndex.value)
        encoder.appendNeverIndexed(header: h3NeverIndex.name, value: h3NeverIndex.value)
        XCTAssertEqual(encoder.encodedData, request3)
        XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 0)
        
        var decoder = HPACKDecoder()
        XCTAssertEqual(decoder.dynamicTableLength, 0)
        
        let fullHeaders1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com")
        ])
        let fullHeaders2 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com"),
            ("cache-control", "no-cache"),
            ("custom-key", "custom-value")
        ])
        let fullHeaders3 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "https"),
            (":path", "/index.html"),
            (":authority", "www.example.com"),
            ("custom-key", "custom-value")
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
    
    func _testSomeOddCases() throws {
        let request1 = buffer(wrapping: [])
        
        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":authority", "rover.ebay.com"),
            (":path", "/roversync/"),
            ("user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:16.0) Gecko/20100101 Firefox/16.0"),
            ("accept", "image/png,image/*;q=0.8,*/*;q=0.5"),
            ("accept-language", "en-US,en;q=0.5"),
            ("accept-encoding", "gzip, deflate"),
            ("connection", "keep-alive"),
            ("referer", "http://www.ebay.com/"),
            ("cookie", "ebay=%5Esbf%3D%23%5E; dp1=bpbf/%238000000000005276504d^u1p/QEBfX0BAX19AQA**5276504d^; cssg=c67883f113a0a56964e646c6ffaa1abe; s=CgAD4ACBQlm5NYzY3ODgzZjExM2EwYTU2OTY0ZTY0NmM2ZmZhYTFhYmUBSgAYUJZuTTUwOTUxY2NkLjAuMS4zLjE1MS4zLjAuMeN+7JE*; nonsession=CgAFMABhSdlBNNTA5NTFjY2QuMC4xLjEuMTQ5LjMuMC4xAMoAIFn7Hk1jNjc4ODNmMTEzYTBhNTY5NjRlNjQ2YzZmZmFhMWFjMQDLAAFQlSPVMX8u5Z8*")
        ])
        
        var encoder = HPACKEncoder(allocator: allocator)
        try encoder.append(headers: headers1)
        var encoded = encoder.encodedData
        
        var decoder = HPACKDecoder(allocator: allocator)
        let decoded = try decoder.decodeHeaders(from: &encoded)
        XCTAssertEqual(headers1, decoded)
        //XCTAssertEqual(encoder.encodedData, request1)
        //XCTAssertEqual(encoder.headerIndexTable.dynamicTableLength, 57)
        //XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 62))
    }
    
    func testInlineDynamicTableResize() throws {
        var request1 = buffer(wrapping: [0x82, 0x86, 0x84, 0x3F, 0x32, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff])
        
        let headers1 = HPACKHeaders([
            (":method", "GET"),
            (":scheme", "http"),
            (":path", "/"),
            (":authority", "www.example.com")
        ])
        
        let oddMaxTableSize = 81
        
        var encoder = HPACKEncoder(allocator: allocator)
        XCTAssertNotEqual(encoder.maxDynamicTableSize, oddMaxTableSize)
        
        // adding these all manually to ensure our table size insert happens
        XCTAssertNoThrow(try encoder.append(header: ":method", value: "GET"))
        XCTAssertNoThrow(try encoder.append(header: ":scheme", value: "http"))
        XCTAssertNoThrow(try encoder.append(header: ":path", value: "/"))
        encoder.setMaxDynamicTableSize(oddMaxTableSize)
        XCTAssertNoThrow(try encoder.append(header: ":authority", value: "www.example.com"))
        
        XCTAssertEqual(encoder.encodedData, request1)
        XCTAssertEqual(encoder.dynamicTableSize, 57)
        XCTAssertEqual(encoder.maxDynamicTableSize, oddMaxTableSize)
        XCTAssertEqualTuple(headers1[3], try encoder.headerIndexTable.header(at: 62))
        
        var decoder = HPACKDecoder(maxDynamicTableSize: 22)     // not enough to store the value we expect it to eventually store
        let decoded: HPACKHeaders
        do {
            decoded = try decoder.decodeHeaders(from: &request1)
        }
        catch {
            XCTFail("Failed to decode header set containing dynamic-table-resize command: \(error)")
            return
        }
        
        XCTAssertEqual(decoded, headers1)
        XCTAssertEqual(decoder.maxDynamicTableLength, oddMaxTableSize)
        XCTAssertEqualTuple(headers1[3], try decoder.headerTable.header(at: 62))
    }
}
