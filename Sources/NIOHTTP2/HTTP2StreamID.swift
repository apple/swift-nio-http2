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

/// A single HTTP/2 stream ID.
///
/// Every stream in HTTP/2 has a unique 31-bit stream ID. This stream ID monotonically
/// increases over the lifetime of the connection. In most situations, a NIO HTTP/2
/// channel pipeline will know the concrete stream IDs for all frames that traverse
/// the pipeline, but in some cases the concrete stream ID may not be known. This
/// primarily occurs when sending the initial frames of a stream on the client side,
/// where NIO attempts to allocate the stream ID as late as possible to ensure the
/// stream is successfully created and reduce error rates.
///
/// This structure allows a NIO channel pipeline to operate on the abstract notion
/// of a stream ID, rather than relying on the specific 31-bit integers. It deals
/// with the situation where a new stream is being created and the concrete stream
/// ID is not yet known, and ensures that even when that stream ID does become known
/// the notion of "equality" is preserved.
///
/// Note that it is not possible to create a "free" `HTTP2StreamID` from an integer.
/// This is an intentional limitation. In general users should copy `HTTPStreamID`s
/// around or store them for later use. An abstract `HTTP2StreamID` can be created
/// whenever a new stream is to be created (e.g. for sending requests or push
/// promises, or for more complex priority tree manipulation).
///
/// Note that while `HTTP2StreamID`s are value types, they are not thread-safe: it is
/// not safe to share them across threads. This limitation is reasonable, as stream
/// IDs are not meaningful outside of their connection.
// TODO(cory): We can remove this thread-safety limitation by embedding an atomic
// here, but NIO doesn't let us do it.
public class HTTP2StreamID {
    /// The actual stream ID. Set to a negative number in cases where we don't know the
    /// stream ID yet.
    fileprivate var actualStreamID: Int32 = -1

    /// The root stream on a HTTP/2 connection, stream 0.
    ///
    /// This can safely be used across all connections to identify stream 0.
    public static let rootStream: HTTP2StreamID = HTTP2StreamID(knownID: 0)

    /// The largest possible stream ID on a HTTP/2 connection.
    ///
    /// This should not usually be used to manage a specific stream. Instead, it's a sentinel
    /// that can be used to "quiesce" a HTTP/2 connection on a GOAWAY frame.
    public static let maxID: HTTP2StreamID = HTTP2StreamID(knownID: Int32.max)

    /// Create an abstract stream ID.
    ///
    /// An abstract stream ID represents a handle to a stream ID that may or may not yet
    /// have been reified on the network.
    public init() { }

    /// Create a `HTTP2StreamID` for a known network ID.
    ///
    /// This is used to initialize the global "stream 0" stream ID.
    internal init(knownID: Int32) {
        self.actualStreamID = knownID
    }

    /// The stream ID used on the network, if there is one.
    ///
    /// If the stream has not yet reached the network, this will return `nil`. It is only
    /// necessary to perform this lookup for debugging purposes, or if it is important to
    /// create store the actual stream ID somewhere.
    ///
    /// Note that while this returns an Int32, the value must always be greater than zero.
    public var networkStreamID: Int32? {
        return (self.actualStreamID >= 0) ? self.actualStreamID : nil
    }

    /// Resolve the abstract stream ID to a real one.
    internal func resolve(to newID: Int32) {
        precondition(self.actualStreamID == -1)
        self.actualStreamID = newID
    }
}

// MARK:- Equatable conformance for HTTP2StreamID
extension HTTP2StreamID: Equatable {
    public static func ==(lhs: HTTP2StreamID, rhs: HTTP2StreamID) -> Bool {
        return lhs === rhs
    }
}


// MARK:- Hashable conformance for HTTP2StreamID
extension HTTP2StreamID: Hashable {
    public var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}


extension HTTP2StreamID: CustomDebugStringConvertible {
    public var debugDescription: String {
        var streamIDDescription: String = "unknown"

        if let networkStreamID = self.networkStreamID {
            streamIDDescription = String(networkStreamID)
        }
        return "HTTP2StreamID(\(streamIDDescription))"
    }
}
