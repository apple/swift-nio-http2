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

    private var session: NGHTTP2Session!

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.session = NGHTTP2Session(mode: .server,
                                      allocator: ctx.channel.allocator,
                                      frameReceivedHandler: { ctx.fireChannelRead(self.wrapInboundOut($0)) },
                                      sendFunction: { ctx.write(self.wrapOutboundOut($0), promise: $1) },
                                      flushFunction: ctx.flush)
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        self.session = nil
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var data = self.unwrapInboundIn(data)
        self.session.feedInput(buffer: &data)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.session.feedOutput(allocator: ctx.channel.allocator, frame: frame, promise: promise)
    }

    public func flush(ctx: ChannelHandlerContext) {
        self.session.send(allocator: ctx.channel.allocator)
    }

    public init() {}
}
