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

/// A buffer of pending user events.
///
/// This buffer is used to ensure that we deliver user events and frames correctly from
/// the `NIOHTTP2Handler` in the face of reentrancy. Specifically, it is possible that
/// a re-entrant call will lead to `NIOHTTP2Handler.channelRead` being on the stack twice.
/// In this case, we do not want to deliver frames or user events out of order. Rather than
/// force the stack to unwind, we have this temporary storage location where all user events go.
/// This will be drained both before and after any frame read operation, to ensure that we
/// have always delivered all pending user events before we deliver a frame.
/// Deliberately not threadsafe or `Sendable`.
class InboundEventBuffer {
    fileprivate var buffer: CircularBuffer<BufferedHTTP2UserEvent> = CircularBuffer(initialCapacity: 8)

    func pendingUserEvent(_ event: NIOHTTP2StreamCreatedEvent) {
        self.buffer.append(.streamCreated(event))
    }

    func pendingUserEvent(_ event: StreamClosedEvent) {
        self.buffer.append(.streamClosed(event))
    }

    func pendingUserEvent(_ event: NIOHTTP2WindowUpdatedEvent) {
        self.buffer.append(.streamWindowUpdated(event))
    }

    func pendingUserEvent(_ event: NIOHTTP2BulkStreamWindowChangeEvent) {
        self.buffer.append(.initialStreamWindowChanged(event))
    }

    /// Wraps user event types.
    ///
    /// This allows us to buffer and pass around the events without making use of an existential.
    enum BufferedHTTP2UserEvent {
        case streamCreated(NIOHTTP2StreamCreatedEvent)
        case streamClosed(StreamClosedEvent)
        case streamWindowUpdated(NIOHTTP2WindowUpdatedEvent)
        case initialStreamWindowChanged(NIOHTTP2BulkStreamWindowChangeEvent)
    }
}

// MARK:- Sequence conformance
extension InboundEventBuffer: Sequence {
    typealias Element = BufferedHTTP2UserEvent

    func makeIterator() -> InboundEventBufferIterator {
        InboundEventBufferIterator(self)
    }

    struct InboundEventBufferIterator: IteratorProtocol {
        typealias Element = InboundEventBuffer.Element

        let inboundBuffer: InboundEventBuffer

        fileprivate init(_ buffer: InboundEventBuffer) {
            self.inboundBuffer = buffer
        }

        func next() -> Element? {
            if self.inboundBuffer.buffer.count > 0 {
                return self.inboundBuffer.buffer.removeFirst()
            } else {
                return nil
            }
        }
    }
}

// MARK:- CustomStringConvertible conformance
extension InboundEventBuffer: CustomStringConvertible {
    var description: String {
        "InboundEventBuffer { \(self.buffer) }"
    }
}
