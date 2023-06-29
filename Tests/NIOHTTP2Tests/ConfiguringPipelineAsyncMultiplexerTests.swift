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

import XCTest

import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP1
@_spi(AsyncChannel) import NIOHTTP2
import NIOTLS

final class ConfiguringPipelineAsyncMultiplexerTests: XCTestCase {
    var clientChannel: NIOAsyncTestingChannel!
    var serverChannel: NIOAsyncTestingChannel!

    override func setUp() {
        self.clientChannel = NIOAsyncTestingChannel()
        self.serverChannel = NIOAsyncTestingChannel()
    }

    override func tearDown() {
        self.clientChannel = nil
        self.serverChannel = nil
    }


    static let requestFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders([(":method", "GET"), (":authority", "localhost"), (":scheme", "https"), (":path", "/")]), endStream: true))
    static let responseFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders([(":status", "200")]), endStream: true))

    final class OKResponder: ChannelInboundHandler {
        typealias InboundIn = HTTP2Frame.FramePayload
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = self.unwrapInboundIn(data)
            switch frame {
            case .headers:
                break
            default:
                fatalError("unexpected frame type: \(frame)")
            }

            context.channel.writeAndFlush(responseFramePayload, promise: nil)

            context.fireChannelRead(data)
        }
    }

    final class SimpleRequest: ChannelInboundHandler, ChannelOutboundHandler {
        typealias InboundIn = HTTP2Frame.FramePayload
        typealias OutboundIn = HTTP2Frame.FramePayload

        func writeRequest(context: ChannelHandlerContext) {
            context.channel.writeAndFlush(requestFramePayload, promise: nil)
        }

        func channelActive(context: ChannelHandlerContext) {
            self.writeRequest(context: context)
            context.fireChannelActive()
        }
    }

    func testBasicPipelineCommunicates() async throws {
        let requestCount = 100

        let serverRecorder = InboundFramePayloadRecorder()

        let clientMultiplexer = try await assertNoThrowWithValue(
            try await self.clientChannel.configureAsyncHTTP2Pipeline(
                mode: .client,
                connectionConfiguration: .init(),
                streamConfiguration: .init()
            ) { channel -> EventLoopFuture<Channel> in
                channel.eventLoop.makeSucceededFuture(channel)
            }.get()
        )

        let serverMultiplexer = try await assertNoThrowWithValue(
            try await self.serverChannel.configureAsyncHTTP2Pipeline(
                mode: .server,
                connectionConfiguration: .init(),
                streamConfiguration: .init()
            ) { channel -> EventLoopFuture<Channel> in
                channel.pipeline.addHandlers([OKResponder(), serverRecorder]).map { _ in channel }
            }.get()
        )

        try await assertNoThrow(try await self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))

        try await withThrowingTaskGroup(of: Int.self, returning: Void.self) { group in
            // server
            group.addTask {
                var serverInboundChannelCount = 0
                for try await _ in serverMultiplexer.inbound {
                    serverInboundChannelCount += 1
                }
                return serverInboundChannelCount
            }

            // client
            for _ in 0 ..< requestCount {
                // Let's try sending some requests
                let streamChannel = try await clientMultiplexer.createStreamChannel { channel -> EventLoopFuture<Channel> in
                    return channel.pipeline.addHandlers([SimpleRequest(), InboundFramePayloadRecorder()]).map {
                        return channel
                    }
                }

                let clientRecorder = try await streamChannel.pipeline.handler(type: InboundFramePayloadRecorder.self).get()
                try await self.interactInMemory(self.clientChannel, self.serverChannel)
                clientRecorder.receivedFrames.assertFramePayloadsMatch([ConfiguringPipelineAsyncMultiplexerTests.responseFramePayload])
                try await streamChannel.closeFuture.get()
            }

            try await assertNoThrow(try await self.clientChannel.finish())
            try await assertNoThrow(try await self.serverChannel.finish())

            let serverInboundChannelCount = try await assertNoThrowWithValue(try await group.next()!)
            XCTAssertEqual(serverInboundChannelCount, requestCount, "We should have created one server-side channel as a result of the each HTTP/2 stream used.")
        }

        serverRecorder.receivedFrames.assertFramePayloadsMatch(Array(repeating: ConfiguringPipelineAsyncMultiplexerTests.requestFramePayload, count: requestCount))
    }
}

#if swift(<5.9)
// this should be available in the std lib from 5.9 onwards
extension AsyncStream {
    fileprivate static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}
#endif
