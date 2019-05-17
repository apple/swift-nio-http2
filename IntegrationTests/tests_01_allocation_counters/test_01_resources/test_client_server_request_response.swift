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
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        switch data.payload {
        case .headers(let headers) where headers.endStream:
            break
        case .data(let data) where data.endStream:
            break
        default:
            // Ignore this frame
            return
        }

        // We got END_STREAM. Let's send a response.
        let headers = HPACKHeaders([(":status", "200")])
        let responseFrame = HTTP2Frame(streamID: data.streamID, payload: .headers(.init(headers: headers, endStream: true)))
        context.writeAndFlush(self.wrapOutboundOut(responseFrame), promise: nil)
    }
}


final class ClientHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    let streamID: HTTP2StreamID

    init(streamID: HTTP2StreamID) {
        self.streamID = streamID
    }

    func channelActive(context: ChannelHandlerContext) {
        // Send a request.
        let headers = HPACKHeaders([(":path", "/"),
                                    (":authority", "localhost"),
                                    (":method", "GET"),
                                    (":scheme", "https")])
        let requestFrame = HTTP2Frame(streamID: self.streamID, payload: .headers(.init(headers: headers, endStream: true)))
        context.writeAndFlush(self.wrapOutboundOut(requestFrame), promise: nil)
    }
}

func run(identifier: String) {
    let loop = EmbeddedEventLoop()

    measure(identifier: identifier) {
        var sumOfStreamIDs = 0

        for _ in 0..<1000 {
            let clientChannel = EmbeddedChannel(loop: loop)
            let serverChannel = EmbeddedChannel(loop: loop)

            let clientMultiplexer = try! clientChannel.configureHTTP2Pipeline(mode: .client).wait()
            _ = try! serverChannel.configureHTTP2Pipeline(mode: .server) { (channel, streamID) in
                return channel.pipeline.addHandler(ServerHandler())
            }.wait()
            try! clientChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()
            try! serverChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()

            let promise = clientChannel.eventLoop.makePromise(of: Channel.self)
            clientMultiplexer.createStreamChannel(promise: promise) { (channel, streamID) in
                return channel.pipeline.addHandler(ClientHandler(streamID: streamID))
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

