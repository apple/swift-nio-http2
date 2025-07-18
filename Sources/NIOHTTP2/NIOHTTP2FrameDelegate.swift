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
public protocol NIOHTTP2FrameDelegate {
    /// Called when a frame is written by the connection channel.
    ///
    /// - Parameters:
    ///   - frame: The frame to write.
    func wroteFrame(_ frame: HTTP2Frame)
}
