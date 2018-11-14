// swift-tools-version:4.1
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
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-nio-nghttp2-support.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "CNIONghttp2"),
        .target(name: "NIOHTTP2Server",
            dependencies: ["NIOHTTP2"]),
        .target(name: "NIOHTTP2",
            dependencies: ["NIO", "NIOHTTP1", "NIOTLS", "CNIONghttp2"]),
        .target(name: "NIOHPACK",
            dependencies: ["NIO", "NIOConcurrencyHelpers", "NIOHTTP1"]),
        .testTarget(name: "NIOHTTP2Tests",
            dependencies: ["NIO", "NIOHTTP1", "NIOHTTP2"]),
        .testTarget(name: "NIOHPACKTests",
            dependencies: ["NIOHPACK"])
    ]
)
