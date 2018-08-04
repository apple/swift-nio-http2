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
import CNIONghttp2
import NIO

/// A single setting for HTTP/2, a combination of parameter identifier and its value.
public enum HTTP2Setting {
    /// SETTINGS_HEADER_TABLE_SIZE (0x1)
    ///
    /// Allows the sender to inform the remote endpoint of the maximum size of
    /// the header compression table used to decode header blocks, in octets. The
    /// encoder can select any size equal to or less than this value by using
    /// signaling specific to the header compression format inside a header block.
    /// The initial value is 4,096 octets.
    case headerTableSize(Int32)

    /// SETTINGS_ENABLE_PUSH (0x2)
    ///
    /// This setting can be used to disable server push. The initial value is `true`,
    /// which indicates that server push is permitted.
    case enablePush(Bool)

    /// SETTINGS_MAX_CONCURRENT_STREAMS (0x3)
    ///
    /// Indicates the maximum number of concurrent streams that the sender will
    /// allow. This limit is directional: it applies to the number of streams that
    /// the sender permits the receiver to create. Initially, there is no limit to
    /// this value. It is recommended that this value be no smaller than 100, so as
    /// to not unnecessarily limit parallelism.
    ///
    /// A value of 0 is legal, and will prevent the creation of new streams.
    case maxConcurrentStreams(Int32)

    /// SETTINGS_INITIAL_WINDOW_SIZE (0x4)
    ///
    /// Indicates the sender's initial window size (in octets) for stream-level
    /// flow control. The initial value is 2^16-1 (65,535) octets.
    ///
    /// Values above the maximum flow-control window size of 2^31-1 are illegal,
    /// and will result in a connection error.
    case initialWindowSize(Int32)

    /// SETTINGS_MAX_FRAME_SIZE (0x5)
    ///
    /// Indicates the size of the largest frame payload that the sender is willing
    /// to receive, in octets.
    ///
    /// The initial value is 2^14 (16,384) octets.  The value advertised by an
    /// endpoint MUST be between this initial value and the maximum allowed frame
    /// size (2^24-1 or 16,777,215 octets), inclusive.
    case maxFrameSize(Int32)

    /// SETTINGS_MAX_HEADER_LIST_SIZE (0x6)
    ///
    /// This advisory setting informs a peer of the maximum size of header list
    /// that the sender is prepared to accept, in octets.  The value is based on the
    /// uncompressed size of header fields, including the length of the name and
    /// value in octets plus an overhead of 32 octets for each header field.
    case maxHeaderListSize(Int32)

    /// SETTINGS_ACCEPT_CACHE_DIGEST (0x7)
    ///
    /// A server can notify its support for CACHE_DIGEST frame by sending this
    /// parameter with a value of `true`. If the server is tempted to make
    /// optimizations based on CACHE_DIGEST frames, it SHOULD send this parameter
    /// immediately after the connection is established.
    case acceptCacheDigest(Bool)

    /// SETTINGS_ENABLE_CONNECT_PROTOCOL (0x8)
    ///
    /// Upon receipt of this parameter with a value of `true`, a client MAY use
    /// the Extended CONNECT method when creating new streams, for example to
    /// bootstrap a WebSocket connection. Receipt of this parameter by a server
    /// does not have any impact.
    case enableConnectProtocol(Bool)

    /// The network representation of the identifier for this setting.
    internal var identifier: UInt16 {
        switch self {
        case .headerTableSize:          return 1
        case .enablePush:               return 2
        case .maxConcurrentStreams:     return 3
        case .initialWindowSize:        return 4
        case .maxFrameSize:             return 5
        case .maxHeaderListSize:        return 6
        case .acceptCacheDigest:        return 7
        case .enableConnectProtocol:    return 8
        }
    }

    /// Create a new `HTTP2Setting` from nghttp2's raw representation.
    internal init(fromNghttp2 setting: nghttp2_settings_entry) {
        switch UInt32(setting.settings_id) {
        case NGHTTP2_SETTINGS_HEADER_TABLE_SIZE.rawValue:
            self = .headerTableSize(Int32(setting.value))
        case NGHTTP2_SETTINGS_ENABLE_PUSH.rawValue:
            self = .enablePush(setting.value != 0)
        case NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS.rawValue:
            self = .maxConcurrentStreams(Int32(setting.value))
        case NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE.rawValue:
            self = .initialWindowSize(Int32(setting.value))
        case NGHTTP2_SETTINGS_MAX_FRAME_SIZE.rawValue:
            self = .maxFrameSize(Int32(setting.value))
        case NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE.rawValue:
            self = .maxHeaderListSize(Int32(setting.value))
        case 0x7:
            self = .acceptCacheDigest(setting.value != 0)
        case 0x8:
            self = .enableConnectProtocol(setting.value != 0)
        default:
            // nghttp2 doesn't support any other settings at this point
            fatalError("Unrecognised setting from nghttp2: \(setting.settings_id) : \(setting.value)")
        }
    }
}

extension HTTP2Setting: Equatable, Hashable {
    public static func == (lhs: HTTP2Setting, rhs: HTTP2Setting) -> Bool {
        switch (lhs, rhs) {
        case (.headerTableSize(let l), .headerTableSize(let r)),
             (.maxConcurrentStreams(let l), .maxConcurrentStreams(let r)),
             (.initialWindowSize(let l), .initialWindowSize(let r)),
             (.maxFrameSize(let l), .maxFrameSize(let r)),
             (.maxHeaderListSize(let l), .maxHeaderListSize(let r)):
            return l == r
        case (.enablePush(let l), .enablePush(let r)),
             (.acceptCacheDigest(let l), .acceptCacheDigest(let r)),
             (.enableConnectProtocol(let l), .enableConnectProtocol(let r)):
            return l == r
        default:
            return false
        }
    }
    
    public var hashValue: Int {
        switch self {
        case .headerTableSize(let v), .maxConcurrentStreams(let v), .initialWindowSize(let v),
             .maxFrameSize(let v), .maxHeaderListSize(let v):
            return Int(self.identifier) * 31 + Int(v)
        case .enablePush(let b), .acceptCacheDigest(let b), .enableConnectProtocol(let b):
            return Int(self.identifier) & 31 + (b ? 1 : 0)
        }
    }
}

internal extension nghttp2_settings_entry {
    internal init(nioSetting: HTTP2Setting) {
        switch nioSetting {
        case .headerTableSize(let v):
            self.init(settings_id: Int32(NGHTTP2_SETTINGS_HEADER_TABLE_SIZE.rawValue), value: UInt32(v))
        case .enablePush(let v):
            self.init(settings_id: Int32(NGHTTP2_SETTINGS_ENABLE_PUSH.rawValue), value: v ? 1 : 0)
        case .maxConcurrentStreams(let v):
            self.init(settings_id: Int32(NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS.rawValue), value: UInt32(v))
        case .initialWindowSize(let v):
            self.init(settings_id: Int32(NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE.rawValue), value: UInt32(v))
        case .maxFrameSize(let v):
            self.init(settings_id: Int32(NGHTTP2_SETTINGS_MAX_FRAME_SIZE.rawValue), value: UInt32(v))
        case .maxHeaderListSize(let v):
            self.init(settings_id: Int32(NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE.rawValue), value: UInt32(v))
        case .acceptCacheDigest(let v):
            self.init(settings_id: 0x7, value: v ? 1 : 0)
        case .enableConnectProtocol(let v):
            self.init(settings_id: 0x8, value: v ? 1 : 0)
        }
    }
}

extension HTTP2Setting {
    // nullable *and* throws? Invalid data causes an error, but unknown setting types return 'nil' quietly.
    static func decode(from buffer: inout ByteBuffer) throws -> HTTP2Setting? {
        precondition(buffer.readableBytes >= 6)
        
        let identifier: UInt16 = buffer.readInteger()!
        let value: Int32 = buffer.readInteger()!
        
        switch identifier {
        case 0x1:
            return .headerTableSize(value)
        case 0x2:
            guard value == 0 || value == 1 else {
                throw NIOHTTP2Errors.InvalidSettings(setting: identifier, value: value, errorCode: .protocolError)
            }
            return .enablePush(value != 0)
        case 0x3:
            return .maxConcurrentStreams(value)
        case 0x4:
            // yes, this looks weird. Yes, value is an Int32. Yes, this condition is stipulated in the
            // protocol specification.
            guard value <= UInt32.max else {
                throw NIOHTTP2Errors.InvalidSettings(setting: identifier, value: value, errorCode: .flowControlError)
            }
            return .initialWindowSize(value)
        case 0x5:
            guard value <= 16_777_215 else {
                throw NIOHTTP2Errors.InvalidSettings(setting: identifier, value: value, errorCode: .protocolError)
            }
            return .maxFrameSize(value)
        case 0x6:
            return .maxHeaderListSize(value)
        case 0x7:
            guard value == 0 || value == 1 else {
                throw NIOHTTP2Errors.InvalidSettings(setting: identifier, value: value, errorCode: .protocolError)
            }
            return .acceptCacheDigest(value != 0)
        case 0x8:
            guard value == 0 || value == 1 else {
                throw NIOHTTP2Errors.InvalidSettings(setting: identifier, value: value, errorCode: .protocolError)
            }
            return .enableConnectProtocol(value != 0)
        default:
            // ignore any unknown settings
            return nil
        }
    }

    func compile(to buffer: inout ByteBuffer) {
        buffer.write(integer: self.identifier)
        switch self {
        case .headerTableSize(let v),
             .maxConcurrentStreams(let v),
             .initialWindowSize(let v),
             .maxFrameSize(let v),
             .maxHeaderListSize(let v):
            buffer.write(integer: v)
        case .enablePush(let b),
             .acceptCacheDigest(let b),
             .enableConnectProtocol(let b):
            buffer.write(integer: Int32(b ? 1 : 0))
        }
    }
}
