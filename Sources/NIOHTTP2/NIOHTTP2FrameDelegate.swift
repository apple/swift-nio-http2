//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHPACK

/// A delegate which can be used with the ``NIOHTTP2Handler`` which is notified
/// when various frame types are written into the connection channel.
///
/// This delegate, when used by the ``NIOHTTP2Handler`` will be called on the event
/// loop associated with the channel that the handler is a part of. As such you should
/// avoid doing expensive or blocking work in this delegate.
public protocol NIOHTTP2FrameDelegate: Sendable {
    /// Called when a HEADERS frame is written by the connection channel.
    ///
    /// - Parameters:
    ///   - headers: The headers sent to the remote peer.
    ///   - endStream: Whether the end stream was set on the frame.
    ///   - streamID: The ID of the stream the frame was written to.
    func wroteHeaders(_ headers: HPACKHeaders, endStream: Bool, streamID: HTTP2StreamID)

    /// Called when a DATA frame is written by the connection channel.
    ///
    /// The data you see here may be chunked differently to the data you sent
    /// from a stream channel. This may happen as the connect may need to slice up
    /// the data over multiple frames to respect flow control windows and various
    /// connection settings (such as max frame size).
    ///
    /// - Parameters:
    ///   - data: The content of the DATA frame.
    ///   - endStream: Whether the end stream was set on the frame.
    ///   - streamID: The ID of the stream the frame was written to.
    func wroteData(_ data: ByteBuffer, endStream: Bool, streamID: HTTP2StreamID)
}

extension NIOHTTP2FrameDelegate {
    public func wroteHeaders(_ headers: HPACKHeaders, endStream: Bool, streamID: HTTP2StreamID) {
        // no-op
    }

    public func wroteData(_ data: ByteBuffer, endStream: Bool, streamID: HTTP2StreamID) {
        // no-op
    }
}
