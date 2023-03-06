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

/// Demultiplexes inbound HTTP/2 frames on a connection into HTTP/2 streams.
internal protocol HTTP2InboundStreamMultiplexer {
    /// An HTTP/2 frame has been received from the remote peer.
    func receivedFrame(_ frame: HTTP2Frame)

    /// A stream error was thrown when trying to send an outbound frame.
    func streamError(streamID: HTTP2StreamID, error: Error)

    /// A new HTTP/2 stream was created with the given ID.
    func streamCreated(event: NIOHTTP2StreamCreatedEvent)

    /// An HTTP/2 stream with the given ID was closed.
    func streamClosed(event: StreamClosedEvent)

    /// The flow control windows of the HTTP/2 stream changed.
    func streamWindowUpdated(event: NIOHTTP2WindowUpdatedEvent)

    /// The initial stream window for all streams changed by the given amount.
    func initialStreamWindowChanged(event: NIOHTTP2BulkStreamWindowChangeEvent)
}

extension NIOHTTP2Handler {
    /// Abstracts over the integrated stream multiplexing (new) and the chained channel handler (legacy) multiplexing approaches.
    ///
    /// We use an enum for this purpose since we can't use a generic (for API compatibility reasons) and it allows us to avoid the cost of using an existential.
    internal enum InboundStreamMultiplexer: HTTP2InboundStreamMultiplexer {
        case legacy(LegacyInboundStreamMultiplexer)
        case new

        func receivedFrame(_ frame: HTTP2Frame) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.receivedFrame(frame)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func streamError(streamID: HTTP2StreamID, error: Error) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.streamError(streamID: streamID, error: error)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func streamCreated(event: NIOHTTP2StreamCreatedEvent) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.streamCreated(event: event)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func streamClosed(event: StreamClosedEvent) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.streamClosed(event: event)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func streamWindowUpdated(event: NIOHTTP2WindowUpdatedEvent) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.streamWindowUpdated(event: event)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func initialStreamWindowChanged(event: NIOHTTP2BulkStreamWindowChangeEvent) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.initialStreamWindowChanged(event: event)
            case .new:
                fatalError("Not yet implemented.")
            }
        }
    }
}

/// Provides an inbound stream multiplexer interface for legacy compatibility.
///
/// This doesn't actually do any demultiplexing of inbound streams but communicates with the `HTTP2StreamChannel` which does - mostly via `UserInboundEvent`s.
internal struct LegacyInboundStreamMultiplexer {
    let context: ChannelHandlerContext
}

extension LegacyInboundStreamMultiplexer: HTTP2InboundStreamMultiplexer {
    func receivedFrame(_ frame: HTTP2Frame) {
        self.context.fireChannelRead(NIOAny(frame))
    }

    func streamError(streamID: HTTP2StreamID, error: Error) {
        self.context.fireErrorCaught(NIOHTTP2Errors.streamError(streamID: streamID, baseError: error))
    }

    func streamCreated(event: NIOHTTP2StreamCreatedEvent) {
        self.context.fireUserInboundEventTriggered(event)
    }

    func streamClosed(event: StreamClosedEvent) {
        self.context.fireUserInboundEventTriggered(event)
    }

    func streamWindowUpdated(event: NIOHTTP2WindowUpdatedEvent) {
        self.context.fireUserInboundEventTriggered(event)
    }

    func initialStreamWindowChanged(event: NIOHTTP2BulkStreamWindowChangeEvent) {
        self.context.fireUserInboundEventTriggered(event)
    }
}
