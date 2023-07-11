//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@_spi(AsyncChannel) import NIOCore

internal struct InlineStreamMultiplexer {
    private let context: ChannelHandlerContext

    private let commonStreamMultiplexer: HTTP2CommonInboundStreamMultiplexer
    private let outboundView: NIOHTTP2Handler.OutboundView

    /// The delegate to be notified upon stream creation and close.
    private var streamDelegate: NIOHTTP2StreamDelegate?

    init(context: ChannelHandlerContext, outboundView: NIOHTTP2Handler.OutboundView, mode: NIOHTTP2Handler.ParserMode, inboundStreamStateInitializer: MultiplexerAbstractChannel.InboundStreamStateInitializer, targetWindowSize: Int, streamChannelOutboundBytesHighWatermark: Int, streamChannelOutboundBytesLowWatermark: Int, streamDelegate: NIOHTTP2StreamDelegate?) {
        self.context = context
        self.commonStreamMultiplexer = HTTP2CommonInboundStreamMultiplexer(
            mode: mode,
            channel: context.channel,
            inboundStreamStateInitializer: inboundStreamStateInitializer,
            targetWindowSize: targetWindowSize,
            streamChannelOutboundBytesHighWatermark: streamChannelOutboundBytesHighWatermark,
            streamChannelOutboundBytesLowWatermark: streamChannelOutboundBytesLowWatermark
        )
        self.outboundView = outboundView
        self.streamDelegate = streamDelegate
    }
}

extension InlineStreamMultiplexer: HTTP2InboundStreamMultiplexer {
    func receivedFrame(_ frame: HTTP2Frame) {
        self.commonStreamMultiplexer.receivedFrame(frame, context: self.context, multiplexer: .inline(self))
    }

    func streamError(streamID: HTTP2StreamID, error: Error) {
        let streamError = NIOHTTP2Errors.streamError(streamID: streamID, baseError: error)
        self.commonStreamMultiplexer.streamError(context: self.context, streamError)
    }

    func streamCreated(event: NIOHTTP2StreamCreatedEvent) {
        if let childChannel = self.commonStreamMultiplexer.streamCreated(event: event) {
            self.streamDelegate?.streamCreated(event.streamID, channel: childChannel)
        }
    }

    func streamClosed(event: StreamClosedEvent) {
        if let childChannel = self.commonStreamMultiplexer.streamClosed(event: event) {
            self.streamDelegate?.streamClosed(event.streamID, channel: childChannel)
        }
    }

    func streamWindowUpdated(event: NIOHTTP2WindowUpdatedEvent) {
        if event.streamID == .rootStream {
            // This force-unwrap is safe: we always have a connection window.
            self.newConnectionWindowSize(newSize: event.inboundWindowSize!)
        } else {
            self.commonStreamMultiplexer.childStreamWindowUpdated(event: event)
        }
    }

    func initialStreamWindowChanged(event: NIOHTTP2BulkStreamWindowChangeEvent) {
        self.commonStreamMultiplexer.initialStreamWindowChanged(event: event)
    }

    private func newConnectionWindowSize(newSize: Int) {
        guard let increment = self.commonStreamMultiplexer.newConnectionWindowSize(newSize) else {
            return
        }

        let frame = HTTP2Frame(streamID: .rootStream, payload: .windowUpdate(windowSizeIncrement: increment))
        self.writeFrame(frame, promise: nil)
        self.flushStream(frame.streamID)
    }
}

extension InlineStreamMultiplexer: HTTP2OutboundStreamMultiplexer {
    func writeFrame(_ frame: HTTP2Frame, promise: NIOCore.EventLoopPromise<Void>?) {
        self.outboundView.write(context: self.context, frame: frame, promise: promise)
    }

    func flushStream(_ id: HTTP2StreamID) {
        switch self.commonStreamMultiplexer.flushDesired() {
        case .proceed:
            self.outboundView.flush(context: self.context)
        case .waitForReadsToComplete:
            break // flush will be executed on `readComplete`
        }
    }

    func requestStreamID(forChannel channel: NIOCore.Channel) -> HTTP2StreamID {
        self.commonStreamMultiplexer.requestStreamID(forChannel: channel)
    }

    func streamClosed(channelID: ObjectIdentifier) {
        self.commonStreamMultiplexer.childChannelClosed(channelID: channelID)
    }

    func streamClosed(id: HTTP2StreamID) {
        self.commonStreamMultiplexer.childChannelClosed(streamID: id)
    }
}

extension InlineStreamMultiplexer {
    internal func propagateChannelActive() {
        self.commonStreamMultiplexer.propagateChannelActive(context: self.context)
    }

    internal func propagateChannelInactive() {
        self.commonStreamMultiplexer.propagateChannelInactive()
    }

    internal func propagateChannelWritabilityChanged() {
        self.commonStreamMultiplexer.propagateChannelWritabilityChanged(context: self.context)
    }

    internal func propagateReadComplete() {
        switch self.commonStreamMultiplexer.propagateReadComplete() {
        case .flushNow:
            // we had marked a flush as blocked by an active read which we may now perform
            self.outboundView.flush(context: self.context)
        case .noop:
            break
        }
    }

    internal func processedFrame(frame: HTTP2Frame) {
        self.commonStreamMultiplexer.processedFrame(streamID: frame.streamID, size: frame.payload.flowControlledSize)
    }
}

extension InlineStreamMultiplexer {
    internal func createStreamChannel(promise: EventLoopPromise<Channel>?, _ streamStateInitializer: @escaping (Channel) -> EventLoopFuture<Void>) {
        self.commonStreamMultiplexer.createStreamChannel(multiplexer: .inline(self), promise: promise, streamStateInitializer)
    }

    internal func createStreamChannel(_ streamStateInitializer: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        self.commonStreamMultiplexer.createStreamChannel(multiplexer: .inline(self), streamStateInitializer)
    }

    internal func createStreamChannel<Output>(_ initializer: @escaping NIOChannelInitializerWithOutput<Output>) -> EventLoopFuture<Output> {
        self.commonStreamMultiplexer.createStreamChannel(multiplexer: .inline(self), initializer)
    }
}

extension NIOHTTP2Handler {
    /// A multiplexer that creates a child channel for each HTTP/2 stream.
    ///
    /// > Note: This multiplexer is functionally similar to the ``HTTP2StreamMultiplexer`` channel handler, however as it is part of the ``NIOHTTP2Handler`` rather than a separate handler in the pipeline it benefits from efficiencies allowing for higher performance.
    ///
    /// In general in NIO applications it is helpful to consider each HTTP/2 stream as an
    /// independent stream of HTTP/2 frames. This multiplexer achieves this by creating a
    /// number of in-memory `HTTP2StreamChannel` objects, one for each stream. These operate
    /// on ``HTTP2Frame/FramePayload`` objects as their base communication
    /// atom, as opposed to the regular NIO `SelectableChannel` objects which use `ByteBuffer`
    /// and `IOData`.
    public struct StreamMultiplexer: @unchecked Sendable {
        // '@unchecked Sendable' because this state is not intrinsically `Sendable`
        // but it is only accessed in `createStreamChannel` which executes the work on the right event loop
        private let inlineStreamMultiplexer: InlineStreamMultiplexer

        /// Cannot be created by users.
        internal init(_ inlineStreamMultiplexer: InlineStreamMultiplexer) {
            self.inlineStreamMultiplexer = inlineStreamMultiplexer
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
        public func createStreamChannel(promise: EventLoopPromise<Channel>?, _ streamStateInitializer: @escaping StreamInitializer) {
            self.inlineStreamMultiplexer.createStreamChannel(promise: promise, streamStateInitializer)
        }

        /// Create a new `Channel` for a new stream initiated by this peer.
        ///
        /// This method is intended for situations where the NIO application is initiating the stream. For clients,
        /// this is for all request streams. For servers, this is for pushed streams.
        ///
        /// > Note: Resources for the stream will be freed after it has been closed.
        ///
        /// - Parameter streamStateInitializer: A callback that will be invoked to allow you to configure the
        ///         `ChannelPipeline` for the newly created channel.
        /// - Returns: An `EventLoopFuture` containing the created `Channel`, fulfilled after the supplied `streamStateInitializer` has been executed on it.
        public func createStreamChannel(_ streamStateInitializer: @escaping StreamInitializer) -> EventLoopFuture<Channel> {
            self.inlineStreamMultiplexer.createStreamChannel(streamStateInitializer)
        }
    }
}

extension InlineStreamMultiplexer {
    func setChannelContinuation(_ streamChannels: any ChannelContinuation) {
        self.commonStreamMultiplexer.setChannelContinuation(streamChannels)
    }
}

extension NIOHTTP2Handler {
    /// A variant of `NIOHTTP2Handler.StreamMultiplexer` which creates a child channel for each HTTP/2 stream and
    /// provides access to inbound HTTP/2 streams.
    ///
    /// In general in NIO applications it is helpful to consider each HTTP/2 stream as an
    /// independent stream of HTTP/2 frames. This multiplexer achieves this by creating a
    /// number of in-memory `HTTP2StreamChannel` objects, one for each stream. These operate
    /// on ``HTTP2Frame/FramePayload`` objects as their base communication
    /// atom, as opposed to the regular NIO `SelectableChannel` objects which use `ByteBuffer`
    /// and `IOData`.
    ///
    /// Outbound stream channel objects are initialized upon creation using the supplied `streamStateInitializer` which returns a type
    /// `OutboundStreamOutput`. This type may be `HTTP2Frame` or changed to any other type.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    @_spi(AsyncChannel)
    public struct AsyncStreamMultiplexer<InboundStreamOutput> {
        private let inlineStreamMultiplexer: InlineStreamMultiplexer
        public let inbound: NIOHTTP2InboundStreamChannels<InboundStreamOutput>

        // Cannot be created by users.
        internal init(_ inlineStreamMultiplexer: InlineStreamMultiplexer, continuation: any ChannelContinuation, inboundStreamChannels: NIOHTTP2InboundStreamChannels<InboundStreamOutput>) {
            self.inlineStreamMultiplexer = inlineStreamMultiplexer
            self.inlineStreamMultiplexer.setChannelContinuation(continuation)
            self.inbound = inboundStreamChannels
        }

        /// Create a stream channel initialized with the provided closure
        public func createStreamChannel<OutboundStreamOutput>(_ initializer: @escaping NIOChannelInitializerWithOutput<OutboundStreamOutput>) async throws -> OutboundStreamOutput {
            return try await self.inlineStreamMultiplexer.createStreamChannel(initializer).get()
        }


        /// Create a stream channel initialized with the provided closure and return it wrapped within a `NIOAsyncChannel`.
        ///
        /// - Parameters:
        ///   - configuration: Configuration for the ``NIOAsyncChannel`` wrapping the HTTP/2 stream channel.
        ///   - initializer: A callback that will be invoked to allow you to configure the
        ///         `ChannelPipeline` for the newly created channel.
        @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
        @_spi(AsyncChannel)
        public func createStreamChannel<Inbound, Outbound>(
            configuration: NIOAsyncChannel<Inbound, Outbound>.Configuration = .init(),
            initializer: @escaping NIOChannelInitializer
        ) async throws -> NIOAsyncChannel<Inbound, Outbound> {
            return try await self.createStreamChannel { channel in
                initializer(channel).flatMapThrowing { _ in
                    return try NIOAsyncChannel(
                        synchronouslyWrapping: channel,
                        configuration: configuration
                    )
                }
            }
        }
    }
}
