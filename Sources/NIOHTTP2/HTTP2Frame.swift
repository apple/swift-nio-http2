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
import NIOHPACK
import CNIONghttp2

/// A representation of a single HTTP/2 frame.
public struct HTTP2Frame {
    /// The payload of this HTTP/2 frame.
    public var payload: FramePayload

    /// The frame flags.
    public var flags: FrameFlags
    
    /// The frame stream ID as a 32-bit integer.
    public var streamID: HTTP2StreamID
    
    /// Stream priority data, used in PRIORITY frames and optionally in HEADERS frames.
    public struct StreamPriorityData: Equatable, Hashable {
        public var exclusive: Bool
        public var dependency: HTTP2StreamID
        public var weight: UInt8
    }

    /// Frame-type-specific payload data.
    public enum FramePayload {
        /// A DATA frame, containing raw bytes.
        ///
        /// See [RFC 7540 § 6.1](https://httpwg.org/specs/rfc7540.html#rfc.section.6.1).
        case data(IOData)
        
        /// A HEADERS frame, containing all headers or trailers associated with a request
        /// or response.
        ///
        /// Note that swift-nio-http2 automatically coalesces HEADERS and CONTINUATION
        /// frames into a single `FramePayload.headers` instance.
        ///
        /// See [RFC 7540 § 6.2](https://httpwg.org/specs/rfc7540.html#rfc.section.6.2).
        case headers(HPACKHeaders, StreamPriorityData?)
        
        /// A PRIORITY frame, used to change priority and dependency ordering among
        /// streams.
        ///
        /// See [RFC 7540 § 6.3](https://httpwg.org/specs/rfc7540.html#rfc.section.6.3).
        case priority(StreamPriorityData)
        
        /// A RST_STREAM (reset stream) frame, sent when a stream has encountered an error
        /// condition and needs to be terminated as a result.
        ///
        /// See [RFC 7540 § 6.4](https://httpwg.org/specs/rfc7540.html#rfc.section.6.4).
        case rstStream(HTTP2ErrorCode)
        
        /// A SETTINGS frame, containing various connection--level settings and their
        /// desired values.
        ///
        /// See [RFC 7540 § 6.5](https://httpwg.org/specs/rfc7540.html#rfc.section.6.5).
        case settings([HTTP2Setting])
        
        /// A PUSH_PROMISE frame, used to notify a peer in advance of streams that a sender
        /// intends to initiate. It performs much like a request's HEADERS frame, informing
        /// a peer that the response for a theoretical request like the one in the promise
        /// will arrive on a new stream.
        ///
        /// As with the HEADERS frame, swift-nio-http2 will coalesce an initial PUSH_PROMISE
        /// frame with any CONTINUATION frames that follow, emitting a single
        /// `FramePayload.pushPromise` instance for the complete set.
        ///
        /// See [RFC 7540 § 6.6](https://httpwg.org/specs/rfc7540.html#rfc.section.6.6).
        ///
        /// For more information on server push in HTTP/2, see
        /// [RFC 7540 § 8.2](https://httpwg.org/specs/rfc7540.html#rfc.section.8.2).
        case pushPromise(HTTP2StreamID, HPACKHeaders)
        
        /// A PING frame, used to measure round-trip time between endpoints.
        ///
        /// See [RFC 7540 § 6.7](https://httpwg.org/specs/rfc7540.html#rfc.section.6.7).
        case ping(HTTP2PingData)
        
        /// A GOAWAY frame, used to request that a peer immediately cease communication with
        /// the sender. It contains a stream ID indicating the last stream that will be processed
        /// by the sender, an error code (if the shutdown was caused by an error), and optionally
        /// some additional diagnostic data.
        ///
        /// See [RFC 7540 § 6.8](https://httpwg.org/specs/rfc7540.html#rfc.section.6.8).
        case goAway(lastStreamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, opaqueData: ByteBuffer?)
        
        /// A WINDOW_UPDATE frame. This is used to implement flow control of DATA frames,
        /// allowing peers to advertise and update the amount of data they are prepared to
        /// process at any given moment.
        ///
        /// See [RFC 7540 § 6.9](https://httpwg.org/specs/rfc7540.html#rfc.section.6.9).
        case windowUpdate(windowSizeIncrement: Int)
        
        /// An ALTSVC frame. This is sent by an HTTP server to indicate alternative origin
        /// locations for accessing the same resource, for instance via another protocol,
        /// or over TLS. It consists of an origin and a list of alternate protocols and
        /// the locations at which they may be addressed.
        ///
        /// See [RFC 7838 § 4](https://tools.ietf.org/html/rfc7838#section-4).
        case alternativeService(origin: String?, field: ByteBuffer?)
        
        /// An ORIGIN frame. This allows servers which allow access to multiple origins
        /// via the same socket connection to identify which origins may be accessed in
        /// this manner.
        ///
        /// See [RFC 8336 § 2](https://tools.ietf.org/html/rfc8336#section-2).
        case origin([String])
        
        /// The one-byte identifier used to indicate the type of a frame on the wire.
        var code: UInt8 {
            switch self {
            case .data:                 return 0x0
            case .headers:              return 0x1
            case .priority:             return 0x2
            case .rstStream:            return 0x3
            case .settings:             return 0x4
            case .pushPromise:          return 0x5
            case .ping:                 return 0x6
            case .goAway:               return 0x7
            case .windowUpdate:         return 0x8
            case .alternativeService:   return 0xa
            case .origin:               return 0xc
            }
        }
        
        /// The set of flags that are permitted in the flags field of a particular frame.
        var allowedFlags: FrameFlags {
            switch self {
            case .data:
                return [.padded, .endStream]
            case .headers:
                return [.endStream, .endHeaders, .padded, .priority]
            case .pushPromise:
                return [.endHeaders, .padded]
            case .settings, .ping:
                return .ack
            case .priority, .rstStream, .goAway, .windowUpdate,
                 .alternativeService, .origin:
                return []
            }
        }
    }
    
    /// The flags supported by the frame types understood by this protocol.
    public struct FrameFlags: OptionSet, CustomStringConvertible {
        public typealias RawValue = UInt8
        
        public private(set) var rawValue: UInt8
        
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        /// END_STREAM flag. Valid on DATA and HEADERS frames.
        public static let endStream     = FrameFlags(rawValue: 0x01)
        
        /// ACK flag. Valid on SETTINGS and PING frames.
        public static let ack           = FrameFlags(rawValue: 0x01)
        
        /// END_HEADERS flag. Valid on HEADERS, CONTINUATION, and PUSH_PROMISE frames.
        public static let endHeaders    = FrameFlags(rawValue: 0x04)
        
        /// PADDED flag. Valid on DATA, HEADERS, CONTINUATION, and PUSH_PROMISE frames.
        ///
        /// NB: swift-nio-http2 does not automatically pad outgoing frames.
        public static let padded        = FrameFlags(rawValue: 0x08)
        
        /// PRIORITY flag. Valid on HEADERS frames, specifically as the first frame sent
        /// on a new stream.
        public static let priority      = FrameFlags(rawValue: 0x20)
        
        // useful for test cases
        internal static var allFlags: FrameFlags = [.endStream, .endHeaders, .padded, .priority]
        
        public var description: String {
            var strings: [String] = []
            for i in 0..<8 {
                let flagBit: UInt8 = 1 << i
                if (self.rawValue & flagBit) != 0 {
                    strings.append(String(flagBit, radix: 16, uppercase: true))
                }
            }
            return "[\(strings.joined(separator: ", "))]"
        }
    }
}


internal extension HTTP2Frame {
    internal init(streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.flags = flags.intersection(payload.allowedFlags)
        self.payload = payload
    }
    internal init(streamID: HTTP2StreamID, flags: UInt8, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.flags = FrameFlags(rawValue: flags).intersection(payload.allowedFlags)
        self.payload = payload
    }
}

public extension HTTP2Frame {
    /// Constructs a frame header for a given stream ID. All flags are unset.
    public init(streamID: HTTP2StreamID, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.flags = []
        self.payload = payload
    }
}
