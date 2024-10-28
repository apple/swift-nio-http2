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

final class ServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)
        switch payload {
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
        let responseFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))
        context.writeAndFlush(self.wrapOutboundOut(responseFramePayload), promise: nil)
    }
}

final class ClientHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    let dataBlockCount: Int
    let dataBlockLengthBytes: Int

    init(dataBlockCount: Int, dataBlockLengthBytes: Int) {
        self.dataBlockCount = dataBlockCount
        self.dataBlockLengthBytes = dataBlockLengthBytes
    }

    func channelActive(context: ChannelHandlerContext) {
        // Send a request.
        let headers = HPACKHeaders([
            (":path", "/"),
            (":authority", "localhost"),
            (":method", "GET"),
            (":scheme", "https"),
        ])

        if self.dataBlockCount > 0 {
            let requestFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: false))
            context.write(self.wrapOutboundOut(requestFramePayload), promise: nil)

            let buffer = ByteBuffer(repeating: 0, count: self.dataBlockLengthBytes)

            for _ in 0..<self.dataBlockCount - 1 {
                context.write(
                    self.wrapOutboundOut(
                        HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: false))
                    ),
                    promise: nil
                )
            }
            context.writeAndFlush(
                self.wrapOutboundOut(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: true))),
                promise: nil
            )
        } else {
            let requestFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))
            context.writeAndFlush(self.wrapOutboundOut(requestFramePayload), promise: nil)
        }
    }
}

func run(identifier: String) {
    testRun(identifier: identifier) { clientChannel in
        try! clientChannel.configureHTTP2Pipeline(mode: .client) { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        }.wait()
    } serverPipelineConfigurator: { serverChannel in
        _ = try! serverChannel.configureHTTP2Pipeline(mode: .server) { channel in
            channel.pipeline.addHandler(ServerHandler())
        }.wait()
    }

    testRun(identifier: identifier + "_many", dataBlockCount: 100, dataBlockLengthBytes: 1000) { clientChannel in
        try! clientChannel.configureHTTP2Pipeline(mode: .client) { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        }.wait()
    } serverPipelineConfigurator: { serverChannel in
        _ = try! serverChannel.configureHTTP2Pipeline(mode: .server) { channel in
            channel.pipeline.addHandler(ServerHandler())
        }.wait()
    }

    //
    // MARK: - Inline HTTP2 multiplexer tests
    testRun(identifier: identifier + "_inline") { clientChannel in
        try! clientChannel.configureHTTP2Pipeline(
            mode: .client,
            connectionConfiguration: .init(),
            streamConfiguration: .init()
        ) { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        }.wait()
    } serverPipelineConfigurator: { serverChannel in
        _ = try! serverChannel.configureHTTP2Pipeline(
            mode: .server,
            connectionConfiguration: .init(),
            streamConfiguration: .init()
        ) { channel in
            channel.pipeline.addHandler(ServerHandler())
        }.wait()
    }

    testRun(identifier: identifier + "_many_inline", dataBlockCount: 100, dataBlockLengthBytes: 1000) { clientChannel in
        try! clientChannel.configureHTTP2Pipeline(
            mode: .client,
            connectionConfiguration: .init(),
            streamConfiguration: .init()
        ) { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        }.wait()
    } serverPipelineConfigurator: { serverChannel in
        _ = try! serverChannel.configureHTTP2Pipeline(
            mode: .server,
            connectionConfiguration: .init(),
            streamConfiguration: .init()
        ) { channel in
            channel.pipeline.addHandler(ServerHandler())
        }.wait()
    }
}

private func testRun(
    identifier: String,
    dataBlockCount: Int = 0,
    dataBlockLengthBytes: Int = 0,
    clientPipelineConfigurator: (Channel) throws -> MultiplexerChannelCreator,
    serverPipelineConfigurator: (Channel) throws -> Void
) {
    let loop = EmbeddedEventLoop()

    measure(identifier: identifier) {
        var sumOfStreamIDs = 0

        for _ in 0..<1000 {
            let clientChannel = EmbeddedChannel(loop: loop)
            let serverChannel = EmbeddedChannel(loop: loop)

            let clientMultiplexer = try! clientPipelineConfigurator(clientChannel)
            try! serverPipelineConfigurator(serverChannel)
            try! clientChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()
            try! serverChannel.connect(to: SocketAddress(ipAddress: "1.2.3.4", port: 5678)).wait()

            let promise = clientChannel.eventLoop.makePromise(of: Channel.self)
            clientMultiplexer.createStreamChannel(promise: promise) { channel in
                channel.pipeline.addHandler(
                    ClientHandler(dataBlockCount: dataBlockCount, dataBlockLengthBytes: dataBlockLengthBytes)
                )
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
