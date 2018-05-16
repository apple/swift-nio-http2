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
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    private var streams: [HTTP2StreamID: HTTP2StreamChannel] = [:]
    private let streamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        let streamID = frame.streamID

        guard streamID != .rootStream else {
            // For stream 0 we forward all frames on to the main channel.
            ctx.fireChannelRead(data)
            return
        }

        if let channel = streams[streamID] {
            channel.receiveInboundFrame(frame)
        } else if case .headers = frame.payload {
            let channel = HTTP2StreamChannel(allocator: ctx.channel.allocator,
                                             parent: ctx.channel,
                                             streamID: streamID,
                                             initializer: self.streamStateInitializer)

            self.streams[streamID] = channel
            channel.closeFuture.whenComplete {
                self.childChannelClosed(streamID: streamID)
            }
            channel.receiveInboundFrame(frame)
        } else {
            // This frame is for a stream we know nothing about. We can't do much about it, so we
            // are going to fire an error and drop the frame.
            let error = NIOHTTP2Errors.NoSuchStream(streamID: streamID)
            ctx.fireErrorCaught(error)
        }
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        /* for now just forward */
        ctx.write(data, promise: promise)
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        // The only event we care about right now is StreamClosedEvent, and in particular
        // we only care about it if we still have the stream channel for the stream
        // in question.
        guard let evt = event as? StreamClosedEvent, let channel = self.streams[evt.streamID] else {
            ctx.fireUserInboundEventTriggered(event)
            return
        }

        channel.receiveStreamClosed(evt.reason)
    }

    private func childChannelClosed(streamID: HTTP2StreamID) {
        self.streams.removeValue(forKey: streamID)
    }

    public init(streamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)? = nil) {
        self.streamStateInitializer = streamStateInitializer
    }
}
