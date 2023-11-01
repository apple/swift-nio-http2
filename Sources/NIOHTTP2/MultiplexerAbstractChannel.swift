//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

/// This structure defines an abstraction over `HTTP2StreamChannel` that is used
/// by the `HTTP2StreamMultiplexer`.
///
/// The goal of this type is to help reduce the coupling between
/// `HTTP2StreamMultiplexer` and `HTTP2Channel`. By providing this abstraction layer,
/// it makes it easier for us to change the potential backing implementation without
/// having to modify `HTTP2StreamMultiplexer`.
///
/// Note that while this is a `struct`, this `struct` has _reference semantics_.
/// The implementation of `Equatable` & `Hashable` on this type reinforces that requirement.
@usableFromInline
struct MultiplexerAbstractChannel {
    @usableFromInline private(set) var baseChannel: HTTP2StreamChannel

    @usableFromInline
    init(allocator: ByteBufferAllocator,
         parent: Channel,
         multiplexer: HTTP2StreamChannel.OutboundStreamMultiplexer,
         streamID: HTTP2StreamID?,
         targetWindowSize: Int32,
         outboundBytesHighWatermark: Int,
         outboundBytesLowWatermark: Int,
         inboundStreamStateInitializer: InboundStreamStateInitializer) {
        switch inboundStreamStateInitializer {
        case .includesStreamID:
            assert(streamID != nil)
            self.baseChannel = .init(allocator: allocator,
                                     parent: parent,
                                     multiplexer: multiplexer,
                                     streamID: streamID,
                                     targetWindowSize: targetWindowSize,
                                     outboundBytesHighWatermark: outboundBytesHighWatermark,
                                     outboundBytesLowWatermark: outboundBytesLowWatermark,
                                     streamDataType: .frame)

        case .excludesStreamID, .returnsAny:
            self.baseChannel = .init(allocator: allocator,
                                     parent: parent,
                                     multiplexer: multiplexer,
                                     streamID: streamID,
                                     targetWindowSize: targetWindowSize,
                                     outboundBytesHighWatermark: outboundBytesHighWatermark,
                                     outboundBytesLowWatermark: outboundBytesLowWatermark,
                                     streamDataType: .framePayload)
        }
    }
}

extension MultiplexerAbstractChannel {
    @usableFromInline
    enum InboundStreamStateInitializer {
        case includesStreamID(NIOChannelInitializerWithStreamID?)
        case excludesStreamID(NIOChannelInitializer?)
        case returnsAny(NIOChannelInitializerWithOutput<any Sendable>)
    }
}

// MARK: API for HTTP2StreamMultiplexer
extension MultiplexerAbstractChannel {
    var streamID: HTTP2StreamID? {
        return self.baseChannel.streamID
    }

    @usableFromInline
    var channelID: ObjectIdentifier {
        return ObjectIdentifier(self.baseChannel)
    }

    var inList: Bool {
        return self.baseChannel.inList
    }

    var streamChannelListNode: StreamChannelListNode {
        get {
            return self.baseChannel.streamChannelListNode
        }
        nonmutating set {
            self.baseChannel.streamChannelListNode = newValue
        }
    }

    func configureInboundStream(initializer: InboundStreamStateInitializer) {
        switch initializer {
        case .includesStreamID(let initializer):
            self.baseChannel.configure(initializer: initializer, userPromise: nil)
        case .excludesStreamID(let initializer):
            self.baseChannel.configure(initializer: initializer, userPromise: nil)
        case .returnsAny(let initializer):
            self.baseChannel.configure(initializer: initializer, userPromise: nil)
        }
    }

    func configureInboundStream(initializer: InboundStreamStateInitializer, promise: EventLoopPromise<any Sendable>?) {
        switch initializer {
        case .includesStreamID, .excludesStreamID:
            preconditionFailure("Configuration with a supplied `Any` promise is not supported with this initializer type.")
        case .returnsAny(let initializer):
            self.baseChannel.configure(initializer: initializer, userPromise: promise)
        }
    }

    // legacy `initializer` function signature
    func configure(initializer: NIOChannelInitializerWithStreamID?, userPromise promise: EventLoopPromise<Channel>?) {
        self.baseChannel.configure(initializer: initializer, userPromise: promise)
    }

    // NIOHTTP2Handler.Multiplexer and HTTP2StreamMultiplexer
    func configure(initializer: NIOChannelInitializer?, userPromise promise: EventLoopPromise<Channel>?) {
        self.baseChannel.configure(initializer: initializer, userPromise: promise)
    }

    // used for async multiplexer
    @usableFromInline
    func configure(initializer: @escaping NIOChannelInitializerWithOutput<any Sendable>, userPromise promise: EventLoopPromise<any Sendable>?) {
        self.baseChannel.configure(initializer: initializer, userPromise: promise)
    }

    func performActivation() {
        self.baseChannel.performActivation()
    }

    func networkActivationReceived() {
        self.baseChannel.networkActivationReceived()
    }

    func receiveInboundFrame(_ frame: HTTP2Frame) {
        self.baseChannel.receiveInboundFrame(frame)
    }

    func receiveParentChannelReadComplete() {
        self.baseChannel.receiveParentChannelReadComplete()
    }

    func initialWindowSizeChanged(delta: Int) {
        self.baseChannel.initialWindowSizeChanged(delta: delta)
    }

    func receiveWindowUpdatedEvent(_ windowSize: Int) {
        self.baseChannel.receiveWindowUpdatedEvent(windowSize)
    }

    func parentChannelWritabilityChanged(newValue: Bool) {
        self.baseChannel.parentChannelWritabilityChanged(newValue: newValue)
    }

    func receiveStreamClosed(_ reason: HTTP2ErrorCode?) {
        self.baseChannel.receiveStreamClosed(reason)
    }

    func receiveStreamError(_ error: NIOHTTP2Errors.StreamError) {
        self.baseChannel.receiveStreamError(error)
    }

    func wroteBytes(_ size: Int) {
        self.baseChannel.wroteBytes(size)
    }
}

extension MultiplexerAbstractChannel: Equatable {
    @inlinable
    static func ==(lhs: MultiplexerAbstractChannel, rhs: MultiplexerAbstractChannel) -> Bool {
        return lhs.baseChannel === rhs.baseChannel
    }
}

extension MultiplexerAbstractChannel: Hashable {
    @inlinable
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.baseChannel))
    }
}
