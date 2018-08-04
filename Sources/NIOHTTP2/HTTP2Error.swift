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

public protocol NIOHTTP2Error: Equatable, Error { }

/// Errors that NIO raises when handling HTTP/2 connections.
public enum NIOHTTP2Errors {
    /// NIO's upgrade handler encountered a successful upgrade to a protocol that it
    /// does not recognise.
    public struct InvalidALPNToken: NIOHTTP2Error {
        public init() { }
    }

    /// An attempt was made to issue a write on a stream that does not exist.
    public struct NoSuchStream: NIOHTTP2Error {
        /// The stream ID that was used that does not exist.
        public var streamID: HTTP2StreamID

        public init(streamID: HTTP2StreamID) {
            self.streamID = streamID
        }
    }

    /// A stream was closed.
    public struct StreamClosed: NIOHTTP2Error {
        /// The stream ID that was closed.
        public var streamID: HTTP2StreamID

        /// The error code associated with the closure.
        public var errorCode: HTTP2ErrorCode

        public init(streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode) {
            self.streamID = streamID
            self.errorCode = errorCode
        }
    }

    public struct BadClientMagic: NIOHTTP2Error {
        public init() {}
    }

    public struct InternalError: NIOHTTP2Error {
        internal var nghttp2ErrorCode: nghttp2_error

        internal init(nghttp2ErrorCode: nghttp2_error) {
            self.nghttp2ErrorCode = nghttp2ErrorCode
        }
    }

    /// Received/decoded data was invalid.
    public struct InvalidSettings: NIOHTTP2Error {
        /// The network identifier of the setting being read.
        public var settingCode: UInt16
        
        /// The offending value.
        public var value: Int32

        /// The error code associated with the error.
        public var errorCode: HTTP2ErrorCode

        public init(setting: UInt16, value: Int32, errorCode: HTTP2ErrorCode) {
            self.settingCode = setting
            self.value = value
            self.errorCode = errorCode
        }
    }
}


