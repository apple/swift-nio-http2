//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A `StreamClosedEvent` is fired whenever a stream is closed.
///
/// This event is fired whether the stream is closed normally, or via RST_STREAM,
/// or via GOAWAY. Normal closure is indicated by having `reason` be `nil`. In the
/// case of closure by GOAWAY the `reason` is always `.refusedStream`, indicating that
/// the remote peer has not processed this stream. In the case of RST_STREAM,
/// the `reason` contains the error code sent by the peer in the RST_STREAM frame.
public struct StreamClosedEvent {
    /// The stream ID of the stream that is closed.
    public let streamID: HTTP2StreamID

    /// The reason for the stream closure. `nil` if the stream was closed without
    /// error. Otherwise, the error code indicating why the stream was closed.
    public let reason: HTTP2ErrorCode?
}

extension StreamClosedEvent: Equatable {
    public static func ==(lhs: StreamClosedEvent, rhs: StreamClosedEvent) -> Bool {
        return lhs.streamID == rhs.streamID && lhs.reason == rhs.reason
    }
}
