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

import NIO
import NIOHPACK
import NIOHTTP1
import NIOHTTP2

func run(identifier: String) {
    let channel = EmbeddedChannel(handler: NIOHTTP2Handler(mode: .client))
    let multiplexer = HTTP2StreamMultiplexer(mode: .client, channel: channel)
    try! channel.pipeline.addHandler(multiplexer).wait()
    try! channel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()

    measure(identifier: identifier) {
        var sumOfStreamIDs = 0

        for _ in 0..<1000 {
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            multiplexer.createStreamChannel(promise: promise) { (channel, streamID) in
                return channel.eventLoop.makeSucceededFuture(())
            }
            channel.embeddedEventLoop.run()
            let child = try! promise.futureResult.wait()
            let streamID = try! Int(child.getOption(HTTP2StreamChannelOptions.streamID).wait())

            sumOfStreamIDs += streamID
            let closeFuture = child.close()
            channel.embeddedEventLoop.run()
            try! closeFuture.wait()
        }

        return sumOfStreamIDs
    }
}
