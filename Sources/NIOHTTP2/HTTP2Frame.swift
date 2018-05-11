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

import NIO
import NIOHTTP1
import CNIONghttp2

/// A representation of a single HTTP/2 frame.
public struct HTTP2Frame {
    /// The payload of this HTTP/2 frame.
    public var payload: FramePayload

    /// The frame flags as an 8-bit integer. To set/unset well-defined flags, consider using the
    /// other properties on this object (e.g. `endStream`).
    public var flags: UInt8

    /// The frame stream ID as a 32-bit integer.
    public var streamID: HTTP2StreamID

    // Whether the END_STREAM flag bit is set.
    public var endStream: Bool {
        get {
            switch self.payload {
            case .data, .headers:
                return (self.flags & UInt8(NGHTTP2_FLAG_END_STREAM.rawValue) != 0)
            default:
                return false
            }
        }
        set {
            switch self.payload {
            case .data, .headers:
                self.flags |= UInt8(NGHTTP2_FLAG_END_STREAM.rawValue)
            default:
                break
            }
        }
    }

    // Whether the PADDED flag bit is set.
    public var padded: Bool {
        get {
            switch self.payload {
            case .data, .headers, .pushPromise:
                return (self.flags & UInt8(NGHTTP2_FLAG_PADDED.rawValue) != 0)
            default:
                return false
            }
        }
        set {
            switch self.payload {
            case .data, .headers, .pushPromise:
                self.flags |= UInt8(NGHTTP2_FLAG_PADDED.rawValue)
            default:
                break
            }
        }
    }

    // Whether the PRIORITY flag bit is set.
    public var priority: Bool {
        get {
            if case .headers = self.payload {
                 return (self.flags & UInt8(NGHTTP2_FLAG_PRIORITY.rawValue) != 0)
            } else {
                return false
            }
        }
        set {
            if case .headers = self.payload {
                self.flags |= UInt8(NGHTTP2_FLAG_PRIORITY.rawValue)
            }
        }
    }

    // Whether the ACK flag bit is set.
    public var ack: Bool {
        get {
            switch self.payload {
            case .settings, .ping:
                return (self.flags & UInt8(NGHTTP2_FLAG_ACK.rawValue) != 0)
            default:
                return false
            }
        }
        set {
            switch self.payload {
            case .settings, .ping:
                self.flags |= UInt8(NGHTTP2_FLAG_ACK.rawValue)
            default:
                break
            }
        }
    }

    public enum FramePayload {
        case data(IOData)
        case headers(HTTPHeaders)
        case priority
        case rstStream(HTTP2ErrorCode)
        case settings([HTTP2Setting])
        case pushPromise
        case ping(HTTP2PingData)
        case goAway(lastStreamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, opaqueData: ByteBuffer?)
        case windowUpdate(windowSizeIncrement: Int)
        case alternativeService
    }
}


internal extension HTTP2Frame {
    internal init(streamID: HTTP2StreamID, flags: UInt8, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.flags = flags
        self.payload = payload
    }
}

public extension HTTP2Frame {
    /// Constructs a frame header for a given stream ID. All flags are unset.
    public init(streamID: HTTP2StreamID, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.flags = 0
        self.payload = payload
    }
}
