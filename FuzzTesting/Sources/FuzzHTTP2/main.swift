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
// Sources/protoc-gen-swift/main.swift - Protoc plugin main
//
// Copyright (c) 2020 - 2021 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt

import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2

private func fuzzInput(_ bytes: UnsafeRawBufferPointer) throws {
    let channel = EmbeddedChannel()
    defer {
        _ = try? channel.finish()
    }
    _ = try channel.configureHTTP2Pipeline(
        mode: .server,
        initialLocalSettings: [HTTP2Setting(parameter: .maxConcurrentStreams, value: 1 << 23)],
        inboundStreamInitializer: nil
    ).wait()
    try channel.connect(to: SocketAddress(unixDomainSocketPath: "/foo")).wait()

    let buffer = channel.allocator.buffer(bytes: bytes)
    try channel.writeInbound(buffer)
    channel.embeddedEventLoop.run()
    channel.pipeline.fireChannelInactive()
    channel.embeddedEventLoop.run()
}

@_cdecl("LLVMFuzzerTestOneInput")
public func FuzzServer(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let bytes = UnsafeRawBufferPointer(start: start, count: count)
    do {
        let _ = try fuzzInput(bytes)
    } catch {
        // Errors parsing are to be expected since not all inputs will be well formed.
    }

    return 0
}
