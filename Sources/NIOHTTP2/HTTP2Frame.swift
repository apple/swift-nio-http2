//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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
import NIOHTTP1

/// A representation of a single HTTP/2 frame.
public struct HTTP2Frame: Sendable {

    /// The ID representing the stream on which this frame is sent.
    public var streamID: HTTP2StreamID

    /// The payload of this HTTP/2 frame.
    public var payload: FramePayload

    /// Stream priority data, used in PRIORITY frames and optionally in HEADERS frames.
    public struct StreamPriorityData: Equatable, Hashable, Sendable {
        public var dependency: HTTP2StreamID
        public var exclusive: Bool
        public var weight: UInt8

        public init(exclusive: Bool, dependency: HTTP2StreamID, weight: UInt8) {
            self.exclusive = exclusive
            self.dependency = dependency
            self.weight = weight
        }
    }

    /// Frame-type-specific payload data.
    public enum FramePayload {
        /// A `DATA` frame, containing raw bytes.
        ///
        /// See [RFC 7540 § 6.1](https://httpwg.org/specs/rfc7540.html#rfc.section.6.1).
        case data(FramePayload.Data)

        /// A `HEADERS` frame, containing all headers or trailers associated with a request
        /// or response.
        ///
        /// Note that swift-nio-http2 automatically coalesces `HEADERS` and `CONTINUATION`
        /// frames into a single ``HTTP2Frame/FramePayload/headers(_:)`` instance.
        ///
        /// See [RFC 7540 § 6.2](https://httpwg.org/specs/rfc7540.html#rfc.section.6.2).
        case headers(Headers)

        /// A `PRIORITY` frame, used to change priority and dependency ordering among
        /// streams.
        ///
        /// See [RFC 7540 § 6.3](https://httpwg.org/specs/rfc7540.html#rfc.section.6.3).
        case priority(StreamPriorityData)

        /// A `RST_STREAM` (reset stream) frame, sent when a stream has encountered an error
        /// condition and needs to be terminated as a result.
        ///
        /// See [RFC 7540 § 6.4](https://httpwg.org/specs/rfc7540.html#rfc.section.6.4).
        case rstStream(HTTP2ErrorCode)

        /// A `SETTINGS` frame, containing various connection--level settings and their
        /// desired values.
        ///
        /// See [RFC 7540 § 6.5](https://httpwg.org/specs/rfc7540.html#rfc.section.6.5).
        case settings(Settings)

        /// A `PUSH_PROMISE` frame, used to notify a peer in advance of streams that a sender
        /// intends to initiate. It performs much like a request's `HEADERS` frame, informing
        /// a peer that the response for a theoretical request like the one in the promise
        /// will arrive on a new stream.
        ///
        /// As with the `HEADERS` frame, `swift-nio-http2` will coalesce an initial `PUSH_PROMISE`
        /// frame with any `CONTINUATION` frames that follow, emitting a single
        /// ``HTTP2Frame/FramePayload/pushPromise(_:)`` instance for the complete set.
        ///
        /// See [RFC 7540 § 6.6](https://httpwg.org/specs/rfc7540.html#rfc.section.6.6).
        ///
        /// For more information on server push in HTTP/2, see
        /// [RFC 7540 § 8.2](https://httpwg.org/specs/rfc7540.html#rfc.section.8.2).
        indirect case pushPromise(PushPromise)

        /// A `PING` frame, used to measure round-trip time between endpoints.
        ///
        /// See [RFC 7540 § 6.7](https://httpwg.org/specs/rfc7540.html#rfc.section.6.7).
        case ping(HTTP2PingData, ack: Bool)

        /// A `GOAWAY` frame, used to request that a peer immediately cease communication with
        /// the sender. It contains a stream ID indicating the last stream that will be processed
        /// by the sender, an error code (if the shutdown was caused by an error), and optionally
        /// some additional diagnostic data.
        ///
        /// See [RFC 7540 § 6.8](https://httpwg.org/specs/rfc7540.html#rfc.section.6.8).
        indirect case goAway(lastStreamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, opaqueData: ByteBuffer?)

        /// A `WINDOW_UPDATE` frame. This is used to implement flow control of DATA frames,
        /// allowing peers to advertise and update the amount of data they are prepared to
        /// process at any given moment.
        ///
        /// See [RFC 7540 § 6.9](https://httpwg.org/specs/rfc7540.html#rfc.section.6.9).
        case windowUpdate(windowSizeIncrement: Int)

        /// An `ALTSVC` frame. This is sent by an HTTP server to indicate alternative origin
        /// locations for accessing the same resource, for instance via another protocol,
        /// or over TLS. It consists of an origin and a list of alternate protocols and
        /// the locations at which they may be addressed.
        ///
        /// See [RFC 7838 § 4](https://tools.ietf.org/html/rfc7838#section-4).
        ///
        /// - Important: ALTSVC frames are not currently supported. Any received ALTSVC frames will
        ///   be ignored. Attempting to send an ALTSVC frame will result in a fatal error.
        indirect case alternativeService(origin: String?, field: ByteBuffer?)

        /// An `ORIGIN` frame. This allows servers which allow access to multiple origins
        /// via the same socket connection to identify which origins may be accessed in
        /// this manner.
        ///
        /// See [RFC 8336 § 2](https://tools.ietf.org/html/rfc8336#section-2).
        ///
        /// > Important: `ORIGIN` frames are not currently supported. Any received `ORIGIN` frames will
        /// > be ignored. Attempting to send an `ORIGIN` frame will result in a fatal error.
        case origin([String])

        /// The payload of a `DATA` frame.
        public struct Data {
            /// The application data carried within the `DATA` frame.
            @inlinable
            public var data: IOData {
                get {
                    self._backing.data
                }
                set {
                    self._copyIfNeeded()
                    self._backing.data = newValue
                }
            }

            /// The value of the `END_STREAM` flag on this frame.
            @inlinable
            public var endStream: Bool {
                get {
                    self._backing.endStream
                }
                set {
                    self._copyIfNeeded()
                    self._backing.endStream = newValue
                }
            }

            /// The number of padding bytes sent in this frame. If nil, this frame was not padded.
            @inlinable
            public var paddingBytes: Int? {
                get {
                    self._backing.paddingBytes.map { Int($0) }
                }
                set {
                    self._copyIfNeeded()
                    if let newValue = newValue {
                        precondition(
                            newValue >= 0 && newValue <= Int(UInt8.max),
                            "Invalid padding byte length: \(newValue)"
                        )
                        self._backing.paddingBytes = UInt8(newValue)
                    } else {
                        self._backing.paddingBytes = nil
                    }
                }
            }

            @usableFromInline
            var _backing: _Backing

            @inlinable
            public init(data: IOData, endStream: Bool = false, paddingBytes: Int? = nil) {
                self._backing = _Backing(data: data, endStream: endStream, paddingBytes: paddingBytes.map { UInt8($0) })
            }

            @inlinable
            init(_ backing: _Backing) {
                self._backing = backing
            }

            @inlinable
            mutating func _copyIfNeeded() {
                if !isKnownUniquelyReferenced(&self._backing) {
                    self._backing = self._backing.copy()
                }
            }

            @usableFromInline
            final class _Backing {
                @usableFromInline
                var data: IOData

                @usableFromInline
                var endStream: Bool

                @usableFromInline
                var paddingBytes: UInt8?

                @inlinable
                init(data: IOData, endStream: Bool, paddingBytes: UInt8?) {
                    self.data = data
                    self.endStream = endStream
                    self.paddingBytes = paddingBytes
                }

                @inlinable
                func copy() -> _Backing {
                    _Backing(data: self.data, endStream: self.endStream, paddingBytes: self.paddingBytes)
                }
            }
        }

        /// The payload of a `HEADERS` frame.
        public struct Headers: Sendable {
            /// An OptionSet that keeps track of the various boolean flags in HEADERS.
            /// It allows us to elide having our two optionals by keeping track of their
            /// optionality here, which frees up a byte and keeps the total size of
            /// HTTP2Frame at 24 bytes.
            @usableFromInline
            struct Booleans: OptionSet, Sendable, Hashable {
                @usableFromInline
                var rawValue: UInt8

                @inlinable
                init(rawValue: UInt8) {
                    self.rawValue = rawValue
                }

                @usableFromInline static let endStream = Booleans(rawValue: 1 << 0)
                @usableFromInline static let priorityPresent = Booleans(rawValue: 1 << 1)
                @usableFromInline static let paddingPresent = Booleans(rawValue: 1 << 2)
            }

            /// The decoded header block belonging to this `HEADERS` frame.
            public var headers: HPACKHeaders

            /// Stream priority data.
            ///
            /// If `.priorityPresent` is not set in our boolean flags, this value is ignored.
            @usableFromInline
            var _priorityData: StreamPriorityData

            /// The number of padding bytes in this frame.
            ///
            /// If `.paddingPresent` is not set in our boolean flags, this value is ignored.
            @usableFromInline
            var _paddingBytes: UInt8

            /// Boolean flags that control the presence of other values in this frame.
            @usableFromInline
            var booleans: Booleans

            /// The stream priority data transmitted on this frame, if any.
            @inlinable
            public var priorityData: StreamPriorityData? {
                get {
                    if self.booleans.contains(.priorityPresent) {
                        return self._priorityData
                    } else {
                        return nil
                    }
                }
                set {
                    if let newValue = newValue {
                        self._priorityData = newValue
                        self.booleans.insert(.priorityPresent)
                    } else {
                        self.booleans.remove(.priorityPresent)
                    }
                }
            }

            /// The value of the `END_STREAM` flag on this frame.
            @inlinable
            public var endStream: Bool {
                get {
                    self.booleans.contains(.endStream)
                }
                set {
                    if newValue {
                        self.booleans.insert(.endStream)
                    } else {
                        self.booleans.remove(.endStream)
                    }
                }
            }

            /// The number of padding bytes sent in this frame. If nil, this frame was not padded.
            @inlinable
            public var paddingBytes: Int? {
                get {
                    if self.booleans.contains(.paddingPresent) {
                        return Int(self._paddingBytes)
                    } else {
                        return nil
                    }
                }
                set {
                    if let newValue = newValue {
                        precondition(
                            newValue >= 0 && newValue <= Int(UInt8.max),
                            "Invalid padding byte length: \(newValue)"
                        )
                        self._paddingBytes = UInt8(newValue)
                        self.booleans.insert(.paddingPresent)
                    } else {
                        self.booleans.remove(.paddingPresent)
                    }
                }
            }

            public init(
                headers: HPACKHeaders,
                priorityData: StreamPriorityData? = nil,
                endStream: Bool = false,
                paddingBytes: Int? = nil
            ) {
                self.headers = headers
                self.booleans = .init(rawValue: 0)
                self._paddingBytes = 0
                self._priorityData = StreamPriorityData(exclusive: false, dependency: .rootStream, weight: 0)

                self.priorityData = priorityData
                self.endStream = endStream
                self.paddingBytes = paddingBytes
            }
        }

        /// The payload of a `SETTINGS` frame.
        public enum Settings: Sendable {
            /// This `SETTINGS` frame contains new `SETTINGS`.
            case settings(HTTP2Settings)

            /// This is a `SETTINGS` `ACK`.
            case ack
        }

        /// The payload of a `PUSH_PROMISE` frame.
        public struct PushPromise: Sendable {
            /// The pushed stream ID.
            public var pushedStreamID: HTTP2StreamID

            /// The decoded header block belonging to this `PUSH_PROMISE` frame.
            public var headers: HPACKHeaders

            /// The underlying number of padding bytes. If nil, no padding is present.
            internal private(set) var _paddingBytes: UInt8?

            /// The number of padding bytes sent in this frame. If nil, this frame was not padded.
            public var paddingBytes: Int? {
                get {
                    self._paddingBytes.map { Int($0) }
                }
                set {
                    if let newValue = newValue {
                        precondition(
                            newValue >= 0 && newValue <= Int(UInt8.max),
                            "Invalid padding byte length: \(newValue)"
                        )
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
            case .data: return 0x0
            case .headers: return 0x1
            case .priority: return 0x2
            case .rstStream: return 0x3
            case .settings: return 0x4
            case .pushPromise: return 0x5
            case .ping: return 0x6
            case .goAway: return 0x7
            case .windowUpdate: return 0x8
            case .alternativeService: return 0xa
            case .origin: return 0xc
            }
        }
    }

    /// Constructs a frame header for a given stream ID.
    public init(streamID: HTTP2StreamID, payload: HTTP2Frame.FramePayload) {
        self.payload = payload
        self.streamID = streamID
    }
}

extension HTTP2Frame.FramePayload {
    /// A shorthand heuristic for how many bytes we assume a frame contributes to flow control calculations.
    ///
    /// Here we concern ourselves only with per-stream `DATA` frames.
    ///
    /// Flow control does not take into account the 9-byte frame header (https://www.rfc-editor.org/rfc/rfc9113.html#section-6.9.1).
    var flowControlledSize: Int {
        switch self {
        case .data(let d):
            let paddingBytes = d.paddingBytes.map { $0 + 1 } ?? 0
            return d.data.readableBytes + paddingBytes
        case .headers, .priority, .pushPromise, .rstStream, .windowUpdate:
            //  say 0 bytes because flow control only cares about DATA frames
            return 0
        default:
            // Unknown or unexpected control frame: say 0 bytes because flow control only cares about DATA frames
            return 0
        }
    }
}

/// ``HTTP2Frame/FramePayload/Data`` and therefore ``HTTP2Frame/FramePayload`` and ``HTTP2Frame`` are actually **not** `Sendable`,
/// because ``HTTP2Frame/FramePayload/Data/data`` stores `IOData` which is not and can not be `Sendable`.
/// Marking them non-Sendable would sadly be API breaking.
extension HTTP2Frame.FramePayload: @unchecked Sendable {}
extension HTTP2Frame.FramePayload.Data: @unchecked Sendable {}
