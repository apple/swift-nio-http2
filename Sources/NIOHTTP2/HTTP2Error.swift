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
}


