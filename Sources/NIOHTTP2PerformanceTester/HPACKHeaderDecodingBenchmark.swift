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

final class HPACKHeaderDecodingBenchmark {
    private var headers: ByteBuffer
    private let loopCount: Int
    private var decoder: HPACKDecoder

    init(headers: HPACKHeaders, loopCount: Int) {
        self.headers = headers.encoded
        self.loopCount = loopCount
        self.decoder = HPACKDecoder(allocator: .init())
    }
}

extension HPACKHeaderDecodingBenchmark: Benchmark {
    func setUp() throws {}

    func tearDown() {}

    func run() throws -> Int {
        for _ in 0..<self.loopCount {
            _ = try self.decoder.decodeHeaders(from: &self.headers)
            self.headers.moveReaderIndex(to: 0)
        }

        return self.loopCount
    }
}

extension HPACKHeaders {
    fileprivate var encoded: ByteBuffer {
        var encoder = HPACKEncoder(allocator: .init())
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        try! encoder.encode(headers: self, to: &buffer)
        return buffer
    }
}
