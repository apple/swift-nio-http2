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

/// NIO's default settings used for initial settings values on HTTP/2 streams, when the user hasn't
/// overridden that. This limits the max concurrent streams to 100, and limits the max header list
/// size to 16kB, to avoid trivial resource exhaustion on NIO HTTP/2 users.
public let nioDefaultSettings = [
    HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
    HTTP2Setting(parameter: .maxHeaderListSize, value: 1<<16)
]

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
    private var outboundFrameBuffer: CircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>
    private let mode: ParserMode
    private let initialSettings: [HTTP2Setting]

    public init(mode: ParserMode, connectionManager: HTTP2ConnectionManager = .init(), initialSettings: [HTTP2Setting] = nioDefaultSettings) {
        self.mode = mode
        self.connectionManager = connectionManager
        self.initialSettings = initialSettings
        self.outboundFrameBuffer = CircularBuffer(initialRingCapacity: 8)
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
        self.session.send()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        do {
            try self.session.receivedEOF()
        } catch {
            ctx.fireErrorCaught(error)
        }
        dropOutstandingWrites()
        ctx.fireChannelInactive()
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        // Half-closure is not allowed for HTTP/2: it must always be possible to send frames both ways.
        if case .some(.inputClosed) = event as? ChannelEvent {
            do {
                try self.session.receivedEOF()
            } catch {
                ctx.fireErrorCaught(error)
            }
            dropOutstandingWrites()
        }
        ctx.fireUserInboundEventTriggered(event)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.outboundFrameBuffer.append((frame, promise))
    }

    public func flush(ctx: ChannelHandlerContext) {
        while self.outboundFrameBuffer.count > 0 {
            let (frame, promise) = self.outboundFrameBuffer.removeFirst()
            self.session.feedOutput(frame: frame, promise: promise)
        }
        self.session.send()
    }

    private func flushPreamble(ctx: ChannelHandlerContext) {
        let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(self.initialSettings))
        self.session.feedOutput(frame: frame, promise: nil)
        self.flush(ctx: ctx)
    }

    private func dropOutstandingWrites() {
        while self.outboundFrameBuffer.count > 0 {
            self.outboundFrameBuffer.removeFirst().1?.fail(error: ChannelError.eof)
        }
    }
}
