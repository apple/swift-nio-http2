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
@usableFromInline
internal class HTTP2CommonInboundStreamMultiplexer {
    @usableFromInline internal let _channel: Channel

    // NOTE: All state below should only be modified from the `EventLoop` of the supplied `Channel`

    // Streams which have a stream ID.
    private var streams: [HTTP2StreamID: MultiplexerAbstractChannel] = [:]
    // Streams which don't yet have a stream ID assigned to them.
    @usableFromInline internal var _pendingStreams: [ObjectIdentifier: MultiplexerAbstractChannel] = [:]
    private var didReadChannels: StreamChannelList = StreamChannelList()
    private var nextOutboundStreamID: HTTP2StreamID
    private let inboundStreamStateInitializer: MultiplexerAbstractChannel.InboundStreamStateInitializer

    private var connectionFlowControlManager: InboundWindowManager

    private let mode: NIOHTTP2Handler.ParserMode
    @usableFromInline internal let _targetWindowSize: Int
    @usableFromInline internal let _streamChannelOutboundBytesHighWatermark: Int
    @usableFromInline internal let _streamChannelOutboundBytesLowWatermark: Int

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
        self._channel = channel
        self.inboundStreamStateInitializer = inboundStreamStateInitializer
        self._targetWindowSize = targetWindowSize
        self.connectionFlowControlManager = InboundWindowManager(targetSize: Int32(targetWindowSize))
        self._streamChannelOutboundBytesHighWatermark = streamChannelOutboundBytesHighWatermark
        self._streamChannelOutboundBytesLowWatermark = streamChannelOutboundBytesLowWatermark
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
        self._channel.eventLoop.preconditionInEventLoop()

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
                allocator: self._channel.allocator,
                parent: self._channel,
                multiplexer: multiplexer,
                streamID: streamID,
                targetWindowSize: Int32(self._targetWindowSize),
                outboundBytesHighWatermark: self._streamChannelOutboundBytesHighWatermark,
                outboundBytesLowWatermark: self._streamChannelOutboundBytesLowWatermark,
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
                let promise = self._channel.eventLoop.makePromise(of: (any Sendable).self)
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
        self._channel.eventLoop.preconditionInEventLoop()
        self.streams[streamError.streamID]?.receiveStreamError(streamError)
        context.fireErrorCaught(streamError.baseError)
    }

    func streamCreated(event: NIOHTTP2StreamCreatedEvent) -> Channel? {
        self._channel.eventLoop.preconditionInEventLoop()
        if let channel = self.streams[event.streamID] {
            channel.networkActivationReceived()
            return channel.baseChannel
        }
        return nil
    }

    func streamClosed(event: StreamClosedEvent) -> Channel? {
        self._channel.eventLoop.preconditionInEventLoop()
        if let channel = self.streams[event.streamID] {
            channel.receiveStreamClosed(event.reason)
            return channel.baseChannel
        }
        return nil
    }

    func newConnectionWindowSize(_ newSize: Int) -> Int? {
        self._channel.eventLoop.preconditionInEventLoop()
        return self.connectionFlowControlManager.newWindowSize(newSize)
    }

    func childStreamWindowUpdated(event: NIOHTTP2WindowUpdatedEvent) {
        self._channel.eventLoop.preconditionInEventLoop()
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
        for channel in self._pendingStreams.values {
            if context.channel.isActive {
                channel.performActivation()
            }
        }
    }

    internal func propagateChannelInactive() {
        for channel in self.streams.values {
            channel.receiveStreamClosed(nil)
        }
        for channel in self._pendingStreams.values {
            channel.receiveStreamClosed(nil)
        }
        // there cannot be any more inbound streams now that the connection channel is inactive
        self.streamChannelContinuation?.finish()
    }

    internal func propagateChannelWritabilityChanged(context: ChannelHandlerContext) {
        for channel in self.streams.values {
            channel.parentChannelWritabilityChanged(newValue: context.channel.isWritable)
        }
        for channel in self._pendingStreams.values {
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
        self._pendingStreams.removeValue(forKey: channelID)
    }

    /// Requests a ``HTTP2StreamID`` for the given `Channel`.
    ///
    /// - Precondition: The `channel` must not already have a `streamID`.
    internal func requestStreamID(forChannel channel: Channel) -> HTTP2StreamID {
        let channelID = ObjectIdentifier(channel)

        // This unwrap shouldn't fail: the multiplexer owns the stream and the stream only requests
        // a streamID once.
        guard let abstractChannel = self._pendingStreams.removeValue(forKey: channelID) else {
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
    @inlinable
    internal func createStreamChannel<Output: Sendable>(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        promise: EventLoopPromise<Output>?,
        _ streamStateInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) {
        self._channel.eventLoop.assertInEventLoop()

        let channel = MultiplexerAbstractChannel(
            allocator: self._channel.allocator,
            parent: self._channel,
            multiplexer: multiplexer,
            streamID: nil,
            targetWindowSize: Int32(self._targetWindowSize),
            outboundBytesHighWatermark: self._streamChannelOutboundBytesHighWatermark,
            outboundBytesLowWatermark: self._streamChannelOutboundBytesLowWatermark,
            inboundStreamStateInitializer: .excludesStreamID(nil)
        )
        self._pendingStreams[channel.channelID] = channel

        let anyInitializer: NIOChannelInitializerWithOutput<any Sendable> = { channel in
            streamStateInitializer(channel).map { return $0 }
        }

        let anyPromise: EventLoopPromise<(any Sendable)>?
        if let promise = promise {
            anyPromise = channel.baseChannel.eventLoop.makePromise(of: (any Sendable).self)
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

    @inlinable
    internal func createStreamChannel<Output: Sendable>(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        _ streamStateInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) -> EventLoopFuture<Output> {
        let promise = self._channel.eventLoop.makePromise(of: Output.self)
        self.createStreamChannel(multiplexer: multiplexer, promise: promise, streamStateInitializer)
        return promise.futureResult
    }

    internal func createStreamChannel(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        promise: EventLoopPromise<Channel>?,
        _ streamStateInitializer: @escaping NIOChannelInitializer
    ) {
        self._channel.eventLoop.assertInEventLoop()

        let channel = MultiplexerAbstractChannel(
            allocator: self._channel.allocator,
            parent: self._channel,
            multiplexer: multiplexer,
            streamID: nil,
            targetWindowSize: Int32(self._targetWindowSize),
            outboundBytesHighWatermark: self._streamChannelOutboundBytesHighWatermark,
            outboundBytesLowWatermark: self._streamChannelOutboundBytesLowWatermark,
            inboundStreamStateInitializer: .excludesStreamID(nil)
        )
        self._pendingStreams[channel.channelID] = channel

        channel.configure(initializer: streamStateInitializer, userPromise: promise)
    }

    internal func createStreamChannel(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        _ streamStateInitializer: @escaping NIOChannelInitializer) -> EventLoopFuture<Channel> {
        let promise = self._channel.eventLoop.makePromise(of: Channel.self)
        self.createStreamChannel(multiplexer: multiplexer, promise: promise, streamStateInitializer)
        return promise.futureResult
    }

    @available(*, deprecated, message: "The signature of 'streamStateInitializer' has changed to '(Channel) -> EventLoopFuture<Void>'")
    internal func createStreamChannel(
        multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
        promise: EventLoopPromise<Channel>?,
        _ streamStateInitializer: @escaping NIOChannelInitializerWithStreamID
    ) {
        self._channel.eventLoop.assertInEventLoop()

        let streamID = self.nextStreamID()
        let channel = MultiplexerAbstractChannel(
            allocator: self._channel.allocator,
            parent: self._channel,
            multiplexer: multiplexer,
            streamID: streamID,
            targetWindowSize: Int32(self._targetWindowSize),
            outboundBytesHighWatermark: self._streamChannelOutboundBytesHighWatermark,
            outboundBytesLowWatermark: self._streamChannelOutboundBytesLowWatermark,
            inboundStreamStateInitializer: .includesStreamID(nil)
        )
        self.streams[streamID] = channel
        channel.configure(initializer: streamStateInitializer, userPromise: promise)
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
        self._channel.eventLoop.assertInEventLoop()
        self.streamChannelContinuation = streamChannels
    }
}

/// `AnyContinuation` is used to generic async-sequence-like objects to deal with the generic element types without
/// the holding type becoming generic itself.
///
/// This is useful in in the case of the `HTTP2ChannelHandler` which must deal with types which hold stream initializers
/// which have a generic return type.
@usableFromInline
internal protocol AnyContinuation: Sendable {
    func yield(any: Any)
    func finish()
    func finish(throwing error: Error)
}


/// `NIOHTTP2AsyncSequence` is an implementation of the `AsyncSequence` protocol which allows iteration over a generic
/// element type `Output`.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct NIOHTTP2AsyncSequence<Output: Sendable>: AsyncSequence {
    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = Output

        private var iterator: AsyncThrowingStream<Output, Error>.AsyncIterator

        init(wrapping iterator: AsyncThrowingStream<Output, Error>.AsyncIterator) {
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
        AsyncIterator(wrapping: self.asyncThrowingStream.makeAsyncIterator())
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOHTTP2AsyncSequence {
    /// `Continuation` is a wrapper for a generic `AsyncThrowingStream` to which the products of the initializers of
    /// inbound (remotely-initiated) HTTP/2 stream channels are yielded.
    @usableFromInline
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    struct Continuation: AnyContinuation {
        private var continuation: AsyncThrowingStream<Output, Error>.Continuation

        internal init(wrapping continuation: AsyncThrowingStream<Output, Error>.Continuation) {
            self.continuation = continuation
        }

        /// `yield` takes a channel as outputted by the stream initializer and yields the wrapped `AsyncThrowingStream`.
        ///
        /// It takes channels as as `Any` type to allow wrapping by the stream initializer.
        @usableFromInline
        func yield(any: Any) {
            let yieldResult = self.continuation.yield(any as! Output)
                switch yieldResult {
                case .enqueued:
                    break // success, nothing to do
                case .terminated:
                    // this can happen if the task has been cancelled
                    // we can't do better than dropping the message at the moment
                    break
                case .dropped:
                    preconditionFailure("Attempted to yield when AsyncThrowingStream is over capacity. This shouldn't be possible for an unbounded stream.")
                default:
                    preconditionFailure("Attempt to yield to AsyncThrowingStream failed for unhandled reason.")
                }
        }

        /// `finish` marks the continuation as finished.
        @usableFromInline
        func finish() {
            self.continuation.finish()
        }

        /// `finish` marks the continuation as finished with the supplied error.
        @usableFromInline
        func finish(throwing error: Error) {
            self.continuation.finish(throwing: error)
        }
    }


    /// `initialize` creates a new `Continuation` object and returns it along with its backing ``NIOHTTP2AsyncSequence``.
    /// The `Continuation` provides the ability to yield to the backing .``NIOHTTP2AsyncSequence``.
    ///
    /// - Parameters:
    ///   - inboundStreamInitializerOutput: The type which is returned by the initializer operating on the inbound
    ///   (remotely-initiated) HTTP/2 streams.
    @usableFromInline
    static func initialize(inboundStreamInitializerOutput: Output.Type = Output.self) -> (NIOHTTP2AsyncSequence<Output>, Continuation) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Output.self)
        return (.init(stream), Continuation(wrapping: continuation))
    }
}

@available(*, unavailable)
extension NIOHTTP2AsyncSequence.AsyncIterator: Sendable {}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOHTTP2AsyncSequence: Sendable where Output: Sendable {}

#if swift(<5.9)
// this should be available in the std lib from 5.9 onwards
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncThrowingStream {
    static func makeStream(
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
