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
    private let inboundStreamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?
    private var channel: Channel?

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.channel = ctx.channel
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        self.channel = nil
    }

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
            let channel = HTTP2StreamChannel(allocator: self.channel!.allocator,
                                             parent: self.channel!,
                                             streamID: streamID)
            channel.configure(initializer: self.inboundStreamStateInitializer)
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

    /// Create a new `HTTP2StreamMultiplexer`.
    ///
    /// - parameters:
    ///     - inboundStreamStateInitializer: A block that will be invoked to configure each new child stream
    ///         channel that is created by the remote peer. For servers, these are channels created by
    ///         receiving a `HEADERS` frame from a client. For clients, these are channels created by
    ///         receiving a `PUSH_PROMISE` frame from a server. To initiate a new outbound channel, use
    ///         `createStreamChannel`.
    public init(inboundStreamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)? = nil) {
        self.inboundStreamStateInitializer = inboundStreamStateInitializer
    }
}

extension HTTP2StreamMultiplexer {
    /// Create a new `Channel` for a new stream initiated by this peer.
    ///
    /// This method is intended for situations where the NIO application is initiating the stream. For clients,
    /// this is for all request streams. For servers, this is for pushed streams.
    ///
    /// - parameters:
    ///     - promise: An `EventLoopPromise` that will be succeeded with the new activated channel, or
    ///         failed if an error occurs.
    ///     - streamStateInitializer: A callback that will be invoked to allow you to configure the
    ///         `ChannelPipeline` for the newly created channel.
    /// - returns: An `EventLoopFuture` that completes with the new channel.
    public func createStreamChannel(promise: EventLoopPromise<Channel>?, _ streamStateInitializer: @escaping (Channel, HTTP2StreamID) -> EventLoopFuture<Void>) {
        guard let ourChannel = self.channel else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        ourChannel.eventLoop.execute {
            let streamID = HTTP2StreamID()
            let channel = HTTP2StreamChannel(allocator: ourChannel.allocator,
                                             parent: ourChannel,
                                             streamID: streamID)
            let activationFuture = channel.configure(initializer: streamStateInitializer)
            self.streams[streamID] = channel
            channel.closeFuture.whenComplete {
                self.childChannelClosed(streamID: streamID)
            }

            if let promise = promise {
                activationFuture.map { channel }.cascade(promise: promise)
            }
        }
    }
}
