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

public final class HTTP2StreamMultiplexer: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = (Int32, HTTP2Frame.FramePayload)

    private var streams: [Int32: Channel] = [:]

    public func channelActive(ctx: ChannelHandlerContext) {

        ctx.write(self.wrapOutboundOut((0, HTTP2Frame.FramePayload.settings([]))), promise: nil)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        let streamID = frame.header.streamID
        if let channel = streams[streamID] {
            channel.pipeline.fireChannelRead(data)
        } else {
            switch (streamID, frame.payload) {
            case (0, _), (_, .headers(_)):
                /* this is legal, new stream starts with a header frame */
                self.streams[streamID] = HTTP2StreamChannel(allocator: ctx.channel.allocator, parent: ctx.channel, streamID: streamID)
                self.channelRead(ctx: ctx, data: data)
            default:
                fatalError("unknown stream \(frame.header.streamID) with \(frame.payload)")
            }
        }
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        /* for now just forward */
        ctx.write(data, promise: promise)
    }

    public init() {}
}
