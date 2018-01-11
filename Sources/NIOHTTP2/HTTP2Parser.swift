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
    public typealias OutboundOut = ByteBuffer

    public typealias OutboundIn = (Int32, HTTP2Frame.FramePayload)

    private var session: NGHTTP2Session!

    public func channelRegistered(ctx: ChannelHandlerContext) {
        self.session = NGHTTP2Session(mode: .server) {
            ctx.fireChannelRead(self.wrapInboundOut($0))
        }
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        self.session = nil
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var data = self.unwrapInboundIn(data)
        self.session.feedInput(buffer: &data)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.session.feedOutput(allocator: ctx.channel.allocator, streamID: frame.0, buffer: frame.1)
    }

    public func flush(ctx: ChannelHandlerContext) {
        self.session.send(allocator: ctx.channel.allocator, flushFunction: ctx.flush) { buffer in
            ctx.write(self.wrapOutboundOut(buffer), promise: nil)
        }
    }

    public init() {}
}
