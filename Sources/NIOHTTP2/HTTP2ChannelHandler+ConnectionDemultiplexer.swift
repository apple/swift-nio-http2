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
internal protocol NIOHTTP2ConnectionDemultiplexer {
    /// An HTTP/2 frame has been received from the remote peer.
    func receivedFrame(_ frame: HTTP2Frame)

    /// A stream error was thrown when trying to send an outbound frame.
    func streamError(streamID: HTTP2StreamID, error: Error)

    /// A new HTTP/2 stream was created with the given ID.
    func streamCreated(_ id: HTTP2StreamID, localInitialWindowSize: UInt32?, remoteInitialWindowSize: UInt32?)

    /// An HTTP/2 stream with the given ID was closed.
    func streamClosed(_ id: HTTP2StreamID, reason: HTTP2ErrorCode?)

    /// The flow control windows of the HTTP/2 stream changed.
    func streamWindowUpdated(_ id: HTTP2StreamID, inboundWindowSize: Int?, outboundWindowSize: Int?)

    /// The initial stream window for all streams changed by the given amount.
    func initialStreamWindowChanged(by delta: Int)
}

extension NIOHTTP2Handler {
    /// Abstracts over the integrated stream multiplexing (new) and the chained channel handler (legacy) multiplexing approaches.
    ///
    /// We use an enum for this purpose since we can't use a generic (for API compatibility reasons) and it allows us to avoid the cost of using an existential.
    internal enum ConnectionDemultiplexer: NIOHTTP2ConnectionDemultiplexer {
        case legacy(LegacyHTTP2ConnectionDemultiplexer)
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

        func streamCreated(_ id: HTTP2StreamID, localInitialWindowSize: UInt32?, remoteInitialWindowSize: UInt32?) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.streamCreated(id, localInitialWindowSize: localInitialWindowSize, remoteInitialWindowSize: remoteInitialWindowSize)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func streamClosed(_ id: HTTP2StreamID, reason: HTTP2ErrorCode?) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.streamClosed(id, reason: reason)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func streamWindowUpdated(_ id: HTTP2StreamID, inboundWindowSize: Int?, outboundWindowSize: Int?) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.streamWindowUpdated(id, inboundWindowSize: inboundWindowSize, outboundWindowSize: outboundWindowSize)
            case .new:
                fatalError("Not yet implemented.")
            }
        }

        func initialStreamWindowChanged(by delta: Int) {
            switch self {
            case .legacy(let demultiplexer):
                demultiplexer.initialStreamWindowChanged(by: delta)
            case .new:
                fatalError("Not yet implemented.")
            }
        }
    }
}

/// Provides a 'demultiplexer' interface for legacy compatibility.
///
/// This doesn't actually do any demultiplexing but communicates with the `HTTP2StreamChannel` which does - mostly via `UserInboundEvent`s.
internal struct LegacyHTTP2ConnectionDemultiplexer {
    let context: ChannelHandlerContext
}

extension LegacyHTTP2ConnectionDemultiplexer: NIOHTTP2ConnectionDemultiplexer {
    func receivedFrame(_ frame: HTTP2Frame) {
        self.context.fireChannelRead(NIOAny(frame))
    }

    func streamError(streamID: HTTP2StreamID, error: Error) {
        self.context.fireErrorCaught(NIOHTTP2Errors.streamError(streamID: streamID, baseError: error))
    }

    func streamCreated(_ id: HTTP2StreamID, localInitialWindowSize: UInt32?, remoteInitialWindowSize: UInt32?) {
        self.context.fireUserInboundEventTriggered(NIOHTTP2StreamCreatedEvent(streamID: id, localInitialWindowSize: localInitialWindowSize, remoteInitialWindowSize: remoteInitialWindowSize))
    }

    func streamClosed(_ id: HTTP2StreamID, reason: HTTP2ErrorCode?) {
        self.context.fireUserInboundEventTriggered(StreamClosedEvent(streamID: id, reason: reason))
    }

    func streamWindowUpdated(_ id: HTTP2StreamID, inboundWindowSize: Int?, outboundWindowSize: Int?) {
        self.context.fireUserInboundEventTriggered(NIOHTTP2WindowUpdatedEvent(streamID: id, inboundWindowSize: inboundWindowSize, outboundWindowSize: outboundWindowSize))
    }

    func initialStreamWindowChanged(by delta: Int) {
        self.context.fireUserInboundEventTriggered(NIOHTTP2BulkStreamWindowChangeEvent(delta: delta))
    }
}
