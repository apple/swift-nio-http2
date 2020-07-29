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
    /// Initialize `Self` from an `HTTP2Frame`.
    init(http2Frame: HTTP2Frame)

    /// Makes an `HTTPFrame` with the given `streamID`.
    ///
    /// - Parameter streamID: The `streamID` to use when constructing the frame.
    func makeHTTP2Frame(streamID: HTTP2StreamID) -> HTTP2Frame
}

protocol HTTP2FramePayloadConvertible {
    /// Makes a `HTTP2Frame.FramePayload`.
    var payload: HTTP2Frame.FramePayload { get }
}

extension HTTP2FrameConvertible where Self: HTTP2FramePayloadConvertible {
    /// A shorthand heuristic for how many bytes we assume a frame consumes on the wire.
    ///
    /// Here we concern ourselves only with per-stream frames: that is, `HEADERS`, `DATA`,
    /// `WINDOW_UDPATE`, `RST_STREAM`, and I guess `PRIORITY`. As a simple heuristic we
    /// hard code fixed lengths for fixed length frames, use a calculated length for
    /// variable length frames, and just ignore encoded headers because it's not worth doing a better
    /// job.
    var estimatedFrameSize: Int {
        let frameHeaderSize = 9

        switch self.payload {
        case .data(let d):
            let paddingBytes = d.paddingBytes.map { $0 + 1 } ?? 0
            return d.data.readableBytes + paddingBytes + frameHeaderSize
        case .headers(let h):
            let paddingBytes = h.paddingBytes.map { $0 + 1 } ?? 0
            return paddingBytes + frameHeaderSize
        case .priority:
            return frameHeaderSize + 5
        case .pushPromise(let p):
            // Like headers, this is variably size, and we just ignore the encoded headers because
            // it's not worth having a heuristic.
            let paddingBytes = p.paddingBytes.map { $0 + 1 } ?? 0
            return paddingBytes + frameHeaderSize
        case .rstStream:
            return frameHeaderSize + 4
        case .windowUpdate:
            return frameHeaderSize + 4
        default:
            // Unknown or unexpected control frame: say 9 bytes.
            return frameHeaderSize
        }
    }
}
