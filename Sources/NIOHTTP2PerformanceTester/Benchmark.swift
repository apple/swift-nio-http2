//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

protocol Benchmark: class {
    init()
    func setUp() throws
    func tearDown()
    func run() throws -> Int
}

func measureAndPrint<B: Benchmark>(desc: String, benchmark: B.Type) throws {
    let bench = B()
    try bench.setUp()
    defer {
        bench.tearDown()
    }
    try measureAndPrint(desc: desc) {
        return try bench.run()
    }
}
