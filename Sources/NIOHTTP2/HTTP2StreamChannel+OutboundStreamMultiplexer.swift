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

/// Multiplexes outbound HTTP/2 frames from an HTTP/2 stream into an HTTP/2
/// connection.
internal protocol HTTP2OutboundStreamMultiplexer {
  /// Write the frame into the HTTP/2 connection. Stream ID is included in the
  /// frame.
  func writeFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?)

  /// Flush the stream with the given ID.
  func flushStream(_ id: HTTP2StreamID)

  /// Request a stream ID for the given channel.
  ///
  /// Required to lazily assign a stream ID to a channel on first write.
  func requestStreamID(forChannel: Channel) -> HTTP2StreamID

  /// Notify the multiplexer that the channel with the given ID closed.
  ///
  /// Required as a channel may not have a stream ID when it closes.
  func streamClosed(channelID: ObjectIdentifier)

  /// Notify the multiplexer that the stream with the given ID closed.
  func streamClosed(id: HTTP2StreamID)
}

extension HTTP2StreamChannel {
    /// Abstracts over the integrated stream multiplexing (new) and the chained channel handler (legacy) multiplexing approaches.
    ///
    /// We use an enum for this purpose since we can't use a generic (for API compatibility reasons) and it allows us to avoid the cost of using an existential.
    @usableFromInline
    internal enum OutboundStreamMultiplexer: HTTP2OutboundStreamMultiplexer {
        case legacy(LegacyOutboundStreamMultiplexer)
        case inline(InlineStreamMultiplexer)

        func writeFrame(_ frame: HTTP2Frame, promise: NIOCore.EventLoopPromise<Void>?) {
            switch self {
            case .legacy(let legacyOutboundMultiplexer):
                legacyOutboundMultiplexer.writeFrame(frame, promise: promise)
            case .inline(let inlineStreamMultiplexer):
                inlineStreamMultiplexer.writeFrame(frame, promise: promise)
            }
        }

        func flushStream(_ id: HTTP2StreamID) {
            switch self {
            case .legacy(let legacyOutboundMultiplexer):
                legacyOutboundMultiplexer.flushStream(id)
            case .inline(let inlineStreamMultiplexer):
                inlineStreamMultiplexer.flushStream(id)
            }
        }

        func requestStreamID(forChannel: NIOCore.Channel) -> HTTP2StreamID {
            switch self {
            case .legacy(let legacyOutboundMultiplexer):
                return legacyOutboundMultiplexer.requestStreamID(forChannel: forChannel)
            case .inline(let inlineStreamMultiplexer):
                return inlineStreamMultiplexer.requestStreamID(forChannel: forChannel)
            }
        }

        func streamClosed(channelID: ObjectIdentifier) {
            switch self {
            case .legacy(let legacyOutboundMultiplexer):
                legacyOutboundMultiplexer.streamClosed(channelID: channelID)
            case .inline(let inlineStreamMultiplexer):
                inlineStreamMultiplexer.streamClosed(channelID: channelID)
            }
        }

        func streamClosed(id: HTTP2StreamID) {
            switch self {
            case .legacy(let legacyOutboundMultiplexer):
                legacyOutboundMultiplexer.streamClosed(id: id)
            case .inline(let inlineStreamMultiplexer):
                inlineStreamMultiplexer.streamClosed(id: id)
            }
        }
    }
}

/// Provides a 'multiplexer' interface for legacy compatibility.
///
/// This doesn't actually do any multiplexing but delegates it to the `HTTP2StreamMultiplexer` which does.
@usableFromInline
internal struct LegacyOutboundStreamMultiplexer {
    let multiplexer: HTTP2StreamMultiplexer
}

extension LegacyOutboundStreamMultiplexer: HTTP2OutboundStreamMultiplexer {
    func writeFrame(_ frame: HTTP2Frame, promise: NIOCore.EventLoopPromise<Void>?) {
        self.multiplexer.childChannelWrite(frame, promise: promise)
    }

    func flushStream(_ id: HTTP2StreamID) {
        self.multiplexer.childChannelFlush()
    }

    func requestStreamID(forChannel: NIOCore.Channel) -> HTTP2StreamID {
        self.multiplexer.requestStreamID(forChannel: forChannel)
    }

    func streamClosed(channelID: ObjectIdentifier) {
        self.multiplexer.childChannelClosed(channelID: channelID)
    }

    func streamClosed(id: HTTP2StreamID) {
        self.multiplexer.childChannelClosed(streamID: id)
    }
}

