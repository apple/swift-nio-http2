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

final class HPACKHeaderEncodingBenchmark {
    private let headers: HPACKHeaders
    private let loopCount: Int
    private var encoder: HPACKEncoder
    private var buffer: ByteBuffer

    init(headers: HPACKHeaders, loopCount: Int) {
        self.headers = headers
        self.loopCount = loopCount
        self.encoder = HPACKEncoder(allocator: ByteBufferAllocator())
        self.buffer = ByteBufferAllocator().buffer(capacity: 1024)
    }
}

extension HPACKHeaderEncodingBenchmark: Benchmark {
    func setUp() throws {}

    func tearDown() {}

    func run() throws -> Int {
        for _ in 0..<self.loopCount {
            try self.encoder.encode(headers: headers, to: &self.buffer)
            self.buffer.clear()
        }

        return self.loopCount
    }
}

extension HPACKHeaders {
    static let indexable: HPACKHeaders = {
        var headers = HPACKHeaders()
        headers.add(
            contentsOf: [
                (":method", "GET"), (":path", "/"), (":scheme", "https"), (":authority", "localhost"), ("foo", "bar"),
            ],
            indexing: .indexable
        )
        return headers
    }()

    static let nonIndexable: HPACKHeaders = {
        var headers = HPACKHeaders()
        headers.add(
            contentsOf: [
                (":method", "GET"), (":path", "/"), (":scheme", "https"), (":authority", "localhost"), ("foo", "bar"),
            ],
            indexing: .nonIndexable
        )
        return headers
    }()

    static let neverIndexed: HPACKHeaders = {
        var headers = HPACKHeaders()
        headers.add(
            contentsOf: [
                (":method", "GET"), (":path", "/"), (":scheme", "https"), (":authority", "localhost"), ("foo", "bar"),
            ],
            indexing: .neverIndexed
        )
        return headers
    }()
}
