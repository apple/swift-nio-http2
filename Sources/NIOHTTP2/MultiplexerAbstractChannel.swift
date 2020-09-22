//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIO

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
struct MultiplexerAbstractChannel {
    private var baseChannel: HTTP2StreamChannel

    init(allocator: ByteBufferAllocator,
         parent: Channel,
         multiplexer: HTTP2StreamMultiplexer,
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

        case .excludesStreamID:
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
    enum InboundStreamStateInitializer {
        case includesStreamID(((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?)
        case excludesStreamID(((Channel) -> EventLoopFuture<Void>)?)
    }
}

// MARK: API for HTTP2StreamMultiplexer
extension MultiplexerAbstractChannel {
    var streamID: HTTP2StreamID? {
        return self.baseChannel.streamID
    }

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
        }
    }

    func configure(initializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?, userPromise promise: EventLoopPromise<Channel>?) {
        self.baseChannel.configure(initializer: initializer, userPromise: promise)
    }

    func configure(initializer: ((Channel) -> EventLoopFuture<Void>)?, userPromise promise: EventLoopPromise<Channel>?) {
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
}

extension MultiplexerAbstractChannel: Equatable {
    static func ==(lhs: MultiplexerAbstractChannel, rhs: MultiplexerAbstractChannel) -> Bool {
        return lhs.baseChannel === rhs.baseChannel
    }
}

extension MultiplexerAbstractChannel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.baseChannel))
    }
}
