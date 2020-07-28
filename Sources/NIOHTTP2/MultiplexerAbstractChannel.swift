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

    init(allocator: ByteBufferAllocator,
         parent: Channel,
         multiplexer: HTTP2StreamMultiplexer,
         streamID: HTTP2StreamID,
         targetWindowSize: Int32,
         outboundBytesHighWatermark: Int,
         outboundBytesLowWatermark: Int) {
        self.baseChannel = .frameBased(.init(allocator: allocator,
                                             parent: parent,
                                             multiplexer: multiplexer,
                                             streamID: streamID,
                                             targetWindowSize: targetWindowSize,
                                             outboundBytesHighWatermark: outboundBytesHighWatermark,
                                             outboundBytesLowWatermark: outboundBytesLowWatermark))
    }

    init(_ channel: HTTP2StreamChannel) {
        self.baseChannel = .frameBased(channel)
    }
}

extension MultiplexerAbstractChannel {
    enum BaseChannel {
        case frameBased(HTTP2StreamChannel)
    }
}

// MARK: API for HTTP2StreamMultiplexer
extension MultiplexerAbstractChannel {
    var streamID: HTTP2StreamID? {
        switch self.baseChannel {
        case .frameBased(let base):
            return base.streamID
        }
    }

    var inList: Bool {
        switch self.baseChannel {
        case .frameBased(let base):
            return base.inList
        }
    }

    var streamChannelListNode: StreamChannelListNode {
        get {
            switch self.baseChannel {
            case .frameBased(let base):
                return base.streamChannelListNode
            }
        }
        nonmutating set {
            switch self.baseChannel {
            case .frameBased(let base):
                base.streamChannelListNode = newValue
            }
        }
    }

    func configure(initializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?, userPromise promise: EventLoopPromise<Channel>?) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.configure(initializer: initializer, userPromise: promise)
        }
    }

    func performActivation() {
        switch self.baseChannel {
        case .frameBased(let base):
            base.performActivation()
        }
    }

    func networkActivationReceived() {
        switch self.baseChannel {
        case .frameBased(let base):
            base.networkActivationReceived()
        }
    }

    func receiveInboundFrame(_ frame: HTTP2Frame) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveInboundFrame(frame)
        }
    }

    func receiveParentChannelReadComplete() {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveParentChannelReadComplete()
        }
    }

    func initialWindowSizeChanged(delta: Int) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.initialWindowSizeChanged(delta: delta)
        }
    }

    func receiveWindowUpdatedEvent(_ windowSize: Int) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveWindowUpdatedEvent(windowSize)
        }
    }

    func parentChannelWritabilityChanged(newValue: Bool) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.parentChannelWritabilityChanged(newValue: newValue)
        }
    }

    func receiveStreamClosed(_ reason: HTTP2ErrorCode?) {
        switch self.baseChannel {
        case .frameBased(let base):
            base.receiveStreamClosed(reason)
        }
    }
}

extension MultiplexerAbstractChannel: Equatable {
    static func ==(lhs: MultiplexerAbstractChannel, rhs: MultiplexerAbstractChannel) -> Bool {
        switch (lhs.baseChannel, rhs.baseChannel) {
        case (.frameBased(let lhs), .frameBased(let rhs)):
            return lhs === rhs
        }
    }
}

extension MultiplexerAbstractChannel: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self.baseChannel {
        case .frameBased(let base):
            hasher.combine(ObjectIdentifier(base))
        }
    }
}
