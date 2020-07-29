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
    private var baseChannel: BaseChannel

    private init(baseChannel: BaseChannel) {
        self.baseChannel = baseChannel
    }

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
            self.init(baseChannel: .frameBased(.init(allocator: allocator,
                                                     parent: parent,
                                                     multiplexer: multiplexer,
                                                     streamID: streamID,
                                                     targetWindowSize: targetWindowSize,
                                                     outboundBytesHighWatermark: outboundBytesHighWatermark,
                                                     outboundBytesLowWatermark: outboundBytesLowWatermark)))
        case .excludesStreamID:
            self.init(baseChannel: .payloadBased(.init(allocator: allocator,
                                                       parent: parent,
                                                       multiplexer: multiplexer,
                                                       streamID: streamID,
                                                       targetWindowSize: targetWindowSize,
                                                       outboundBytesHighWatermark: outboundBytesHighWatermark,
                                                       outboundBytesLowWatermark: outboundBytesLowWatermark)))
        }
    }
}

extension MultiplexerAbstractChannel {
    enum BaseChannel {
        case frameBased(HTTP2FrameBasedStreamChannel)
        case payloadBased(HTTP2PayloadBasedStreamChannel)
    }

    enum InboundStreamStateInitializer {
        case includesStreamID(((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?)
        case excludesStreamID(((Channel) -> EventLoopFuture<Void>)?)
    }
}

// MARK: API for HTTP2StreamMultiplexer
extension MultiplexerAbstractChannel {
    var streamID: HTTP2StreamID? {
        switch self.baseChannel {
        case .frameBased(let base):
            return base.streamID
        case .payloadBased(let base):
            return base.streamID
        }
    }

    var channelID: ObjectIdentifier {
        switch self.baseChannel {
        case .frameBased(let base):
            return ObjectIdentifier(base)
        case .payloadBased(let base):
            return ObjectIdentifier(base)
        }
    }

    var inList: Bool {
        switch self.baseChannel {
        case .frameBased(let base):
            return base.inList
        case .payloadBased(let base):
            return base.inList
        }
    }

    var streamChannelListNode: StreamChannelListNode {
        get {
            switch self.baseChannel {
            case .frameBased(let base):
                return base.streamChannelListNode
            case .payloadBased(let base):
                return base.streamChannelListNode
            }
        }
        nonmutating set {
            switch self.baseChannel {
            case .frameBased(let base):
                base.streamChannelListNode = newValue
            case .payloadBased(let base):
                base.streamChannelListNode = newValue
            }
        }
    }

    func configureInboundStream(initializer: InboundStreamStateInitializer) {
        switch (self.baseChannel, initializer) {
        case (.frameBased(let base), .includesStreamID(let initializer)):
            base.configure(initializer: initializer, userPromise: nil)
        case (.payloadBased(let base), .excludesStreamID(let initializer)):
            base.configure(initializer: initializer, userPromise: nil)
        case (.frameBased, .excludesStreamID),
             (.payloadBased, .includesStreamID):
            // We create the base channel based on the type inbound initializer we receive
            // in `init`, so this should never happen.
            preconditionFailure("Invalid base channel and inbound stream state combination")
        }
    }

    func configure(initializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?, userPromise promise: EventLoopPromise<Channel>?) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.configure(initializer: initializer, userPromise: promise)
        case .payloadBased:
            fatalError("Can't configure a payload based channel with this initializer.")
        }
    }

    func configure(initializer: ((Channel) -> EventLoopFuture<Void>)?, userPromise promise: EventLoopPromise<Channel>?) {
        switch self.baseChannel {
        case .frameBased:
            fatalError("Can't configure a frame based channel with this initializer.")
        case .payloadBased(let base):
            base.configure(initializer: initializer, userPromise: promise)
        }
    }

    func performActivation() {
        switch self.baseChannel {
        case .frameBased(let base):
            base.performActivation()
        case .payloadBased(let base):
            base.performActivation()
        }
    }

    func networkActivationReceived() {
        switch self.baseChannel {
        case .frameBased(let base):
            base.networkActivationReceived()
        case .payloadBased(let base):
            base.networkActivationReceived()
        }
    }

    func receiveInboundFrame(_ frame: HTTP2Frame) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveInboundFrame(frame)
        case .payloadBased(let base):
            base.receiveInboundFrame(frame)
        }
    }

    func receiveParentChannelReadComplete() {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveParentChannelReadComplete()
        case .payloadBased(let base):
            base.receiveParentChannelReadComplete()
        }
    }

    func initialWindowSizeChanged(delta: Int) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.initialWindowSizeChanged(delta: delta)
        case .payloadBased(let base):
            base.initialWindowSizeChanged(delta: delta)
        }
    }

    func receiveWindowUpdatedEvent(_ windowSize: Int) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveWindowUpdatedEvent(windowSize)
        case .payloadBased(let base):
            base.receiveWindowUpdatedEvent(windowSize)
        }
    }

    func parentChannelWritabilityChanged(newValue: Bool) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.parentChannelWritabilityChanged(newValue: newValue)
        case .payloadBased(let base):
            base.parentChannelWritabilityChanged(newValue: newValue)
        }
    }

    func receiveStreamClosed(_ reason: HTTP2ErrorCode?) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveStreamClosed(reason)
        case .payloadBased(let base):
            base.receiveStreamClosed(reason)
        }
    }
}

extension MultiplexerAbstractChannel: Equatable {
    static func ==(lhs: MultiplexerAbstractChannel, rhs: MultiplexerAbstractChannel) -> Bool {
        switch (lhs.baseChannel, rhs.baseChannel) {
        case (.frameBased(let lhs), .frameBased(let rhs)):
            return lhs === rhs
        case (.payloadBased(let lhs), .payloadBased(let rhs)):
            return lhs === rhs
        case (.frameBased, .payloadBased), (.payloadBased, .frameBased):
            return false
        }
    }
}

extension MultiplexerAbstractChannel: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self.baseChannel {
        case .frameBased(let base):
            hasher.combine(ObjectIdentifier(base))
        case .payloadBased(let base):
            hasher.combine(ObjectIdentifier(base))
        }
    }
}
