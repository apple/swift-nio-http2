//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import CNIONghttp2

public final class PrintEverythingHandler: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = Any
    public typealias OutboundIn = Any

    private let prefix: String

    public init(prefix: String) {
        self.prefix = prefix
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        print("-> \(self.prefix): \(self.unwrapInboundIn(data))")
        ctx.fireChannelRead(data)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        print("<- \(self.prefix): \(self.unwrapInboundIn(data))")
        ctx.write(data, promise: promise)
    }
}

final class HTTP2StreamChannel: Channel, ChannelCore {
    public init(allocator: ByteBufferAllocator, parent: Channel, streamID: Int32) {
        self.allocator = allocator
        self.closePromise = parent.eventLoop.newPromise()
        self.localAddress = parent.localAddress
        self.remoteAddress = parent.remoteAddress
        self.parent = parent
        self.eventLoop = parent.eventLoop
        // FIXME: that's just wrong
        self.isWritable = true
        self.isActive = true
        self._pipeline = ChannelPipeline(channel: self)
        _ = self._pipeline.add(handler: HTTP2ToHTTP1Codec(streamID: streamID))
        _ = self._pipeline.add(handler: PrintEverythingHandler(prefix: "inner"))
        _ = self._pipeline.add(handler: HTTP1TestServer())
    }

    private var _pipeline: ChannelPipeline!

    public let allocator: ByteBufferAllocator

    private let closePromise: EventLoopPromise<()>

    public var closeFuture: EventLoopFuture<Void> {
        return self.closePromise.futureResult
    }

    public var pipeline: ChannelPipeline {
        return self._pipeline
    }

    public let localAddress: SocketAddress?

    public let remoteAddress: SocketAddress?

    public let parent: Channel?

    func localAddress0() throws -> SocketAddress {
        fatalError()
    }

    func remoteAddress0() throws -> SocketAddress {
        fatalError()
    }

    func setOption<T>(option: T, value: T.OptionType) -> EventLoopFuture<Void> where T : ChannelOption {
        fatalError()
    }

    func getOption<T>(option: T) -> EventLoopFuture<T.OptionType> where T : ChannelOption {
        fatalError()
    }

    public let isWritable: Bool

    public let isActive: Bool

    public var _unsafe: ChannelCore {
        return self
    }

    public let eventLoop: EventLoop

    public func register0(promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func flush0() {
        self.parent?.flush()
    }

    public func read0() {
        fatalError("not implemented \(#function)")
    }

    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // FIXME: nothing?
        promise?.succeed(result: ())
        self.closePromise.succeed(result: ())
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func channelRead0(_ data: NIOAny) {
        // do nothing
    }

    public func errorCaught0(error: Error) {
        fatalError("not implemented \(#function)")
    }
}
