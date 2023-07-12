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

import NIOConcurrencyHelpers
@_spi(AsyncChannel) import NIOCore
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

    static let requestHead = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/testHTTP1")
    static let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: HTTPHeaders([("transfer-encoding", "chunked")]))

    final class OKResponder: ChannelInboundHandler {
        typealias InboundIn = HTTP2Frame.FramePayload
        typealias OutboundOut = HTTP2Frame.FramePayload

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = self.unwrapInboundIn(data)
            switch frame {
            case .headers:
                break
            default:
                fatalError("unexpected frame type: \(frame)")
            }

            context.writeAndFlush(self.wrapOutboundOut(responseFramePayload), promise: nil)
            context.fireChannelRead(data)
        }
    }

    final class HTTP1OKResponder: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch self.unwrapInboundIn(data) {
            case .head:
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            case .body, .end:
                break
            }

            context.fireChannelRead(data)
        }
    }

    final class SimpleRequest: ChannelInboundHandler {
        typealias InboundIn = HTTP2Frame.FramePayload
        typealias OutboundOut = HTTP2Frame.FramePayload

        func writeRequest(context: ChannelHandlerContext) {
            context.writeAndFlush(self.wrapOutboundOut(requestFramePayload), promise: nil)
        }

        func channelActive(context: ChannelHandlerContext) {
            self.writeRequest(context: context)
            context.fireChannelActive()
        }
    }

    // `testBasicPipelineCommunicates` ensures that a client-server system set up to use async stream abstractions
    // can communicate successfully.
    func testBasicPipelineCommunicates() async throws {
        let requestCount = 100

        let serverRecorder = InboundFramePayloadRecorder()

        let clientMultiplexer = try await assertNoThrowWithValue(
            try await self.clientChannel.configureAsyncHTTP2Pipeline(mode: .client) { channel -> EventLoopFuture<Channel> in
                channel.eventLoop.makeSucceededFuture(channel)
            }.get()
        )

        let serverMultiplexer = try await assertNoThrowWithValue(
            try await self.serverChannel.configureAsyncHTTP2Pipeline(mode: .server) { channel -> EventLoopFuture<Channel> in
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
                try await self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)
                try await self.deliverAllBytes(from: self.serverChannel, to: self.clientChannel)
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

    // `testNIOAsyncConnectionStreamChannelPipelineCommunicates` ensures that a client-server system set up to use `NIOAsyncChannel`
    // wrappers around connection and stream channels can communicate successfully.
    func testNIOAsyncConnectionStreamChannelPipelineCommunicates() async throws {
        let requestCount = 100

        let (clientAsyncChannel, clientMultiplexer) = try await assertNoThrowWithValue(
            try await self.clientChannel.configureAsyncHTTP2Pipeline(
                mode: .client,
                configuration: .init(
                    connectionAsyncChannel: NIOAsyncChannel.Configuration(inboundType: HTTP2Frame.self, outboundType: HTTP2Frame.self),
                    inboundStreamAsyncChannel: NIOAsyncChannel.Configuration(inboundType: HTTP2Frame.FramePayload.self, outboundType: HTTP2Frame.FramePayload.self)
                ) { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                } inboundStreamInitializer: { channel -> EventLoopFuture<Void> in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
            ).get()
        )

        let (serverAsyncChannel, serverMultiplexer) = try await assertNoThrowWithValue(
            try await self.serverChannel.configureAsyncHTTP2Pipeline(
                mode: .server,
                configuration: .init(
                    connectionAsyncChannel: NIOAsyncChannel.Configuration(inboundType: HTTP2Frame.self, outboundType: HTTP2Frame.self),
                    inboundStreamAsyncChannel: NIOAsyncChannel.Configuration(inboundType: HTTP2Frame.FramePayload.self, outboundType: HTTP2Frame.FramePayload.self)
                ) { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                } inboundStreamInitializer: { channel -> EventLoopFuture<Void> in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
            ).get()
        )

        try await assertNoThrow(try await self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))

        try await withThrowingTaskGroup(of: Int.self, returning: Void.self) { group in
            // server
            group.addTask {
                var serverInboundChannelCount = 0
                for try await streamChannel in serverMultiplexer.inbound {
                    for try await receivedFrame in streamChannel.inboundStream {
                        receivedFrame.assertFramePayloadMatches(this: ConfiguringPipelineAsyncMultiplexerTests.requestFramePayload)

                        try await streamChannel.outboundWriter.write(ConfiguringPipelineAsyncMultiplexerTests.responseFramePayload)
                        streamChannel.outboundWriter.finish()

                        try await self.deliverAllBytes(from: self.serverChannel, to: self.clientChannel)
                    }
                    serverInboundChannelCount += 1
                }
                return serverInboundChannelCount
            }

            // client
            for _ in 0 ..< requestCount {
                let streamChannel = try await clientMultiplexer.createStreamChannel(
                    configuration: .init(
                        inboundType: HTTP2Frame.FramePayload.self,
                        outboundType: HTTP2Frame.FramePayload.self
                    )
                ) { channel -> EventLoopFuture<Void> in
                    channel.eventLoop.makeSucceededVoidFuture()
                }
                // Let's try sending some requests
                try await streamChannel.outboundWriter.write(ConfiguringPipelineAsyncMultiplexerTests.requestFramePayload)
                streamChannel.outboundWriter.finish()

                try await self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)

                for try await receivedFrame in streamChannel.inboundStream {
                    receivedFrame.assertFramePayloadMatches(this: ConfiguringPipelineAsyncMultiplexerTests.responseFramePayload)
                }
            }

            clientAsyncChannel.outboundWriter.finish()
            serverAsyncChannel.outboundWriter.finish()

            try await assertNoThrow(try await self.clientChannel.finish())
            try await assertNoThrow(try await self.serverChannel.finish())

            let serverInboundChannelCount = try await assertNoThrowWithValue(try await group.next()!)
            XCTAssertEqual(serverInboundChannelCount, requestCount, "We should have created one server-side channel as a result of the one HTTP/2 stream used.")
        }
    }
    
    // `testNegotiatedHTTP2BasicPipelineCommunicates` ensures that a client-server system set up to use async stream abstractions
    // can communicate successfully when HTTP/2 is negotiated.
    func testNegotiatedHTTP2BasicPipelineCommunicates() async throws {
        let requestCount = 100

        let serverRecorder = InboundFramePayloadRecorder()

        let clientMultiplexer = try await assertNoThrowWithValue(
            try await self.clientChannel.configureAsyncHTTP2Pipeline(mode: .client) { channel -> EventLoopFuture<Channel> in
                channel.eventLoop.makeSucceededFuture(channel)
            }.get()
        )

        let nioProtocolNegotiationHandler = try await self.serverChannel.configureAsyncHTTPServerPipeline() { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        } http2ConnectionInitializer: { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        } http2InboundStreamInitializer: { channel -> EventLoopFuture<Channel> in
            channel.pipeline.addHandlers([OKResponder(), serverRecorder]).map { _ in channel }
        }.get()

        // Let's pretend the TLS handler did protocol negotiation for us
        self.serverChannel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "h2"))

        let nioProtocolNegotiationResult = try await nioProtocolNegotiationHandler.protocolNegotiationResult.get()

        try await assertNoThrow(try await self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))

        let serverMultiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
        switch nioProtocolNegotiationResult {
        case .deferredResult:
            preconditionFailure("Negotiation result must be ready")
        case .finished(let negotiationResult):
            switch negotiationResult {
            case .http1_1:
                preconditionFailure("Negotiation result must be ready")
            case .http2(let (_, multiplexer)):
                serverMultiplexer = multiplexer
            }
        }

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

                try await self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)
                try await self.deliverAllBytes(from: self.serverChannel, to: self.clientChannel)

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

    // `testNegotiatedHTTP1BasicPipelineCommunicates` ensures that a client-server system set up to use async stream abstractions
    // can communicate successfully when HTTP/1.1 is negotiated.
    func testNegotiatedHTTP1BasicPipelineCommunicates() async throws {
        let requestCount = 100

        let _ = try await self.clientChannel.pipeline.addHTTPClientHandlers().map { _ in
            self.clientChannel.pipeline.addHandlers([InboundRecorderHandler<HTTPClientResponsePart>(), HTTP1ClientSendability()])
        }.get()

        let nioProtocolNegotiationHandler = try await self.serverChannel.configureAsyncHTTPServerPipeline() { channel in
            channel.pipeline.addHandlers([HTTP1OKResponder(), InboundRecorderHandler<HTTPServerRequestPart>()])
        } http2ConnectionInitializer: { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        } http2InboundStreamInitializer: { channel -> EventLoopFuture<Channel> in
            channel.eventLoop.makeSucceededFuture(channel)
        }.get()

        // Let's pretend the TLS handler did protocol negotiation for us
        self.serverChannel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "http/1.1"))

        let nioProtocolNegotiationResult = try await nioProtocolNegotiationHandler.protocolNegotiationResult.get()

        try await self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)
        try await self.deliverAllBytes(from: self.serverChannel, to: self.clientChannel)

        switch nioProtocolNegotiationResult {
        case .deferredResult:
            preconditionFailure("Negotiation result must be ready")
        case .finished(let negotiationResult):
            switch negotiationResult {
            case .http1_1:
                break
            case .http2:
                preconditionFailure("Negotiation result must be http/1.1")
            }
        }

        // client
        for _ in 0 ..< requestCount {
            // Let's try sending some http/1.1 requests.
            // we need to put these through a mapping to remove references to `IOData` which isn't Sendable
            try await self.clientChannel.writeOutbound(HTTP1ClientSendability.RequestPart.head(ConfiguringPipelineAsyncMultiplexerTests.requestHead))
            try await self.clientChannel.writeOutbound(HTTP1ClientSendability.RequestPart.end(nil))
            try await self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)
            try await self.deliverAllBytes(from: self.serverChannel, to: self.clientChannel)
        }

        // check expectations
        let clientRecorder = try await self.clientChannel.pipeline.handler(type: InboundRecorderHandler<HTTPClientResponsePart>.self).get()
        let serverRecorder = try await self.serverChannel.pipeline.handler(type: InboundRecorderHandler<HTTPServerRequestPart>.self).get()

        XCTAssertEqual(serverRecorder.receivedParts.count, requestCount*2)
        XCTAssertEqual(clientRecorder.receivedParts.count, requestCount*2)

        for i in 0 ..< requestCount {
            XCTAssertEqual(serverRecorder.receivedParts[i*2], HTTPServerRequestPart.head(ConfiguringPipelineAsyncMultiplexerTests.requestHead), "Unexpected request part in iteration \(i)")
            XCTAssertEqual(serverRecorder.receivedParts[i*2+1], HTTPServerRequestPart.end(nil), "Unexpected request part in iteration \(i)")

            XCTAssertEqual(clientRecorder.receivedParts[i*2], HTTPClientResponsePart.head(ConfiguringPipelineAsyncMultiplexerTests.responseHead), "Unexpected response part in iteration \(i)")
            XCTAssertEqual(clientRecorder.receivedParts[i*2+1], HTTPClientResponsePart.end(nil), "Unexpected response part in iteration \(i)")
        }

        try await assertNoThrow(try await self.clientChannel.finish())
        try await assertNoThrow(try await self.serverChannel.finish())
    }

    // Simple handler which maps client request parts to remove references to `IOData` which isn't Sendable
    internal final class HTTP1ClientSendability: ChannelOutboundHandler {
        public typealias RequestPart = HTTPPart<HTTPRequestHead, ByteBuffer>

        typealias OutboundIn = RequestPart
        typealias OutboundOut = HTTPClientRequestPart

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            let requestPart = self.unwrapOutboundIn(data)

            let httpClientRequestPart: HTTPClientRequestPart
            switch requestPart {
            case .head(let head):
                httpClientRequestPart = .head(head)
            case .body(let byteBuffer):
                httpClientRequestPart = .body(.byteBuffer(byteBuffer))
            case .end(let headers):
                httpClientRequestPart = .end(headers)
            }

            context.write(self.wrapOutboundOut(httpClientRequestPart), promise: promise)
        }
    }

    // Simple handler which maps server response parts to remove references to `IOData` which isn't Sendable
    internal final class HTTP1ServerSendability: ChannelOutboundHandler {
        public typealias ResponsePart = HTTPPart<HTTPResponseHead, ByteBuffer>

        typealias OutboundIn = ResponsePart
        typealias OutboundOut = HTTPServerResponsePart

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            let responsePart = self.unwrapOutboundIn(data)

            let httpServerResponsePart: HTTPServerResponsePart
            switch responsePart {
            case .head(let head):
                httpServerResponsePart = .head(head)
            case .body(let byteBuffer):
                httpServerResponsePart = .body(.byteBuffer(byteBuffer))
            case .end(let headers):
                httpServerResponsePart = .end(headers)
            }

            context.write(self.wrapOutboundOut(httpServerResponsePart), promise: promise)
        }
    }

    /// A simple channel handler that records inbound messages.
    internal final class InboundRecorderHandler<message>: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = message

        private let partsLock = NIOLock()
        private var _receivedParts: [message] = []

        var receivedParts: [message] {
            get {
                self.partsLock.withLock {
                    self._receivedParts
                }
            }
            set {
                self.partsLock.withLock {
                    self._receivedParts = newValue
                }
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            self.receivedParts.append(self.unwrapInboundIn(data))
            context.fireChannelRead(data)
        }
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
