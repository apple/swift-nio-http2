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
    private let httpHeaders: HTTPHeaders
    private let iterations: Int

    init(httpHeaders: HTTPHeaders, iterations: Int) {
        self.httpHeaders = httpHeaders
        self.iterations = iterations
    }
}


extension HPACKHeadersNormalizationOfHTTPHeadersBenchmark: Benchmark {
    func setUp() throws { }

    func tearDown() { }

    func run() throws -> Int {
        var count = 0

        for _ in 0 ..< self.iterations {
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

        let connectionHeaderValue = (0 ..< count).map(String.init).joined(separator: ",")
        httpHeaders.add(name: "connection", value: connectionHeaderValue)

        for i in 0 ..< count {
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
        let connectionHeaderValue = (0 ..< count).map { _ in "a" }.joined(separator: ",")
        httpHeaders.add(name: "connection", value: connectionHeaderValue)

        for _ in 0 ..< count {
            httpHeaders.add(name: "b", value: "")
        }

        return httpHeaders
    }
}
