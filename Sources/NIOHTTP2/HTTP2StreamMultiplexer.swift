//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// A channel handler that creates a child channel for each HTTP/2 stream.
///
/// In general in NIO applications it is helpful to consider each HTTP/2 stream as an
/// independent stream of HTTP/2 frames. This multiplexer achieves this by creating a
/// number of in-memory `HTTP2StreamChannel` objects, one for each stream. These operate
/// on ``HTTP2Frame`` or ``HTTP2Frame/FramePayload`` objects as their base communication
/// atom, as opposed to the regular NIO `SelectableChannel` objects which use `ByteBuffer`
/// and `IOData`.
public final class HTTP2StreamMultiplexer: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    private let channel: Channel
    private var context: ChannelHandlerContext!

    private let commonStreamMultiplexer: HTTP2CommonInboundStreamMultiplexer

    public func handlerAdded(context: ChannelHandlerContext) {
        // We now need to check that we're on the same event loop as the one we were originally given.
        // If we weren't, this is a hard failure, as there is a thread-safety issue here.
        self.channel.eventLoop.preconditionInEventLoop()
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.commonStreamMultiplexer.clearDidReadChannels()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.commonStreamMultiplexer.receivedFrame(frame, context: context, multiplexer:  .legacy(LegacyOutboundStreamMultiplexer(multiplexer: self)))
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        switch self.commonStreamMultiplexer.propagateReadComplete() {
        case .flushNow:
            context.flush()
        case .noop:
            break
        }

        context.fireChannelReadComplete()
    }

    public func flush(context: ChannelHandlerContext) {
        switch self.commonStreamMultiplexer.flushDesired() {
        case .proceed:
            context.flush()
        case .waitForReadsToComplete:
            break // flush will be executed on `channelReadComplete`
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        /* for now just forward */
        context.write(data, promise: promise)
    }

    public func channelActive(context: ChannelHandlerContext) {
        // We just got channelActive. Any previously existing channels may be marked active.
        self.commonStreamMultiplexer.propagateChannelActive(context: context)

        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.commonStreamMultiplexer.propagateChannelInactive()

        context.fireChannelInactive()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as StreamClosedEvent:
            _ = self.commonStreamMultiplexer.streamClosed(event: evt)
        case let evt as NIOHTTP2WindowUpdatedEvent where evt.streamID == .rootStream:
            // This force-unwrap is safe: we always have a connection window.
            self.newConnectionWindowSize(newSize: evt.inboundWindowSize!, context: context)
        case let evt as NIOHTTP2WindowUpdatedEvent:
            self.commonStreamMultiplexer.childStreamWindowUpdated(event: evt)
        case let evt as NIOHTTP2BulkStreamWindowChangeEvent:
            self.commonStreamMultiplexer.initialStreamWindowChanged(event: evt)
        case let evt as NIOHTTP2StreamCreatedEvent:
            _ = self.commonStreamMultiplexer.streamCreated(event: evt)
        default:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.commonStreamMultiplexer.propagateChannelWritabilityChanged(context: context)

        context.fireChannelWritabilityChanged()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let streamError = error as? NIOHTTP2Errors.StreamError {
            self.commonStreamMultiplexer.streamError(context: context, streamError)
        }
        context.fireErrorCaught(error)
    }

    private func newConnectionWindowSize(newSize: Int, context: ChannelHandlerContext) {
        guard let increment = self.commonStreamMultiplexer.newConnectionWindowSize(newSize) else {
            return
        }

        // This is too much flushing, but for now it'll have to do.
        let frame = HTTP2Frame(streamID: .rootStream, payload: .windowUpdate(windowSizeIncrement: increment))
        context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
    }

    /// Create a new ``HTTP2StreamMultiplexer``.
    ///
    /// - Parameters:
    ///   - mode: The mode of the HTTP/2 connection being used: server or client.
    ///   - channel: The Channel to which this ``HTTP2StreamMultiplexer`` belongs.
    ///   - targetWindowSize: The target inbound connection and stream window size. Defaults to 65535 bytes.
    ///   - inboundStreamStateInitializer: A block that will be invoked to configure each new child stream
    ///         channel that is created by the remote peer. For servers, these are channels created by
    ///         receiving a `HEADERS` frame from a client. For clients, these are channels created by
    ///         receiving a `PUSH_PROMISE` frame from a server. To initiate a new outbound channel, use
    ///         ``createStreamChannel(promise:_:)-1jk0q``.
    @available(*, deprecated, renamed: "init(mode:channel:targetWindowSize:outboundBufferSizeHighWatermark:outboundBufferSizeLowWatermark:inboundStreamInitializer:)")
    public convenience init(mode: NIOHTTP2Handler.ParserMode, channel: Channel, targetWindowSize: Int = 65535, inboundStreamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)? = nil) {
        // We default to an 8kB outbound buffer size: this is a good trade off for avoiding excessive buffering while ensuring that decent
        // throughput can be maintained. We use 4kB as the low water mark.
        self.init(mode: mode,
                  channel: channel,
                  targetWindowSize: targetWindowSize,
                  outboundBufferSizeHighWatermark: 8192,
                  outboundBufferSizeLowWatermark: 4096,
                  inboundStreamStateInitializer: .includesStreamID(inboundStreamStateInitializer))
    }

    /// Create a new ``HTTP2StreamMultiplexer``.
    ///
    /// - Parameters:
    ///   - mode: The mode of the HTTP/2 connection being used: server or client.
    ///   - channel: The Channel to which this ``HTTP2StreamMultiplexer`` belongs.
    ///   - targetWindowSize: The target inbound connection and stream window size. Defaults to 65535 bytes.
    ///   - outboundBufferSizeHighWatermark: The high watermark for the number of bytes of writes that are
    ///         allowed to be un-sent on any child stream. This is broadly analogous to a regular socket send buffer.
    ///         Defaults to 8196 bytes.
    ///   - outboundBufferSizeLowWatermark: The low watermark for the number of bytes of writes that are
    ///         allowed to be un-sent on any child stream. This is broadly analogous to a regular socket send buffer.
    ///         Defaults to 4092 bytes.
    ///   - inboundStreamInitializer: A block that will be invoked to configure each new child stream
    ///         channel that is created by the remote peer. For servers, these are channels created by
    ///         receiving a `HEADERS` frame from a client. For clients, these are channels created by
    ///         receiving a `PUSH_PROMISE` frame from a server. To initiate a new outbound channel, use
    ///         ``createStreamChannel(promise:_:)-1jk0q``.
    public convenience init(mode: NIOHTTP2Handler.ParserMode,
                            channel: Channel,
                            targetWindowSize: Int = 65535,
                            outboundBufferSizeHighWatermark: Int = 8196,
                            outboundBufferSizeLowWatermark: Int = 4092,
                            inboundStreamInitializer: ((Channel) -> EventLoopFuture<Void>)?) {
        self.init(mode: mode,
                  channel: channel,
                  targetWindowSize: targetWindowSize,
                  outboundBufferSizeHighWatermark: outboundBufferSizeHighWatermark,
                  outboundBufferSizeLowWatermark: outboundBufferSizeLowWatermark,
                  inboundStreamStateInitializer: .excludesStreamID(inboundStreamInitializer))
    }

    /// Create a new ``HTTP2StreamMultiplexer``.
    ///
    /// - Parameters:
    ///   - mode: The mode of the HTTP/2 connection being used: server or client.
    ///   - channel: The Channel to which this `HTTP2StreamMultiplexer` belongs.
    ///   - targetWindowSize: The target inbound connection and stream window size. Defaults to 65535 bytes.
    ///   - outboundBufferSizeHighWatermark: The high watermark for the number of bytes of writes that are
    ///         allowed to be un-sent on any child stream. This is broadly analogous to a regular socket send buffer.
    ///   - outboundBufferSizeLowWatermark: The low watermark for the number of bytes of writes that are
    ///         allowed to be un-sent on any child stream. This is broadly analogous to a regular socket send buffer.
    ///   - inboundStreamStateInitializer: A block that will be invoked to configure each new child stream
    ///         channel that is created by the remote peer. For servers, these are channels created by
    ///         receiving a `HEADERS` frame from a client. For clients, these are channels created by
    ///         receiving a `PUSH_PROMISE` frame from a server. To initiate a new outbound channel, use
    ///         ``createStreamChannel(promise:_:)-1jk0q``.
    @available(*, deprecated, renamed: "init(mode:channel:targetWindowSize:outboundBufferSizeHighWatermark:outboundBufferSizeLowWatermark:inboundStreamInitializer:)")
    public convenience init(mode: NIOHTTP2Handler.ParserMode,
                            channel: Channel,
                            targetWindowSize: Int = 65535,
                            outboundBufferSizeHighWatermark: Int,
                            outboundBufferSizeLowWatermark: Int,
                            inboundStreamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)? = nil) {
        self.init(mode: mode,
                  channel: channel,
                  targetWindowSize: targetWindowSize,
                  outboundBufferSizeHighWatermark: outboundBufferSizeHighWatermark,
                  outboundBufferSizeLowWatermark: outboundBufferSizeLowWatermark,
                  inboundStreamStateInitializer: .includesStreamID(inboundStreamStateInitializer))
    }

    private init(mode: NIOHTTP2Handler.ParserMode,
                 channel: Channel,
                 targetWindowSize: Int = 65535,
                 outboundBufferSizeHighWatermark: Int,
                 outboundBufferSizeLowWatermark: Int,
                 inboundStreamStateInitializer: MultiplexerAbstractChannel.InboundStreamStateInitializer) {
        self.channel = channel

        self.commonStreamMultiplexer = HTTP2CommonInboundStreamMultiplexer(
            mode: mode,
            channel: channel,
            inboundStreamStateInitializer: inboundStreamStateInitializer,
            targetWindowSize: targetWindowSize,
            streamChannelOutboundBytesHighWatermark: outboundBufferSizeHighWatermark,
            streamChannelOutboundBytesLowWatermark: outboundBufferSizeLowWatermark
        )
    }
}



extension HTTP2StreamMultiplexer {
    /// Create a new `Channel` for a new stream initiated by this peer.
    ///
    /// This method is intended for situations where the NIO application is initiating the stream. For clients,
    /// this is for all request streams. For servers, this is for pushed streams.
    ///
    /// > Note: Resources for the stream will be freed after it has been closed.
    ///
    /// - Parameters:
    ///   - promise: An `EventLoopPromise` that will be succeeded with the new activated channel, or
    ///         failed if an error occurs.
    ///   - streamStateInitializer: A callback that will be invoked to allow you to configure the
    ///         `ChannelPipeline` for the newly created channel.
    public func createStreamChannel(promise: EventLoopPromise<Channel>?, _ streamStateInitializer: @escaping NIOChannelInitializer) {
        self.commonStreamMultiplexer.createStreamChannel(multiplexer: .legacy(LegacyOutboundStreamMultiplexer(multiplexer: self)), promise: promise, streamStateInitializer)
    }

    /// Create a new `Channel` for a new stream initiated by this peer.
    ///
    /// This method is intended for situations where the NIO application is initiating the stream. For clients,
    /// this is for all request streams. For servers, this is for pushed streams.
    ///
    /// > Note: Resources for the stream will be freed after it has been closed.
    ///
    /// - Parameters:
    ///   - promise: An `EventLoopPromise` that will be succeeded with the new activated channel, or
    ///         failed if an error occurs.
    ///   - streamStateInitializer: A callback that will be invoked to allow you to configure the
    ///         `ChannelPipeline` for the newly created channel.
    @available(*, deprecated, message: "The signature of 'streamStateInitializer' has changed to '(Channel) -> EventLoopFuture<Void>'")
    public func createStreamChannel(promise: EventLoopPromise<Channel>?, _ streamStateInitializer: @escaping (Channel, HTTP2StreamID) -> EventLoopFuture<Void>) {
        self.commonStreamMultiplexer.createStreamChannel(multiplexer: .legacy(LegacyOutboundStreamMultiplexer(multiplexer: self)), promise: promise, streamStateInitializer)
    }
}


// MARK:- Child to parent calls
extension HTTP2StreamMultiplexer {
    internal func childChannelClosed(streamID: HTTP2StreamID) {
        self.commonStreamMultiplexer.childChannelClosed(streamID: streamID)
    }

    internal func childChannelClosed(channelID: ObjectIdentifier) {
        self.commonStreamMultiplexer.childChannelClosed(channelID: channelID)
    }

    internal func childChannelWrite(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        self.context.write(self.wrapOutboundOut(frame), promise: promise)
    }

    internal func childChannelFlush() {
        self.flush(context: self.context)
    }

    /// Requests a ``HTTP2StreamID`` for the given `Channel`.
    ///
    /// - Precondition: The `channel` must not already have a `streamID`.
    internal func requestStreamID(forChannel channel: Channel) -> HTTP2StreamID {
        self.commonStreamMultiplexer.requestStreamID(forChannel: channel)
    }
}
