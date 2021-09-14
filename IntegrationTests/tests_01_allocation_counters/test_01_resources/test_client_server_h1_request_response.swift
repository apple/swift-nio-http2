//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
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

/// Have two `EmbeddedChannel` objects send and receive data from each other until
/// they make no forward progress.
func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel) throws {
    var operated: Bool

    func readBytesFromChannel(_ channel: EmbeddedChannel) throws -> ByteBuffer? {
        return try channel.readOutbound(as: ByteBuffer.self)
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

final class ServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        switch data {
        case .head, .body:
            // Ignore this
            return
        case .end:
            break
        }

        // We got .end. Let's send a response.
        let head = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}


final class ClientHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    func channelActive(context: ChannelHandlerContext) {
        // Send a request.
        let head = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .GET, uri: "/", headers: HTTPHeaders([("host", "localhost")]))
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

func run(identifier: String) {
    let loop = EmbeddedEventLoop()

    measure(identifier: identifier) {
        var sumOfStreamIDs = 0

        for _ in 0..<1000 {
            let clientChannel = EmbeddedChannel(loop: loop)
            let serverChannel = EmbeddedChannel(loop: loop)

            let clientMultiplexer = try! clientChannel.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil).wait()
            _ = try! serverChannel.configureHTTP2Pipeline(mode: .server) { channel in
                return channel.pipeline.addHandlers([HTTP2FramePayloadToHTTP1ServerCodec(), ServerHandler()])
            }.wait()
            try! clientChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()
            try! serverChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()

            let promise = clientChannel.eventLoop.makePromise(of: Channel.self)
            clientMultiplexer.createStreamChannel(promise: promise) { channel in
                return channel.pipeline.addHandlers([HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https), ClientHandler()])
            }
            clientChannel.embeddedEventLoop.run()
            let child = try! promise.futureResult.wait()
            let streamID = try! Int(child.getOption(HTTP2StreamChannelOptions.streamID).wait())

            sumOfStreamIDs += streamID
            try! interactInMemory(clientChannel, serverChannel)
            try! child.closeFuture.wait()

            try! clientChannel.close().wait()
            try! serverChannel.close().wait()
        }

        return sumOfStreamIDs
    }
}

