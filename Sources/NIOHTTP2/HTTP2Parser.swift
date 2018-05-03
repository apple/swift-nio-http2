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

public final class HTTP2Parser: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundOut = IOData

    public typealias OutboundIn = HTTP2Frame

    /// The mode for this parser to operate in: client or server.
    public enum ParserMode {
        /// Client mode
        case client

        /// Server mode
        case server
    }

    /// The `HTTP2ConnectionManager` used to manage stream IDs on this connection.
    public let connectionManager: HTTP2ConnectionManager

    private var session: NGHTTP2Session!
    private let mode: ParserMode

    public init(mode: ParserMode, connectionManager: HTTP2ConnectionManager = .init()) {
        self.mode = mode
        self.connectionManager = connectionManager
    }

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.session = NGHTTP2Session(mode: self.mode,
                                      allocator: ctx.channel.allocator,
                                      connectionManager: self.connectionManager,
                                      frameReceivedHandler: { ctx.fireChannelRead(self.wrapInboundOut($0)) },
                                      sendFunction: { ctx.write(self.wrapOutboundOut($0), promise: $1) },
                                      flushFunction: ctx.flush)

        self.flushPreamble(ctx: ctx)
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        self.session = nil
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var data = self.unwrapInboundIn(data)
        self.session.feedInput(buffer: &data)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        // TODO(cory): Prevent this unconditionally flushing.
        // TODO(cory): Should this flush at all? The tests rely on it right now.
        self.session.send(allocator: ctx.channel.allocator)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.session.feedOutput(allocator: ctx.channel.allocator, frame: frame, promise: promise)
    }

    public func flush(ctx: ChannelHandlerContext) {
        self.session.send(allocator: ctx.channel.allocator)
    }

    private func flushPreamble(ctx: ChannelHandlerContext) {
        // TODO(cory): This should actually allow configuring settings at some point.
        let fixedSettings: [(UInt16, UInt32)] = [(UInt16(NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS.rawValue), 100)]
        let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(fixedSettings))
        self.session.feedOutput(allocator: ctx.channel.allocator, frame: frame, promise: nil)
        self.flush(ctx: ctx)
    }
}
