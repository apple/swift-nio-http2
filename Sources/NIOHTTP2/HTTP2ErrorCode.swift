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

/// HTTP/2 error codes that may be found in frames at the HTTP/2 level.
public enum HTTP2ErrorCode {
    /// The associated condition is not a result of an error. For example,
    /// a GOAWAY might include this code to indicate graceful shutdown of
    /// a connection.
    case noError

    /// The endpoint detected an unspecific protocol error. This error is
    /// for use when a more specific error code is not available.
    case protocolError

    /// The endpoint encountered an unexpected internal error.
    case internalError

    /// The endpoint detected that its peer violated the flow-control
    /// protocol.
    case flowControlError

    /// The endpoint sent a SETTINGS frame but did not receive a
    /// response in a timely manner.
    case settingsTimeout

    /// The endpoint received a frame after a stream was half-closed.
    case streamClosed

    /// The endpoint received a frame with an invalid size.
    case frameSizeError

    /// The endpoint refused the stream prior to performing any
    /// application processing.
    case refusedStream

    /// Used by the endpoint to indicate that the stream is no
    /// longer needed.
    case cancel

    /// The endpoint is unable to maintain the header compression
    /// context for the connection.
    case compressionError

    /// The connection established in response to a CONNECT request
    /// was reset or abnormally closed.
    case connectError

    /// The endpoint detected that its peer is exhibiting a behavior
    /// that might be generating excessive load.
    case enhanceYourCalm

    /// The underlying transport has properties that do not meet
    /// minimum security requirements.
    case inadequateSecurity

    /// The endpoint requires that HTTP/1.1 be used instead of HTTP/2.
    case http11Required

    /// The error code is not known to NIO.
    case unknown(UInt32)
}

public extension HTTP2ErrorCode {
    /// Create a `HTTP2ErrorCode` from the 32-bit integer it corresponds to.
    public init(_ networkInteger: UInt32) {
        switch networkInteger {
        case 0x0:
            self = .noError
        case 0x1:
            self = .protocolError
        case 0x2:
            self = .internalError
        case 0x3:
            self = .flowControlError
        case 0x4:
            self = .settingsTimeout
        case 0x5:
            self = .streamClosed
        case 0x6:
            self = .frameSizeError
        case 0x7:
            self = .refusedStream
        case 0x8:
            self = .cancel
        case 0x9:
            self = .compressionError
        case 0xa:
            self = .connectError
        case 0xb:
            self = .enhanceYourCalm
        case 0xc:
            self = .inadequateSecurity
        case 0xd:
            self = .http11Required
        default:
            self = .unknown(networkInteger)
        }
    }

    /// Create a `HTTP2ErrorCode` from the integer it corresponds to.
    public init(_ userInteger: Int) {
        self.init(UInt32(userInteger))
    }
}

public extension UInt32 {
    /// Create a 32-bit integer corresponding to the given `HTTP2ErrorCode`.
    public init(http2ErrorCode code: HTTP2ErrorCode) {
        switch code {
        case .noError:
            self = 0x0
        case .protocolError:
            self = 0x1
        case .internalError:
            self = 0x2
        case .flowControlError:
            self = 0x3
        case .settingsTimeout:
            self = 0x4
        case .streamClosed:
            self = 0x5
        case .frameSizeError:
            self = 0x6
        case .refusedStream:
            self = 0x7
        case .cancel:
            self = 0x8
        case .compressionError:
            self = 0x9
        case .connectError:
            self = 0xa
        case .enhanceYourCalm:
            self = 0xb
        case .inadequateSecurity:
            self = 0xc
        case .http11Required:
            self = 0xd
        case .unknown(let val):
            self = val
        }
    }
}

public extension Int {
    /// Create an integer corresponding to the given `HTTP2ErrorCode`.
    public init(http2ErrorCode code: HTTP2ErrorCode) {
        self = Int(UInt32(http2ErrorCode: code))
    }
}

public extension ByteBuffer {
    /// Serializes a `HTTP2ErrorCode` into a `ByteBuffer` in the appropriate endianness
    /// for use in HTTP/2.
    ///
    /// - parameters:
    ///     - code: The `HTTP2ErrorCode` to serialize.
    /// - returns: The number of bytes written.
    public mutating func write(http2ErrorCode code: HTTP2ErrorCode) -> Int {
        return self.write(integer: UInt32(http2ErrorCode: code))
    }
}
