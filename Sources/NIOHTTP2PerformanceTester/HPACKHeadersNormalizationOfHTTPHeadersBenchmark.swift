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
import NIOCore
import NIOHPACK
import NIOHTTP1

final class HPACKHeadersNormalizationOfHTTPHeadersBenchmark {
    private let httpHeadersKind: HeadersKind
    private var httpHeaders: HTTPHeaders!
    private let iterations: Int

    enum HeadersKind {
        case manyUniqueConnectionHeaderValues(Int)
        case manyConnectionHeaderValuesWhichAreNotRemoved(Int)
    }

    init(headersKind: HeadersKind, iterations: Int) {
        self.httpHeadersKind = headersKind
        self.iterations = iterations
    }
}

extension HPACKHeadersNormalizationOfHTTPHeadersBenchmark: Benchmark {
    func setUp() throws {
        switch self.httpHeadersKind {
        case .manyUniqueConnectionHeaderValues(let count):
            self.httpHeaders = .manyUniqueConnectionHeaderValues(count)
        case .manyConnectionHeaderValuesWhichAreNotRemoved(let count):
            self.httpHeaders = .manyConnectionHeaderValuesWhichAreNotRemoved(count)
        }
    }

    func tearDown() {}

    func run() throws -> Int {
        var count = 0

        for _ in 0..<self.iterations {
            let normalize = HPACKHeaders(httpHeaders: self.httpHeaders, normalizeHTTPHeaders: true)
            count &+= normalize.count
        }

        return count
    }
}

extension HTTPHeaders {
    static func manyUniqueConnectionHeaderValues(_ count: Int) -> HTTPHeaders {
        var httpHeaders: HTTPHeaders = [:]
        httpHeaders.reserveCapacity(count + 1)

        let connectionHeaderValue = (0..<count).map(String.init).joined(separator: ",")
        httpHeaders.add(name: "connection", value: connectionHeaderValue)

        for i in 0..<count {
            let header = String(describing: i)
            httpHeaders.add(name: header, value: header)
        }

        return httpHeaders
    }

    static func manyConnectionHeaderValuesWhichAreNotRemoved(_ count: Int) -> HTTPHeaders {
        var httpHeaders: HTTPHeaders = [:]
        httpHeaders.reserveCapacity(count + 1)

        // Assuming connection header values are decomposed into an array then this is the
        // worst case: the whole array must be scanned for each of the `count` headers we add below.
        let connectionHeaderValue = (0..<count).map { _ in "a" }.joined(separator: ",")
        httpHeaders.add(name: "connection", value: connectionHeaderValue)

        for _ in 0..<count {
            httpHeaders.add(name: "b", value: "")
        }

        return httpHeaders
    }
}
