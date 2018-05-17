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

import NIOHTTP1

private extension HTTPHeaders {
    /// Whether this `HTTPHeaders` corresponds to a final response or not.
    ///
    /// This property is only valid if called on a response header block. If the :status header
    /// is not present, this will crash.
    var isInformationalResponse: Bool {
        return self.first { $0.name == ":status" }!.value.first == "1"
    }
}

/// A state machine that keeps track of the header blocks sent or received and that determines the type of any
/// new header block.
struct HTTP2HeadersStateMachine {
    /// The list of possible header frame types.
    ///
    /// This is used in combination with introspection of the HTTP header blocks to determine what HTTP header block
    /// a certain HTTP header is.
    enum HeaderType {
        /// A request header block.
        case requestHead

        /// An informational response header block. These can be sent zero or more times.
        case informationalResponseHead

        /// A final response header block.
        case finalResponseHead

        /// A trailer block. Once this is sent no further header blocks are acceptable.
        case trailer
    }

    /// The previous header block.
    private var previousHeader: HeaderType?

    /// The mode of this connection: client or server.
    private let mode: HTTP2Parser.ParserMode

    init(mode: HTTP2Parser.ParserMode) {
        self.mode = mode
    }

    /// Called when about to process a HTTP headers block to determine its type.
    mutating func newHeaders(block: HTTPHeaders) -> HeaderType {
        let newType: HeaderType

        switch (self.mode, self.previousHeader) {
        case (.client, .none):
            // The first header block on a client mode stream must be a request block.
            newType = .requestHead
        case (.server, .none),
             (.server, .some(.informationalResponseHead)):
            // The first header block on a server mode stream may be either informational or final,
            // depending on the value of the :status pseudo-header. Alternatively, if the previous
            // header block was informational, the same possibilities apply.
            newType = block.isInformationalResponse ? .informationalResponseHead : .finalResponseHead
        case (.client, .some(.requestHead)),
             (.server, .some(.finalResponseHead)):
            // If the client has already sent a request head, or the server has already sent a final response,
            // this is a trailer block.
            newType = .trailer
        case (.client, .some(.informationalResponseHead)),
             (.client, .some(.finalResponseHead)),
             (.server, .some(.requestHead)):
            // These states should not be reachable!
            preconditionFailure("Invalid internal state!")
        case (.client, .some(.trailer)),
             (.server, .some(.trailer)):
            // TODO(cory): This should probably throw, as this can happen in malformed programs without the world ending.
            preconditionFailure("Sending too many header blocks.")
        }

        self.previousHeader = newType
        return newType
    }
}

/// An object that encapsulates all the state management information for a single HTTP/2 stream.
///
/// nghttp2 requires that we maintain a decent amount of internal state on a per-stream basis. At the very least
/// we need a data provider and a state machine to work out what type of headers we're handling based on context.
///
/// For each stream, we store one of these objects as the opaque data that nghttp2 will provide us for stream-specific
/// operations. This is then used to handle this kind of stream specific processing.
final class HTTP2Stream {
    /// The stream ID for this stream.
    let streamID: HTTP2StreamID

    /// The HTTP/2 data provider for this stream. This is used to manage dispatching both HTTP/2 DATA frames and
    /// HEADERS frames that are shipped in trailers.
    let dataProvider: HTTP2DataProvider

    /// Whether this stream is still active on the connection. Streams that are not active on the connection are
    /// safe to prune.
    var active: Bool = false

    /// The headers state machine for outbound headers.
    ///
    /// Currently we do not maintain one of these for inbound headers because nghttp2 doesn't require it of us, but
    /// in the future we may want to do so.
    private var outboundHeaderStateMachine: HTTP2HeadersStateMachine

    init(mode: HTTP2Parser.ParserMode, streamID: HTTP2StreamID) {
        self.outboundHeaderStateMachine = HTTP2HeadersStateMachine(mode: mode)
        self.streamID = streamID
        self.dataProvider = HTTP2DataProvider()
    }

    /// Called to determine the type of a new outbound header block, so as to manage it appropriately.
    func newOutboundHeaderBlock(block: HTTPHeaders) -> HTTP2HeadersStateMachine.HeaderType {
        precondition(self.active)
        return self.outboundHeaderStateMachine.newHeaders(block: block)
    }
}
