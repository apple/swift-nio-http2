//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2023 Apple Inc. and the SwiftNIO project authors
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
import NIOHPACK
import NIOHTTP1
import NIOHTTP2


func run(identifier: String) {
    testRun(identifier: identifier) { channel in
        let http2Handler = NIOHTTP2Handler(mode: .client)
        let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: channel, inboundStreamInitializer: nil)
        try! channel.pipeline.addHandlers([
            http2Handler,
            multiplexer
        ]).wait()
        return multiplexer
    }

    //
    // MARK: - Inline HTTP2 multiplexer tests
    testRun(identifier: identifier + "_inline") { channel in
        let http2Handler = NIOHTTP2Handler(mode: .client, eventLoop: channel.eventLoop) { channel in
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        try! channel.pipeline.addHandler(http2Handler).wait()
        return try! http2Handler.multiplexer.wait()
    }
}

private func testRun(identifier: String, pipelineConfigurator: (Channel) throws -> MultiplexerChannelCreator) {
    let channel = EmbeddedChannel(handler: nil)
    let multiplexer = try! pipelineConfigurator(channel)
    try! channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()

    measure(identifier: identifier) {
        var streams = 0

        for _ in 0..<1000 {
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            multiplexer.createStreamChannel(promise: promise) { channel in
                return channel.eventLoop.makeSucceededFuture(())
            }
            channel.embeddedEventLoop.run()
            let child = try! promise.futureResult.wait()
            streams += 1

            let closeFuture = child.close()
            channel.embeddedEventLoop.run()
            try! closeFuture.wait()
        }

        return streams
    }
}
