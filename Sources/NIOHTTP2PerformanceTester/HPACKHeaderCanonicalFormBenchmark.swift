//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
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

final class HPACKHeaderCanonicalFormBenchmark {
    private let headers: HPACKHeaders

    init(_ test: Test) {
        switch test {
        case .noTrimming:
            self.headers = ["key": "no,trimming"]
        case .trimmingWhitespace:
            self.headers = ["key": "         some   ,   trimming     "]
        case .trimmingWhitespaceFromShortStrings:
            self.headers = ["key": "   smallString   ,whenStripped"]
        case .trimmingWhitespaceFromLongStrings:
            self.headers = ["key": " moreThan15CharactersWithAndWithoutWhitespace ,anotherValue"]
        }
    }

    enum Test {
        case noTrimming
        case trimmingWhitespace
        case trimmingWhitespaceFromShortStrings
        case trimmingWhitespaceFromLongStrings
    }
}

extension HPACKHeaderCanonicalFormBenchmark: Benchmark {
    func setUp() throws {}
    func tearDown() {}

    func run() throws -> Int {
        var count = 0
        for _ in 0..<100_000 {
            count &+= self.headers[canonicalForm: "key"].count
        }
        return count
    }
}
