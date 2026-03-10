// swift-tools-version:6.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "swift-nio-http2-benchmarks",
    platforms: [
        .macOS("14")
    ],
    dependencies: [
        .package(path: "../"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.95.0"),
        .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "NIOHPACKBenchmarks",
            dependencies: [
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Benchmark", package: "package-benchmark"),
            ],
            path: "Benchmarks/NIOHPACKBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        )
    ]
)
