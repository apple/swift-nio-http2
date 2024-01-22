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

/// A delegate which can be used with the ``NIOHTTP2Handler`` and its multiplexer.
///
/// Delegates are called when the multiplexer creates or closes HTTP/2 streams.
public protocol NIOHTTP2StreamDelegate: Sendable {
    /// A new HTTP/2 stream was created with the given ID.
    func streamCreated(_ id: HTTP2StreamID, channel: Channel)

    /// An HTTP/2 stream with the given ID was closed.
    func streamClosed(_ id: HTTP2StreamID, channel: Channel)
}
