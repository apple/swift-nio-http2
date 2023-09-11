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

import NIOCore

/// Represents the common multiplexing machinery used by both legacy ``HTTP2StreamMultiplexer`` and new ``InlineStreamMultiplexer`` inbound stream multiplexing.
internal class HTTP2CommonInboundStreamMultiplexer {
    private let channel: Channel

    // NOTE: All state below should only be modified from the `EventLoop` of the supplied `Channel`

    // Streams which have a stream ID.
    private var streams: [HTTP2StreamID: MultiplexerAbstractChannel] = [:]
    // Streams which don't yet have a stream ID assigned to them.
    private var pendingStreams: [ObjectIdentifier: MultiplexerAbstractChannel] = [:]
    private var didReadChannels: StreamChannelList = StreamChannelList()
    private var nextOutboundStreamID: HTTP2StreamID
    private let inboundStreamStateInitializer: MultiplexerAbstractChannel.InboundStreamStateInitializer

    private var connectionFlowControlManager: InboundWindowManager

    private let mode: NIOHTTP2Handler.ParserMode
    private let targetWindowSize: Int
    private let streamChannelOutboundBytesHighWatermark: Int
    private let streamChannelOutboundBytesLowWatermark: Int

    private var isReading = false
    private var flushPending = false

    var streamChannelContinuation: (any AnyContinuation)?

    init(
        mode: NIOHTTP2Handler.ParserMode,
        channel: Channel,
        inboundStreamStateInitializer: MultiplexerAbstractChannel.InboundStreamStateInitializer,
        targetWindowSize: Int,
        streamChannelOutboundBytesHighWatermark: Int,
        streamChannelOutboundBytesLowWatermark: Int
    ) {
        self.channel = channel
        self.inboundStreamStateInitializer = inboundStreamStateInitializer
        self.targetWindowSize = targetWindowSize
        self.connectionFlowControlManager = InboundWindowManager(targetSize: Int32(targetWindowSize))
        self.streamChannelOutboundBytesHighWatermark = streamChannelOutboundBytesHighWatermark
        self.streamChannelOutboundBytesLowWatermark = streamChannelOutboundBytesLowWatermark
        self.mode = mode
        switch mode {
        case .client:
            self.nextOutboundStreamID = 1
        case .server:
            self.nextOutboundStreamID = 2
        }
    }
}

// MARK:- inbound multiplexer functions
// note this is intentionally not bound to `HTTP2InboundStreamMultiplexer` to allow for freedom in modifying the shared driver function signatures
extension HTTP2CommonInboundStreamMultiplexer {
    func receivedFrame(_ frame: HTTP2Frame, context: ChannelHandlerContext, multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer) {
        self.channel.eventLoop.preconditionInEventLoop()

        self.isReading = true
        let streamID = frame.streamID
        if streamID == .rootStream {
            // For stream 0 we forward all frames on to the main channel.
            context.fireChannelRead(NIOAny(frame))
            return
        }

        if case .priority = frame.payload {
            // Priority frames are special cases, and are always forwarded to the parent stream.
            context.fireChannelRead(NIOAny(frame))
            return
        }

        if let channel = self.streams[streamID] {
            channel.receiveInboundFrame(frame)
            if !channel.inList {
                self.didReadChannels.append(channel)
            }
        } else if case .headers = frame.payload {
            let channel = MultiplexerAbstractChannel(
                allocator: self.channel.allocator,
                parent: self.channel,
                multiplexer: multiplexer,
                streamID: streamID,
                targetWindowSize: Int32(self.targetWindowSize),
                outboundBytesHighWatermark: self.streamChannelOutboundBytesHighWatermark,
                outboundBytesLowWatermark: self.streamChannelOutboundBytesLowWatermark,
                inboundStreamStateInitializer: self.inboundStreamStateInitializer
            )

            self.streams[streamID] = channel

            // Note: Firing the initial (header) frame before calling `HTTP2StreamChannel.configureInboundStream(initializer:)`
            // is crucial to preserve frame order, since the initialization process might trigger another read on the parent
            // channel which in turn might cause further frames to be processed synchronously.
            channel.receiveInboundFrame(frame)

            // Configure the inbound stream.
            // If we have an async sequence of inbound stream channels yield the channel to it
            // but only once we are sure initialization and activation succeed
            if let streamChannelContinuation = self.streamChannelContinuation {
                let promise = self.channel.eventLoop.makePromise(of: Any.self)
                promise.futureResult.whenSuccess { value in
                    streamChannelContinuation.yield(any: value)
                }

                channel.configureInboundStream(initializer: self.inboundStreamStateInitializer, promise: promise)
            } else {
                channel.configureInboundStream(initializer: self.inboundStreamStateInitializer)
            }

            if !channel.inList {
                self.didReadChannels.append(channel)
            }
        } else {
            // This frame is for a stream we know nothing about. We can't do much about it, so we
            // are going to fire an error and drop the frame.
            let error = NIOHTTP2Errors.noSuchStream(streamID: streamID)
            context.fireErrorCaught(error)
        }
    }

    func streamError(context: ChannelHandlerContext, _ streamError: NIOHTTP2Errors.StreamError) {
        self.channel.eventLoop.preconditionInEventLoop()
        self.streams[streamError.streamID]?.receiveStreamError(streamError)
        context.fireErrorCaught(streamError.baseError)
    }

    func streamCreated(event: NIOHTTP2StreamCreatedEvent) -> Channel? {
        self.channel.eventLoop.preconditionInEventLoop()
        if let channel = self.streams[event.streamID] {
            channel.networkActivationReceived()
            return channel.baseChannel
        }
        return nil
    }

    func streamClosed(event: StreamClosedEvent) -> Channel? {
        self.channel.eventLoop.preconditionInEventLoop()
        if let channel = self.streams[event.streamID] {
            channel.receiveStreamClosed(event.reason)
            return channel.baseChannel
        }
        return nil
    }

    func newConnectionWindowSize(_ newSize: Int) -> Int? {
        self.channel.eventLoop.preconditionInEventLoop()
        return self.connectionFlowControlManager.newWindowSize(newSize)
    }

    func childStreamWindowUpdated(event: NIOHTTP2WindowUpdatedEvent) {
        self.channel.eventLoop.preconditionInEventLoop()
        precondition(event.streamID != .rootStream, "not to be called on the root stream")

        if let windowSize = event.inboundWindowSize {
            self.streams[event.streamID]?.receiveWindowUpdatedEvent(windowSize)
        }
    }

    func initialStreamWindowChanged(event: NIOHTTP2BulkStreamWindowChangeEvent) {
        // Here we need to pull the channels out so we aren't holding the streams dict mutably. This is because it
        // will trigger an overlapping access violation if we do.
        let channels = self.streams.values
        for channel in channels {
            channel.initialWindowSizeChanged(delta: event.delta)
        }
    }
}

extension HTTP2CommonInboundStreamMultiplexer {
    internal func propagateChannelActive(context: ChannelHandlerContext) {
        // We double-check the channel activity here, because it's possible action taken during
        // the activation of one of the child channels will cause the parent to close!
        for channel in self.streams.values {
            if context.channel.isActive {
                channel.performActivation()
            }
        }
        for channel in self.pendingStreams.values {
            if context.channel.isActive {
                channel.performActivation()
            }
        }
    }

    internal func propagateChannelInactive() {
        for channel in self.streams.values {
            channel.receiveStreamClosed(nil)
        }
        for channel in self.pendingStreams.values {
            channel.receiveStreamClosed(nil)
        }
        // there cannot be any more inbound streams now that the connection channel is inactive
        self.streamChannelContinuation?.finish()
    }

    internal func propagateChannelWritabilityChanged(context: ChannelHandlerContext) {
        for channel in self.streams.values {
            channel.parentChannelWritabilityChanged(newValue: context.channel.isWritable)
        }
        for channel in self.pendingStreams.values {
            channel.parentChannelWritabilityChanged(newValue: context.channel.isWritable)
        }
    }

    enum ReadFlushNeeded {
        case flushNow
        case noop
    }

    /// returns `.flushPending` if there was a flush pending which may now be performed
    internal func propagateReadComplete() -> ReadFlushNeeded {
        // Call channelReadComplete on the children until this has been propagated enough.
        while let channel = self.didReadChannels.removeFirst() {
            channel.receiveParentChannelReadComplete()
        }

        // stash the state before clearing
        let readFlushNeeded: ReadFlushNeeded = self.flushPending ? .flushNow : .noop

        self.isReading = false
        self.flushPending = false

        return readFlushNeeded
    }

    enum ReadFlushCoalescingState {
        case waitForReadsToComplete
        case proceed
    }

    /// Communicates the intention to flush
    internal func flushDesired() -> ReadFlushCoalescingState {
        if self.isReading {
            self.flushPending = true
            return .waitForReadsToComplete
        }
        return .proceed
    }

    internal func clearDidReadChannels() {
        self.didReadChannels.removeAll()
    }
}

// MARK:- Child to parent calls
extension HTTP2CommonInboundStreamMultiplexer {
    internal func childChannelClosed(streamID: HTTP2StreamID) {
        self.streams.removeValue(forKey: streamID)
    }

    internal func childChannelClosed(channelID: ObjectIdentifier) {
        self.pendingStreams.removeValue(forKey: channelID)
    }

    /// Requests a ``HTTP2StreamID`` for the given `Channel`.
    ///
    /// - Precondition: The `channel` must not already have a `streamID`.
    internal func requestStreamID(forChannel channel: Channel) -> HTTP2StreamID {
        let channelID = ObjectIdentifier(channel)

        // This unwrap shouldn't fail: the multiplexer owns the stream and the stream only requests
        // a streamID once.
        guard let abstractChannel = self.pendingStreams.removeValue(forKey: channelID) else {
            preconditionFailure("No pending streams have channelID \(channelID)")
        }
        assert(abstractChannel.channelID == channelID)

        let streamID = self.nextStreamID()
        self.streams[streamID] = abstractChannel
        return streamID
    }

    private func nextStreamID() -> HTTP2StreamID {
        let streamID = self.nextOutboundStreamID
        self.nextOutboundStreamID = HTTP2StreamID(Int32(streamID) + 2)
        return streamID
    }
}

extension HTTP2CommonInboundStreamMultiplexer {
    internal func _createStreamChannel<Output: Sendable>(
        _ multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        _ promise: EventLoopPromise<Output>?,
        _ streamStateInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) {
        self.channel.eventLoop.assertInEventLoop()

        let channel = MultiplexerAbstractChannel(
            allocator: self.channel.allocator,
            parent: self.channel,
            multiplexer: multiplexer,
            streamID: nil,
            targetWindowSize: Int32(self.targetWindowSize),
            outboundBytesHighWatermark: self.streamChannelOutboundBytesHighWatermark,
            outboundBytesLowWatermark: self.streamChannelOutboundBytesLowWatermark,
            inboundStreamStateInitializer: .excludesStreamID(nil)
        )
        self.pendingStreams[channel.channelID] = channel

        let anyInitializer: NIOChannelInitializerWithOutput<any Sendable> = { channel in
            streamStateInitializer(channel).map { return $0 }
        }

        let anyPromise: EventLoopPromise<Any>?
        if let promise = promise {
            anyPromise = channel.baseChannel.eventLoop.makePromise(of: Any.self)
            anyPromise?.futureResult.whenComplete { result in
                switch result {
                case .success(let any):
                    // The cast through any here is unfortunate but the only way to make this work right now
                    // since the HTTP2ChildChannel and the multiplexer is not generic over the output of the initializer.
                    promise.succeed(any as! Output)
                case .failure(let error):
                    promise.fail(error)
                }
            }
        } else {
            anyPromise = nil
        }

        channel.configure(initializer: anyInitializer, userPromise: anyPromise)
    }

    internal func createStreamChannel<Output: Sendable>(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        promise: EventLoopPromise<Output>?,
        _ streamStateInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) {
        // Always create streams channels on the next event loop tick. This avoids re-entrancy
        // issues where handlers interposed between the two HTTP/2 handlers could create streams
        // in channel active which become activated twice.
        self.channel.eventLoop.execute {
            self._createStreamChannel(multiplexer, promise, streamStateInitializer)
        }
    }

    internal func createStreamChannel<Output: Sendable>(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        _ streamStateInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) -> EventLoopFuture<Output> {
        let promise = self.channel.eventLoop.makePromise(of: Output.self)
        self.createStreamChannel(multiplexer: multiplexer, promise: promise, streamStateInitializer)
        return promise.futureResult
    }

    internal func _createStreamChannel(
        _ multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        _ promise: EventLoopPromise<Channel>?,
        _ streamStateInitializer: @escaping NIOChannelInitializer
    ) {
        let channel = MultiplexerAbstractChannel(
            allocator: self.channel.allocator,
            parent: self.channel,
            multiplexer: multiplexer,
            streamID: nil,
            targetWindowSize: Int32(self.targetWindowSize),
            outboundBytesHighWatermark: self.streamChannelOutboundBytesHighWatermark,
            outboundBytesLowWatermark: self.streamChannelOutboundBytesLowWatermark,
            inboundStreamStateInitializer: .excludesStreamID(nil)
        )
        self.pendingStreams[channel.channelID] = channel

        channel.configure(initializer: streamStateInitializer, userPromise: promise)
    }

    internal func createStreamChannel(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        promise: EventLoopPromise<Channel>?,
        _ streamStateInitializer: @escaping NIOChannelInitializer
    ) {
        // Always create streams channels on the next event loop tick. This avoids re-entrancy
        // issues where handlers interposed between the two HTTP/2 handlers could create streams
        // in channel active which become activated twice.
        self.channel.eventLoop.execute {
            self._createStreamChannel(multiplexer, promise, streamStateInitializer)
        }
    }

    internal func createStreamChannel(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        _ streamStateInitializer: @escaping NIOChannelInitializer) -> EventLoopFuture<Channel> {
        let promise = self.channel.eventLoop.makePromise(of: Channel.self)
        self.createStreamChannel(multiplexer: multiplexer, promise: promise, streamStateInitializer)
        return promise.futureResult
    }

    @available(*, deprecated, message: "The signature of 'streamStateInitializer' has changed to '(Channel) -> EventLoopFuture<Void>'")
    internal func createStreamChannel(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        promise: EventLoopPromise<Channel>?,
        _ streamStateInitializer: @escaping (Channel, HTTP2StreamID) -> EventLoopFuture<Void>
    ) {
        self.channel.eventLoop.execute {
            let streamID = self.nextStreamID()
            let channel = MultiplexerAbstractChannel(
                allocator: self.channel.allocator,
                parent: self.channel,
                multiplexer: multiplexer,
                streamID: streamID,
                targetWindowSize: Int32(self.targetWindowSize),
                outboundBytesHighWatermark: self.streamChannelOutboundBytesHighWatermark,
                outboundBytesLowWatermark: self.streamChannelOutboundBytesLowWatermark,
                inboundStreamStateInitializer: .includesStreamID(nil)
            )
            self.streams[streamID] = channel
            channel.configure(initializer: streamStateInitializer, userPromise: promise)
        }
    }
}

extension HTTP2CommonInboundStreamMultiplexer {
    /// Mark the bytes as written
    ///
    /// > This is only to be called from the inline multiplexer
    ///
    /// Mark bytes as written in the `HTTP2StreamChannel` writability manager directly, as used by the inline stream multiplexer.
    /// This is taken care of separately via a promise in the legacy case.
    internal func processedFrame(streamID: HTTP2StreamID, size: Int) {
        if let channel = self.streams[streamID] {
            channel.wroteBytes(size)
        }
    }
}

extension HTTP2CommonInboundStreamMultiplexer {
    func setChannelContinuation(_ streamChannels: any AnyContinuation) {
        self.channel.eventLoop.assertInEventLoop()
        self.streamChannelContinuation = streamChannels
    }
}

/// `ChannelContinuation` is used to generic async-sequence-like objects to deal with `Channel`s. This is so that they may be held
/// by the `HTTP2ChannelHandler` without causing it to become generic itself.
internal protocol AnyContinuation {
    func yield(any: Any)
    func finish()
    func finish(throwing error: Error)
}


/// `NIOHTTP2InboundStreamChannels` provides access to inbound stream channels as a generic `AsyncSequence`.
/// They make use of generics to allow for wrapping the stream `Channel`s, for example as `NIOAsyncChannel`s or protocol negotiation objects.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@_spi(AsyncChannel)
public struct NIOHTTP2InboundStreamChannels<Output>: AsyncSequence {
    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = Output

        private var iterator: AsyncThrowingStream<Output, Error>.AsyncIterator

        init(_ iterator: AsyncThrowingStream<Output, Error>.AsyncIterator) {
            self.iterator = iterator
        }

        public mutating func next() async throws -> Output? {
            try await self.iterator.next()
        }
    }

    public typealias Element = Output

    private let asyncThrowingStream: AsyncThrowingStream<Output, Error>

    private init(_ asyncThrowingStream: AsyncThrowingStream<Output, Error>) {
        self.asyncThrowingStream = asyncThrowingStream
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(self.asyncThrowingStream.makeAsyncIterator())
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOHTTP2InboundStreamChannels {
    /// `Continuation` is a wrapper for a generic `AsyncThrowingStream` to which inbound HTTP2 stream channels are yielded..
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    struct Continuation: AnyContinuation {
        private var continuation: AsyncThrowingStream<Output, Error>.Continuation

        internal init(
            continuation: AsyncThrowingStream<Output, Error>.Continuation
        ) {
            self.continuation = continuation
        }

        /// `yield` takes a channel as outputted by the stream initializer and yields the wrapped `AsyncThrowingStream`.
        ///
        /// It takes channels as as `Any` type to allow wrapping by the stream initializer.
        func yield(any: Any) {
            let yieldResult = self.continuation.yield(any as! Output)
                switch yieldResult {
                case .enqueued:
                    break // success, nothing to do
                case .dropped:
                    preconditionFailure("Attempted to yield when AsyncThrowingStream is over capacity. This shouldn't be possible for an unbounded stream.")
                case .terminated:
                    preconditionFailure("Attempted to yield to AsyncThrowingStream in terminated state.")
                default:
                    preconditionFailure("Attempt to yield to AsyncThrowingStream failed for unhandled reason.")
                }
        }

        /// `finish` marks the continuation as finished.
        func finish() {
            self.continuation.finish()
        }

        /// `finish` marks the continuation as finished with the supplied error.
        func finish(throwing error: Error) {
            self.continuation.finish(throwing: error)
        }
    }


    /// `initialize` creates a new `Continuation` object and returns it along with its backing `AsyncThrowingStream`.
    /// The `StreamChannelContinuation` provides access to the inbound HTTP2 stream channels.
    ///
    /// - Parameters:
    ///   - inboundStreamInititializer: A closure which initializes the newly-created inbound stream channel and returns a generic.
    ///   The returned type corresponds to the output of the channel once the operations in the initializer have been performed.
    ///   For example an `inboundStreamInititializer` which inserts handlers before wrapping the channel in a `NIOAsyncChannel` would
    ///   have a `Output` corresponding to that `NIOAsyncChannel` type. Another example is in cases where there is
    ///   per-stream protocol negotiation where `Output` would be some form of `NIOProtocolNegotiationResult`.
    static func initialize(inboundStreamInitializerOutput: Output.Type = Output.self) -> (NIOHTTP2InboundStreamChannels<Output>, Continuation) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Output.self)
        return (.init(stream), Continuation(continuation: continuation))
    }
}

#if swift(>=5.7)
// This doesn't compile on 5.6 but the omission of Sendable is sufficient in any case
@available(*, unavailable)
extension NIOHTTP2InboundStreamChannels.AsyncIterator: Sendable {}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOHTTP2InboundStreamChannels: Sendable where Output: Sendable {}
#else
// This wasn't marked as sendable in 5.6 however it should be fine
// https://forums.swift.org/t/so-is-asyncstream-sendable-or-not/53148/2
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOHTTP2InboundStreamChannels: @unchecked Sendable where Output: Sendable {}
#endif


#if swift(<5.9)
// this should be available in the std lib from 5.9 onwards
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncThrowingStream {
    public static func makeStream(
        of elementType: Element.Type = Element.self,
        throwing failureType: Failure.Type = Failure.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncThrowingStream<Element, Failure>, continuation: AsyncThrowingStream<Element, Failure>.Continuation) where Failure == Error {
        var continuation: AsyncThrowingStream<Element, Failure>.Continuation!
        let stream = AsyncThrowingStream<Element, Failure>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}
#endif
