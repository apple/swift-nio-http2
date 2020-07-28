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

protocol HTTP2FrameConvertible {
    /// Makes an `HTTPFrame` with the given `streamID`.
    ///
    /// - Parameter streamID: The `streamID` to use when constructing the frame.
    func makeHTTP2Frame(streamID: HTTP2StreamID) -> HTTP2Frame
}

protocol HTTP2FramePayloadConvertible {
    /// Makes a `HTTP2Frame.FramePayload`.
    var payload: HTTP2Frame.FramePayload { get }
}
