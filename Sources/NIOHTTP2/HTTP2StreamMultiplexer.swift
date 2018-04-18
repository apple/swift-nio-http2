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

/// A channel handler that creates a child channel for each HTTP/2 stream.
///
/// In general in NIO applications it is helpful to consider each HTTP/2 stream as an
/// independent stream of HTTP/2 frames. This multiplexer achieves this by creating a
/// number of in-memory `HTTP2StreamChannel` objects, one for each stream. These operate
/// on `HTTP2Frame` objects as their base communication atom, as opposed to the regular
/// NIO `SelectableChannel` objects which use `ByteBuffer` and `IOData`.
public final class HTTP2StreamMultiplexer: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    private var streams: [Int32: HTTP2StreamChannel] = [:]
    private let streamStateInitializer: ((Channel, Int) -> EventLoopFuture<Void>)?

    public func channelActive(ctx: ChannelHandlerContext) {
        let frame = HTTP2Frame(streamID: 0, payload: .settings([]))
        ctx.write(self.wrapOutboundOut(frame), promise: nil)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        let streamID = frame.streamID

        guard streamID != 0 else {
            // For stream 0 we forward all frames on to the main channel.
            ctx.fireChannelRead(data)
            return
        }

        if let channel = streams[streamID] {
            channel.receiveInboundFrame(frame)
        } else {
            guard case .headers = frame.payload else {
                // This should probably produce a runtime error.
                fatalError("unknown stream \(frame.streamID) with \(frame.payload)")
            }

            let channel =  HTTP2StreamChannel(allocator: ctx.channel.allocator,
                                              parent: ctx.channel,
                                              streamID: streamID,
                                              initializer: self.streamStateInitializer)

            self.streams[streamID] = channel
            channel.receiveInboundFrame(frame)
        }
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        /* for now just forward */
        ctx.write(data, promise: promise)
    }

    public init(streamStateInitializer: ((Channel, Int) -> EventLoopFuture<Void>)? = nil) {
        self.streamStateInitializer = streamStateInitializer
    }
}
