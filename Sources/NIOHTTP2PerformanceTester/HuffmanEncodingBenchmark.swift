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

import NIOCore
import NIOHPACK

/// This benchmark is mostly attempting to stress the Huffman Encoding implementation by
/// way of using larger or more complex strings.
final class HuffmanEncodingBenchmark {
    private var headers: HPACKHeaders
    private let loopCount: Int
    private var encoder: HPACKEncoder
    private var buffer: ByteBuffer

    init(huffmanString: String, loopCount: Int) {
        self.headers = HPACKHeaders()
        self.headers.add(name: "f", value: huffmanString, indexing: .neverIndexed)

        self.loopCount = loopCount
        self.encoder = HPACKEncoder(allocator: .init())
        self.buffer = ByteBufferAllocator().buffer(capacity: 1024)
    }
}

extension HuffmanEncodingBenchmark: Benchmark {
    func setUp() throws {
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
        try self.encoder.encode(headers: self.headers, to: &self.buffer)
        self.buffer.clear()
    }
}

extension String {
    static let basicHuffman: String = {
        var text =
            "Hello, world. I am a header value; I have Teh Texts. I am going on for quite a long time because I want to ensure that the encoded data buffer needs to be expanded to test out that code. I'll try some meta-characters too: \r\t\n ought to do it, no?"
        while text.count < 1024 * 128 {
            text += text
        }
        return text
    }()

    static let complexHuffman: String = {
        var text = "午セイ谷高ぐふあト食71入ツエヘナ津県を類及オモ曜一購ごきわ致掲ぎぐず敗文輪へけり鯖審ヘ塊米卸呪おぴ。"
        while text.utf8.count < 128 * 1024 {
            text += text
        }
        return text
    }()
}
