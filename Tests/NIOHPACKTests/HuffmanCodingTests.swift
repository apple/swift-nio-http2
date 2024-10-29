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

import Foundation
import NIOCore
import NIOFoundationCompat
import XCTest

@testable import NIOHPACK

class HuffmanCodingTests: XCTestCase {
    var scratchBuffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 4096)

    // MARK: - Helper Methods

    func assertEqualContents(_ buffer: ByteBuffer, _ array: [UInt8], file: StaticString = #filePath, line: UInt = #line)
    {
        XCTAssertEqual(
            buffer.readableBytes,
            array.count,
            "Buffer and array are different sizes",
            file: (file),
            line: line
        )
        buffer.withUnsafeReadableBytes { bufPtr in
            array.withUnsafeBytes { arrayPtr in
                XCTAssertEqual(
                    memcmp(bufPtr.baseAddress!, arrayPtr.baseAddress!, arrayPtr.count),
                    0,
                    "Buffer contents don't match",
                    file: (file),
                    line: line
                )
            }
        }
    }

    func verifyHuffmanCoding(
        _ string: String,
        _ bytes: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        self.scratchBuffer.clear()

        let utf8 = string.utf8
        let numBytes = self.scratchBuffer.writeHuffmanEncoded(bytes: utf8)
        XCTAssertEqual(numBytes, bytes.count, "Wrong length encoding '\(string)'", file: (file), line: line)

        assertEqualContents(self.scratchBuffer, bytes, file: (file), line: line)

        let decoded = try scratchBuffer.getHuffmanEncodedString(
            at: self.scratchBuffer.readerIndex,
            length: self.scratchBuffer.readableBytes
        )
        XCTAssertEqual(decoded, string, "Failed to decode '\(string)'", file: (file), line: line)
    }

    func testBasicCoding() throws {
        // all these values come from http://httpwg.org/specs/rfc7541.html#request.examples.with.huffman.coding
        try verifyHuffmanCoding(
            "www.example.com",
            [0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
        )
        try verifyHuffmanCoding("no-cache", [0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf])
        try verifyHuffmanCoding("custom-key", [0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f])
        try verifyHuffmanCoding("custom-value", [0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf])

        // these come from http://httpwg.org/specs/rfc7541.html#response.examples.with.huffman.coding
        try verifyHuffmanCoding("302", [0x64, 0x02])
        try verifyHuffmanCoding("private", [0xae, 0xc3, 0x77, 0x1a, 0x4b])
        try verifyHuffmanCoding(
            "Mon, 21 Oct 2013 20:13:21 GMT",
            [
                0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0,
                0x82, 0xa6, 0x2d, 0x1b, 0xff,
            ]
        )
        try verifyHuffmanCoding(
            "https://www.example.com",
            [0x9d, 0x29, 0xad, 0x17, 0x18, 0x63, 0xc7, 0x8f, 0x0b, 0x97, 0xc8, 0xe9, 0xae, 0x82, 0xae, 0x43, 0xd3]
        )
        try verifyHuffmanCoding("307", [0x64, 0x0e, 0xff])
        try verifyHuffmanCoding(
            "Mon, 21 Oct 2013 20:13:22 GMT",
            [
                0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0,
                0x84, 0xa6, 0x2d, 0x1b, 0xff,
            ]
        )
        try verifyHuffmanCoding("gzip", [0x9b, 0xd9, 0xab])
        try verifyHuffmanCoding(
            "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
            [
                0x94, 0xe7, 0x82, 0x1d, 0xd7, 0xf2, 0xe6, 0xc7, 0xb3, 0x35, 0xdf, 0xdf, 0xcd, 0x5b, 0x39, 0x60, 0xd5,
                0xaf, 0x27, 0x08, 0x7f, 0x36, 0x72, 0xc1, 0xab, 0x27, 0x0f, 0xb5, 0x29, 0x1f, 0x95, 0x87, 0x31, 0x60,
                0x65, 0xc0, 0x03, 0xed, 0x4e, 0xe5, 0xb1, 0x06, 0x3d, 0x50, 0x07,
            ]
        )
    }

    func testComplexCoding() throws {
        try verifyHuffmanCoding(
            "鯖審",
            [0xff, 0xff, 0xaf, 0xff, 0xff, 0x67, 0xff, 0xfe, 0x2f, 0xff, 0xf3, 0xff, 0xff, 0xec, 0xff, 0xff, 0x77]
        )

        let text1 =
            "Hello, world. I am a header value; I have Teh Texts. I am going on for quite a long time because I want to ensure that the encoded data buffer needs to be expanded to test out that code. I'll try some meta-characters too: \r\t\n ought to do it, no?"
        guard
            let encoded1Data = Data(
                base64Encoded:
                    "xlooP9KeD2USLqZFB0qDUnKOQtincdFpftTIpOPuVTeWdTeXylC6mRQdKkxzVTKHqUlPYp2tMkqg1KD1TKJNSVSMpB2oKpkU8DqSok6hakW2FUTONKiZyqFqIeQsikg0jUjtllLYpUUsiFEnUjKoXzWOqQsiiTqJKhKh7UqJnGlQh5CrqZP9UUKJs9KIPSVSkqRrEnHYMiS2IUSc9xT////3//+r////xQ9s06VEnUkOoZP0pUf/Pw=="
            )
        else {
            XCTFail("Unable to import base-64 result data")
            return
        }

        // oh if only Data could conform to ContiguousCollection...
        try verifyHuffmanCoding(text1, Array(encoded1Data))

        // The encoder has a 256-byte encoding buffer to start with, and we want to overflow that to make it expand automatically
        // We also want to include some > 24-bit codes to test all the conditions.
        // So: here's a goodly-sized chunk of UTF-8 text. It won't compress worth a damn.
        let text2 = "午セイ谷高ぐふあト食71入ツエヘナ津県を類及オモ曜一購ごきわ致掲ぎぐず敗文輪へけり鯖審ヘ塊米卸呪おぴ。"
        guard
            let encoded2Data = Data(
                base64Encoded:
                    "//8///3v//W//83//P//8n//m//5///c//+r//wf//v//+v///D//8n//m//9L//+z//zf/+l//8P//m//9L//n//83//R//63//1//+3///e6H//z//+p//+j//zf/9H//p//+b//n///V//5v/+j//8n//m//6P//t//+j//9v//6P//5//+z//93//zf/8///r///X//3f//z//+f//7///2///N//z//+9//5v/+j//p//9H//5f//Z//+n//q//5v//q//8X//8P//N//6X//93//m//9L//73//m//5///v///V//9n//9v//o///r//+D//zf/+l///X//5v//S///s//83//pf/+x//6P//w///j//9H//4v//s///V///D//3v//N//6X//V//5v//S///t//83//P//9v//6///2f//i//8///7P//d//83//R//+T//z//93//7f//8///D//4v//P//97//q//8///9v//vf/+b//0v//t//+b//0v//2//+b//m//5/"
            )
        else {
            XCTFail("Unable to import base-64 result data")
            return
        }

        try verifyHuffmanCoding(text2, Array(encoded2Data))
    }
}
