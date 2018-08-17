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

    /// The frame flags.
    public var flags: FrameFlags
    
    /// The frame stream ID as a 32-bit integer.
    public var streamID: HTTP2StreamID
    
    private func _hasFlag(_ flag: FrameFlags) -> Bool {
        return self.flags.contains(flag)
    }
    
    private mutating func _setFlagIfValid(_ flag: FrameFlags) {
        if self.payload.allowedFlags.contains(flag) {
            self.flags.formUnion(flag)
        }
    }
    
    // Whether the END_STREAM flag bit is set.
    public var endStream: Bool {
        get { return self._hasFlag(.endStream) }
        set { self._setFlagIfValid(.endStream) }
    }
    
    // Whether the PADDED flag bit is set.
    public var padded: Bool {
        get { return self._hasFlag(.padded) }
        set { self._setFlagIfValid(.padded) }
    }
    
    // Whether the PRIORITY flag bit is set.
    public var priority: Bool {
        get { return self._hasFlag(.priority) }
        set { self._setFlagIfValid(.priority) }
    }
    
    // Whether the ACK flag bit is set.
    public var ack: Bool {
        get { return self._hasFlag(.ack) }
        set { self._setFlagIfValid(.ack) }
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
        case alternativeService(origin: String?, field: ByteBuffer?)
        case origin([String])
        
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
    
    public struct FrameFlags : OptionSet {
        public typealias RawValue = UInt8
        
        public private(set) var rawValue: UInt8
        
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        public static let endStream     = FrameFlags(rawValue: 0x01)
        public static let ack           = FrameFlags(rawValue: 0x01)
        public static let endHeaders    = FrameFlags(rawValue: 0x04)
        public static let padded        = FrameFlags(rawValue: 0x08)
        public static let priority      = FrameFlags(rawValue: 0x20)
        
        // useful for test cases
        internal static var allFlags: FrameFlags = [.endStream, .endHeaders, .padded, .priority]
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
