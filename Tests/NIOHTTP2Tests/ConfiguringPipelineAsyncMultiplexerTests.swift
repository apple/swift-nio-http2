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
        XCTAssertNoThrow(try self.clientChannel.connect(to: .init(unixDomainSocketPath: "ignored")).wait())
        self.serverChannel = NIOAsyncTestingChannel()
        XCTAssertNoThrow(try self.serverChannel.connect(to: .init(unixDomainSocketPath: "ignored")).wait())
    }

    override func tearDown() {
        self.clientChannel = nil
        self.serverChannel = nil
    }


    static let requestFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders([(":method", "GET"), (":authority", "localhost"), (":scheme", "https"), (":path", "/")]), endStream: true))
    static let responseFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders([(":status", "200")]), endStream: true))

    class OKResponder: ChannelInboundHandler {
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

    class SimpleRequest: ChannelInboundHandler, ChannelOutboundHandler {
        typealias InboundIn = HTTP2Frame.FramePayload
        typealias OutboundIn = HTTP2Frame.FramePayload

        func writeRequest(context: ChannelHandlerContext) {
            context.channel.writeAndFlush(requestFramePayload, promise: nil)
        }

        func channelActive(context: ChannelHandlerContext) {
            self.writeRequest(context: context)
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = self.unwrapInboundIn(data)
            switch frame {
            case .headers:
                break
            default:
                fatalError("unexpected frame type: \(frame)")
            }
            context.fireChannelRead(data)
        }
    }

    func testBasicPipelineCommunicates() async throws {
        let requestCount = 100


        let (serverRecorderStream, serverRecorderContinuation) = AsyncStream<InboundRecorder<HTTP2Frame.FramePayload>>.makeStream()
        var serverRecorderIterator = serverRecorderStream.makeAsyncIterator()

        let clientMultiplexer = try await assertNoThrowWithValue(
            try await self.clientChannel.configureHTTP2PipelineAsync(
                mode: .client, connectionConfiguration: .init(), streamConfiguration: .init()) { channel in self.serverChannel.eventLoop.makeSucceededFuture(channel) }.get()
        )

        let serverMultiplexer = try await assertNoThrowWithValue(
            try await self.serverChannel.configureHTTP2PipelineAsync(
                mode: .server, connectionConfiguration: .init(), streamConfiguration: .init()) { channel in
                    let serverRecorder = InboundFramePayloadRecorder()
                    serverRecorderContinuation.yield(serverRecorder)
                    return channel.pipeline.addHandlers([OKResponder(), serverRecorder]).map { _ in channel }
                }.get()
        )

        try await assertNoThrow(try await self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))


        let (clientRecorderStream, clientRecorderContinuation) = AsyncStream<InboundRecorder<HTTP2Frame.FramePayload>>.makeStream()
        var clientRecorderIterator = clientRecorderStream.makeAsyncIterator()

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
                let streamChannel = try await clientMultiplexer.createStreamChannel() { channel in
                    let clientRecorder = InboundFramePayloadRecorder()
                    clientRecorderContinuation.yield(clientRecorder)
                    return channel.pipeline.addHandlers([SimpleRequest(), clientRecorder]).map {
                        return channel
                    }
                }

                try await self.interactInMemory(self.clientChannel, self.serverChannel)

                await self.clientChannel.testingEventLoop.run()
                try await streamChannel.closeFuture.get()

                let clientRecorder = await clientRecorderIterator.next()!
                clientRecorder.receivedFrames.assertFramePayloadsMatch([ConfiguringPipelineAsyncMultiplexerTests.responseFramePayload])
            }

            self.clientChannel.close(promise: nil)
            await self.clientChannel.testingEventLoop.run()
            group.cancelAll()

            let serverInboundChannelCount =  try await assertNoThrowWithValue(try await group.next()!)
            XCTAssertEqual(serverInboundChannelCount, requestCount, "We should have created one server-side channel as a result of the one HTTP/2 stream used.")
        }

        for _ in 0 ..< requestCount {
            let serverRecorder = await serverRecorderIterator.next()!
            serverRecorder.receivedFrames.assertFramePayloadsMatch([ConfiguringPipelineAsyncMultiplexerTests.requestFramePayload])
        }

        await self.clientChannel.assertNoFramesReceived()
        await self.serverChannel.assertNoFramesReceived()

        try await assertNoThrow(try await self.clientChannel.finish(acceptAlreadyClosed: true))
        try await assertNoThrow(try await self.serverChannel.finish())
    }
}

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
