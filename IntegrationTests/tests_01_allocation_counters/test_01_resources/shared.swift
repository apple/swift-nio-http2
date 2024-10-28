//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOHTTP2

/// Test use only. Allows abstracting over the two multiplexer implementations to write common testing code
internal protocol MultiplexerChannelCreator {
    func createStreamChannel(
        promise: EventLoopPromise<Channel>?,
        _ streamStateInitializer: @escaping NIOHTTP2Handler.StreamInitializer
    )
    func createStreamChannel(_ initializer: @escaping NIOChannelInitializer) -> EventLoopFuture<Channel>
}

extension HTTP2StreamMultiplexer: MultiplexerChannelCreator {}
extension NIOHTTP2Handler.StreamMultiplexer: MultiplexerChannelCreator {}

/// Have two `EmbeddedChannel` objects send and receive data from each other until
/// they make no forward progress.
func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel) throws {
    precondition(
        first.eventLoop === second.eventLoop,
        "interactInMemory assumes both channels are on the same event loop."
    )
    var operated: Bool

    func readBytesFromChannel(_ channel: EmbeddedChannel) throws -> ByteBuffer? {
        try channel.readOutbound(as: ByteBuffer.self)
    }

    repeat {
        operated = false
        first.embeddedEventLoop.run()

        if let data = try readBytesFromChannel(first) {
            operated = true
            try second.writeInbound(data)
        }
        if let data = try readBytesFromChannel(second) {
            operated = true
            try first.writeInbound(data)
        }
    } while operated
}
