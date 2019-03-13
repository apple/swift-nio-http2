// swift-tools-version:5.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
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
    name: "swift-nio-http2",
    products: [
        .executable(name: "NIOHTTP2Server", targets: ["NIOHTTP2Server"]),
        .library(name: "NIOHTTP2", targets: ["NIOHTTP2"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0-convergence.1"),
    ],
    targets: [
        .target(name: "NIOHTTP2Server",
            dependencies: ["NIOHTTP2"]),
        .target(name: "NIOHTTP2",
            dependencies: ["NIO", "_NIO1APIShims", "NIOHTTP1", "NIOTLS", "NIOHPACK"]),
        .target(name: "NIOHPACK",
            dependencies: ["NIO", "_NIO1APIShims", "NIOConcurrencyHelpers", "NIOHTTP1"]),
        .testTarget(name: "NIOHTTP2Tests",
            dependencies: ["NIO", "_NIO1APIShims", "NIOHTTP1", "NIOHTTP2"]),
        .testTarget(name: "NIOHPACKTests",
            dependencies: ["NIOHPACK"])
    ]
)
