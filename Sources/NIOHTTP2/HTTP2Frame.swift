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

// This file contains the data types used in the HTTP/2 channel pipeline.
//
// The HTTP/2 channel pipeline is a slightly complex entity with a number of channel handlers cooperating together to implement a
// full HTTP/2 stack. These handlers can be divided into three conceptual groups:
//
// 1. Core protocol handlers. These provide core protocol features and conformance, and require a deep understanding of the
//     behaviour of the state machine in the HTTP2Handler.
// 2. Non-core handlers. These handlers need the full frame information, but do not themselves participate in protocol
//     conformance.
// 3. Per-stream handlers. These handlers are usually part of a child HTTP2StreamChannel of the HTTP2StreamMultiplexer.
//     These handlers are tied to a single stream, and so gain no utility from being able to see or manipulate the HTTP2Frame
//     data type.
//
// For this reason, there are multiple data types used throughout the various parts of the HTTP/2 channel pipeline structure.
// Each of these can be thought of as a composition of one of the "less featureful" data types with the information needed to
// become more featureful.
//
// These data types are:
//
// 1. HTTP2FrameWithMetadata and HTTP2FrameWithMetadataRequest
// 2. HTTP2Frame
// 3. HTTP2FramePayload
//
// The numbers above correspond to their use-cases. The core protocol handlers use HTTP2FrameWithMetadata and
// HTTP2FrameWithMetadataRequest as their communication data types. The HTTP2StreamMultiplexer terminates the
// "core protocol handlers" portion of the pipeline, and so while its InboundIn and OutboundOut types are
// the HTTP2FrameWithMetadata[Request] types, the InboundOut and OutbounIn types are HTTP2Frame.
//
// Additionally, the HTTP2StreamMultiplexer communicates with the HTTP2StreamChannel by passing back and forth
// HTTP2Frame data structures. There is no need for the full spread of metadata on that interface anyway, as the interface
// can be rich and featureful due to the tight coupling of these two objects.
//
// Finally, the HTTP2StreamChannel belongs to a single stream. As a result, there is no value in passing the stream ID up and
// down the pipeline. Thus, the HTTP2StreamChannel has as its base currency type HTTP2FramePayload alone.
//
// The following diagram roughly shows the layout of the pipeline, as well as the objects that are passed through the read/write
// data paths of that part of the pipeline.
//
//              ┌────────────────┐
//              │                │
//              │                │
//              │  HTTP2Handler  │
//              │                │
//              │                │
//              └────────────────┘
//                 ▲          │
// HTTP2FrameWith  │          │ HTTP2FrameWithMetadata
// MetadataRequest │          │
//                 │          ▼
//              ┌────────────────┐
//              │                │
//              │      Flow      │
//              │    Control     │
//              │    Handler     │
//              │                │
//              └────────────────┘
//                 ▲          │
// HTTP2FrameWith  │          │ HTTP2FrameWithMetadata
// MetadataRequest │          │
//                 │          ▼
//              ┌────────────────┐
//              │                │
//              │   Concurrent   │
//              │    Streams     │
//              │    Handler     │
//              │                │
//              └────────────────┘
//                 ▲          │
// HTTP2FrameWith  │          │ HTTP2FrameWithMetadata
// MetadataRequest │          │
//                 │          ▼
//              ┌────────────────┐    HTTP2Frame     ┌  ─  ─  ─  ─  ─  ─
//              │                │─  ─  ─  ─  ─  ─  ▶│                   │
//              │     HTTP2      │                           0..n
//              │     Stream     │                        HTTP2Stream
//              │  Multiplexer   │                   │     Channels      │
//              │                │◀  ─  ─  ─  ─  ─  ─
//              └────────────────┘    HTTP2Frame      ─  ─  ─  ─  ─  ─  ─
//                 ▲          │
//   HTTP2Frame    │             HTTP2Frame
// (Stream 0 only)            │(Stream 0 only)
//                 │          ▼
//              ┌ ─ ─ ─ ─ ─ ─ ─ ─
//                               │
//              │
//                Other Handlers │
//              │
//                               │
//              └ ─ ─ ─ ─ ─ ─ ─ ─
//
// Metadata
// ========
//
// A reasonable question is: what is up with this "WithMetadata[Request]" construct?
//
// The core issue we have is that a single HTTP/2 frame has effects that are not, in isolation, very easy to determine.
// For example, how do we determine when a stream has been closed? A stream may be closed by a frame with END_STREAM set
// (sometimes), or by a RST_STREAM frame, or by a GOAWAY frame.
//
// The logic required to understand the semantic meaning of a given frame is basically the same as the complete HTTP/2
// state machine. Reproducing this state machine across multiple ChannelHandlers is not ideal. For this reason, we'd like
// a way for the state machine to communicate the semantic effects of a given frame.
//
// The "WithMetadata[Request]" data types allow the state machine to do just that. On the read path, the HTTP2Handler
// (which owns the state machine) generates not just a HTTP2Frame but also some associated frame metadata corresponding
// to the semantic effect of the frame. This is passed down the ChannelPipeline as a single unit.
//
// On the write path this is a bit trickier: it is not possible to know what the semantic effect of a given frame will
// be until it reaches the HTTP2Handler, which is necessarily the last ChannelHandler to see it. As a result, handlers
// are required to optimistically assume a certain property of the frame. If they are interested in knowing the certain
// final result, they can attach a MetadataRequest promise to the written frame data that will be satisfied with the
// frame metadata. This can be used to confirm the effect of the frame.
//
// Why not use User Events?
// ------------------------
//
// The standard NIO abstraction for communicating non-data semantic information about a Channel is to use User Events.
// Unfortunately user events are not a suitable replacement for the metadata construct because necessarily user events
// are *ordered* with respect to the frame that triggers them: they will be received either before or after the frame
// in question, rather than concurrently. This raises thorny questions about the order of the data delivery, as well
// as makes it very hard to confidently associate a specific state change with a single frame.
//
// As we're essentially distributing the core protocol implementation across multiple ChanneHandlers, it reasonable to
// consider the state machine result to be "data".


/// A single HTTP/2 frame, along with the state change it triggered in the state machine.
public struct HTTP2FrameWithMetadata {
    /// The received HTTP/2 frame.
    public var frame: HTTP2Frame

    /// The state change triggered in the connection.
    public var metadata: NIOHTTP2ConnectionStateChange

    public init(frame: HTTP2Frame, metadata: NIOHTTP2ConnectionStateChange) {
        self.frame = frame
        self.metadata = metadata
    }
}


/// A single HTTP/2 frame, along with an optional promise that will be fulfilled with
/// the state change triggered by parsing this frame.
public struct HTTP2FrameWithMetadataRequest {
    /// The HTTP/2 frame to send.
    public var frame: HTTP2Frame

    /// The promise to fulfil with the state change triggered by this frame, if any.
    ///
    /// This promise will be failed if the frame could not be sent because of an error.
    public var metadataRequest: EventLoopPromise<NIOHTTP2ConnectionStateChange>?

    public init(frame: HTTP2Frame, metadataRequest: EventLoopPromise<NIOHTTP2ConnectionStateChange>? = nil) {
        self.frame = frame
        self.metadataRequest = metadataRequest
    }
}

/// A representation of a single HTTP/2 frame.
public struct HTTP2Frame {
    /// The payload of this HTTP/2 frame.
    public var payload: FramePayload
    
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
        case data(FramePayload.Data)
        
        /// A HEADERS frame, containing all headers or trailers associated with a request
        /// or response.
        ///
        /// Note that swift-nio-http2 automatically coalesces HEADERS and CONTINUATION
        /// frames into a single `FramePayload.headers` instance.
        ///
        /// See [RFC 7540 § 6.2](https://httpwg.org/specs/rfc7540.html#rfc.section.6.2).
        case headers(Headers)
        
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
        case settings(Settings)
        
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
        case pushPromise(PushPromise)
        
        /// A PING frame, used to measure round-trip time between endpoints.
        ///
        /// See [RFC 7540 § 6.7](https://httpwg.org/specs/rfc7540.html#rfc.section.6.7).
        case ping(HTTP2PingData, ack: Bool)
        
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

        /// The payload of a DATA frame.
        public struct Data {
            /// The application data carried within the DATA frame.
            public var data: IOData

            /// The value of the END_STREAM flag on this frame.
            public var endStream: Bool

            /// The underlying number of padding bytes. If nil, no padding is present.
            internal private(set) var _paddingBytes: UInt8?

            /// The number of padding bytes sent in this frame. If nil, this frame was not padded.
            public var paddingBytes: Int? {
                get {
                    return self._paddingBytes.map { Int($0) }
                }
                set {
                    if let newValue = newValue {
                        precondition(newValue >= 0 && newValue <= Int(UInt8.max), "Invalid padding byte length: \(newValue)")
                        self._paddingBytes = UInt8(newValue)
                    } else {
                        self._paddingBytes = nil
                    }
                }
            }

            public init(data: IOData, endStream: Bool = false, paddingBytes: Int? = nil) {
                self.data = data
                self.endStream = endStream
                self.paddingBytes = paddingBytes
            }
        }

        /// The payload of a HEADERS frame.
        public struct Headers {
            /// The decoded header block belonging to this HEADERS frame.
            public var headers: HPACKHeaders

            /// The stream priority data transmitted on this frame, if any.
            public var priorityData: StreamPriorityData?

            /// The value of the END_STREAM flag on this frame.
            public var endStream: Bool

            /// The underlying number of padding bytes. If nil, no padding is present.
            internal private(set) var _paddingBytes: UInt8?

            /// The number of padding bytes sent in this frame. If nil, this frame was not padded.
            public var paddingBytes: Int? {
                get {
                    return self._paddingBytes.map { Int($0) }
                }
                set {
                    if let newValue = newValue {
                        precondition(newValue >= 0 && newValue <= Int(UInt8.max), "Invalid padding byte length: \(newValue)")
                        self._paddingBytes = UInt8(newValue)
                    } else {
                        self._paddingBytes = nil
                    }
                }
            }

            public init(headers: HPACKHeaders, priorityData: StreamPriorityData? = nil, endStream: Bool = false, paddingBytes: Int? = nil) {
                self.headers = headers
                self.priorityData = priorityData
                self.endStream = endStream
                self.paddingBytes = paddingBytes
            }
        }

        /// The payload of a SETTINGS frame.
        public enum Settings {
            /// This SETTINGS frame contains new SETTINGS.
            case settings(HTTP2Settings)

            /// This is a SETTINGS ACK.
            case ack
        }

        public struct PushPromise {
            /// The pushed stream ID.
            public var pushedStreamID: HTTP2StreamID

            /// The decoded header block belonging to this PUSH_PROMISE frame.
            public var headers: HPACKHeaders

            /// The underlying number of padding bytes. If nil, no padding is present.
            internal private(set) var _paddingBytes: UInt8?

            /// The number of padding bytes sent in this frame. If nil, this frame was not padded.
            public var paddingBytes: Int? {
                get {
                    return self._paddingBytes.map { Int($0) }
                }
                set {
                    if let newValue = newValue {
                        precondition(newValue >= 0 && newValue <= Int(UInt8.max), "Invalid padding byte length: \(newValue)")
                        self._paddingBytes = UInt8(newValue)
                    } else {
                        self._paddingBytes = nil
                    }
                }
            }

            public init(pushedStreamID: HTTP2StreamID, headers: HPACKHeaders, paddingBytes: Int? = nil) {
                self.headers = headers
                self.pushedStreamID = pushedStreamID
                self.paddingBytes = paddingBytes
            }
        }
        
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
    }
}

extension HTTP2Frame {
    /// Constructs a frame header for a given stream ID. All flags are unset.
    public init(streamID: HTTP2StreamID, payload: HTTP2Frame.FramePayload) {
        self.streamID = streamID
        self.payload = payload
    }
}
