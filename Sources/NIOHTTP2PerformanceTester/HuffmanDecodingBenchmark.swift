//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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
import NIOHPACK

/// This benchmark is mostly attempting to stress the Huffman Decoding implementation by
/// way of using larger or more complex strings.
final class HuffmanDecodingBenchmark {
    private let loopCount: Int
    private let testType: TestType
    private var decoder: HPACKDecoder
    private var buffer: ByteBuffer

    init(huffmanBytes: TestType, loopCount: Int) {
        self.loopCount = loopCount
        self.decoder = HPACKDecoder(
            allocator: .init(),
            maxDynamicTableSize: HPACKDecoder.maxDynamicTableSize,
            maxHeaderListSize: .max
        )
        self.buffer = ByteBufferAllocator().buffer(capacity: 1024)
        self.testType = huffmanBytes
    }

    enum TestType {
        case basicHuffmanBytes
        case complexHuffmanBytes

        var huffmanBytes: [UInt8] {
            switch self {
            case .basicHuffmanBytes:
                return .basicHuffmanBytes
            case .complexHuffmanBytes:
                return .complexHuffmanBytes
            }
        }
    }
}

extension HuffmanDecodingBenchmark: Benchmark {
    func setUp() throws {
        // We encode this header with both the name and value as a huffman string, never indexed.
        self.buffer.writeInteger(UInt8(0x10))  // Never indexed, non-indexed name
        self.buffer.encodeInteger(1, prefix: 7, prefixBits: 0x80)  // Name length, huffman encoded, 7-bit integer
        self.buffer.writeInteger(UInt8(0x97))  // Huffman encoded "f"
        // Value length, huffman encoded, 7-bit integer
        self.buffer.encodeInteger(UInt(self.testType.huffmanBytes.count), prefix: 7, prefixBits: 0x80)
        self.buffer.writeBytes(self.testType.huffmanBytes)

        // Run a single iteration of the loop. This warms up the encoder and decoder and ensures all the pages are mapped.
        try self.loopIteration()
    }

    func tearDown() {}

    func run() throws -> Int {
        for _ in 0..<self.loopCount {
            try self.loopIteration()
        }

        return self.loopCount
    }

    private func loopIteration() throws {
        _ = try self.decoder.decodeHeaders(from: &self.buffer)
        self.buffer.moveReaderIndex(to: 0)
    }
}

extension Array where Element == UInt8 {
    static let basicHuffmanBytes: [UInt8] = {
        // This is hilariously slow (TWO intermediate Data objects!) but it's only invoked in setup so who cares?
        let url = fixtureDirectoryURL.appendingPathComponent("large_huffman_b64.txt")
        let base64Data = try! Data(contentsOf: url)
        let data = Data(base64Encoded: base64Data)!
        return Array(data)
    }()

    static let complexHuffmanBytes: [UInt8] = {
        let url = fixtureDirectoryURL.appendingPathComponent("large_complex_huffman_b64.txt")
        let base64Data = try! Data(contentsOf: url)
        let data = Data(base64Encoded: base64Data)!
        return Array(data)
    }()

    // The location of the test fixtures.
    private static let fixtureDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests").appendingPathComponent(
            "NIOHPACKTests"
        ).appendingPathComponent("Fixtures").absoluteURL
}

extension ByteBuffer {
    // Copied directly from our internal implementation.
    fileprivate mutating func encodeInteger(_ value: UInt, prefix: Int, prefixBits: UInt8 = 0) {
        assert(prefix <= 8)
        assert(prefix >= 1)

        let k = (1 << prefix) - 1
        var initialByte = prefixBits

        if value < k {
            // it fits already!
            initialByte |= UInt8(truncatingIfNeeded: value)
            self.writeInteger(initialByte)
            return
        }

        // if it won't fit in this byte altogether, fill in all the remaining bits and move
        // to the next byte.
        initialByte |= UInt8(truncatingIfNeeded: k)
        self.writeInteger(initialByte)

        // deduct the initial [prefix] bits from the value, then encode it seven bits at a time into
        // the remaining bytes.
        var n = value - UInt(k)
        while n >= 128 {
            let nextByte = (1 << 7) | UInt8(n & 0x7f)
            self.writeInteger(nextByte)
            n >>= 7
        }

        self.writeInteger(UInt8(n))
    }
}
