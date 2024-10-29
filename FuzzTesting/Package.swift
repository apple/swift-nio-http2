// swift-tools-version:5.3
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

import PackageDescription

let package = Package(
    name: "FuzzTesting",
    dependencies: [
        .package(name: "swift-nio-http2", path: ".."),
        .package(url: "https://github.com/apple/swift-nio", from: "2.29.0"),
    ],
    targets: [
        .target(
            name: "FuzzHTTP2",
            dependencies: [
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        )
    ]
)
