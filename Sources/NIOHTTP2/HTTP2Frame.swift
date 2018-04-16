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
    public var header: FrameHeader
    public var payload: FramePayload

    public struct FrameHeader {
        var storage: nghttp2_frame_hd

        /// The frame flags as an 8-bit integer. To set/unset well-defined flags, consider using the
        /// other properties on this object (e.g. `endStream`).
        public var flags: UInt8 {
            return self.storage.flags
        }
        public var streamID: Int32 {
            return self.storage.stream_id
        }

        // Whether the END_STREAM flag bit is set.
        public var endStream: Bool {
            get {
                return ((self.storage.type == NGHTTP2_DATA.rawValue || self.storage.type == NGHTTP2_HEADERS.rawValue) &&
                        (self.storage.flags & UInt8(NGHTTP2_FLAG_END_STREAM.rawValue) != 0))
            }
            set {
                guard self.storage.type == NGHTTP2_DATA.rawValue || self.storage.type == NGHTTP2_HEADERS.rawValue else {
                    return
                }
                self.storage.flags |= UInt8(NGHTTP2_FLAG_END_STREAM.rawValue)
            }
        }

        // Whether the END_HEADERS flag bit is set.
        public var endHeaders: Bool {
            get {
                return ((self.storage.type == NGHTTP2_HEADERS.rawValue || self.storage.type == NGHTTP2_PUSH_PROMISE.rawValue || self.storage.type == NGHTTP2_CONTINUATION.rawValue) &&
                        (self.storage.flags & UInt8(NGHTTP2_FLAG_END_HEADERS.rawValue) != 0))
            }
            set {
                guard self.storage.type == NGHTTP2_HEADERS.rawValue || self.storage.type == NGHTTP2_PUSH_PROMISE.rawValue || self.storage.type == NGHTTP2_CONTINUATION.rawValue else {
                    return
                }
                self.storage.flags |= UInt8(NGHTTP2_FLAG_END_HEADERS.rawValue)
            }
        }

        // Whether the PADDED flag bit is set.
        public var padded: Bool {
            get {
                return ((self.storage.type == NGHTTP2_DATA.rawValue || self.storage.type == NGHTTP2_HEADERS.rawValue || self.storage.type == NGHTTP2_PUSH_PROMISE.rawValue) &&
                        (self.storage.flags & UInt8(NGHTTP2_FLAG_PADDED.rawValue) != 0))
            }
            set {
                guard self.storage.type == NGHTTP2_DATA.rawValue || self.storage.type == NGHTTP2_HEADERS.rawValue || self.storage.type == NGHTTP2_PUSH_PROMISE.rawValue else {
                    return
                }
                self.storage.flags |= UInt8(NGHTTP2_FLAG_PADDED.rawValue)
            }
        }

        // Whether the PRIORITY flag bit is set.
        public var priority: Bool {
            get {
                return (self.storage.type == NGHTTP2_HEADERS.rawValue && (self.storage.flags & UInt8(NGHTTP2_FLAG_PRIORITY.rawValue) != 0))
            }
            set {
                guard self.storage.type == NGHTTP2_HEADERS.rawValue else {
                    return
                }
                self.storage.flags |= UInt8(NGHTTP2_FLAG_PRIORITY.rawValue)
            }
        }

        // Whether the ACK flag bit is set.
        public var ack: Bool {
            get {
                return ((self.storage.type == NGHTTP2_SETTINGS.rawValue || self.storage.type == NGHTTP2_PING.rawValue) &&
                    (self.storage.flags & UInt8(NGHTTP2_FLAG_ACK.rawValue) != 0))
            }
            set {
                guard self.storage.type == NGHTTP2_SETTINGS.rawValue || self.storage.type == NGHTTP2_PING.rawValue else {
                    return
                }
                self.storage.flags |= UInt8(NGHTTP2_FLAG_ACK.rawValue)
            }
        }
    }

    public enum FramePayload {
        case data(IOData)
        case headers(HTTP2HeadersCategory)
        case priority
        case rstStream
        case settings([(Int32, UInt32)])
        case pushPromise
        case ping
        case goAway
        case windowUpdate(windowSizeIncrement: Int)
        case continuation
        case alternativeService
    }
}


internal extension HTTP2Frame.FrameHeader {
    internal init(nghttp2FrameHeader: nghttp2_frame_hd) {
        self.storage = nghttp2FrameHeader
    }
}

public extension HTTP2Frame.FrameHeader {
    /// Constructs a frame header for a given stream ID. All flags are unset.
    public init(streamID: Int) {
        precondition(streamID >= 0 && streamID < (Int32.max), "Invalid stream identifier: \(streamID)")
        self.storage = nghttp2_frame_hd()
        self.storage.stream_id = Int32(streamID)
    }

    /// Constructs a frame header for a given stream ID. All flags are unset.
    public init(streamID: Int32) {
        self.init(streamID: Int(streamID))
    }
}
