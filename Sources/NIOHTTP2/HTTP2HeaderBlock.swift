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
import NIOHTTP1

/// The type of header block. This carries along with it the HTTP head portion for
/// whatever the appropriate type is (either response or request).
public enum HTTP2HeadersCategory {
    case request(HTTPRequestHead)
    case response(HTTPResponseHead)
    case pushResponse(HTTPRequestHead)

    // TODO(cory): Non-final stuff goes here, but I don't know what to put here.
    case headers
}

// MARK:- Helpers for working with nghttp2 headers.
internal extension HTTP2HeadersCategory {
    /// Creates a NGHTTP2 header block for this HTTP/2 HEADERS frame.
    ///
    /// This function will handle placing in the appropriate pseudo-headers
    /// for HTTP/2 usage and obeying the ordering rules for those headers.
    internal func withNGHTTP2Headers(allocator: ByteBufferAllocator,
                                     _ body: (UnsafePointer<nghttp2_nv>, Int) -> Void) {
        var headerBlock = ContiguousHeaderBlock(buffer: allocator.buffer(capacity: 1024))
        self.writeHeaders(into: &headerBlock)

        var nghttpNVs: [nghttp2_nv] = []
        nghttpNVs.reserveCapacity(headerBlock.headerIndices.count)
        headerBlock.headerBuffer.withUnsafeMutableReadableBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for (hnBegin, hnLen, hvBegin, hvLen) in headerBlock.headerIndices {
                nghttpNVs.append(nghttp2_nv(name: base + hnBegin,
                                            value: base + hvBegin,
                                            namelen: hnLen,
                                            valuelen: hvLen,
                                            flags: 0))
            }
            nghttpNVs.withUnsafeMutableBufferPointer { nvPtr in
                body(nvPtr.baseAddress!, nvPtr.count)
            }
        }
    }

    /// Writes the header block.
    ///
    /// This function writes the headers corresponding to this type of header block into a byte
    /// buffer, recording their indices. This includes writing out any pseudo-headers that are
    /// needed, and ensuring that those pseudo-headers are written first.
    private func writeHeaders(into headerBlock: inout ContiguousHeaderBlock) {
        let headers: HTTPHeaders
        switch self {
        case .request(var h), .pushResponse(var h):
            // TODO(cory): This is potentially wrong if the URI contains more than just a path.
            headerBlock.writeHeader(name: ":path", value: h.uri)
            headerBlock.writeHeader(name: ":method", value: String(httpMethod: h.method))

            // TODO(cory): This is very wrong.
            headerBlock.writeHeader(name: ":scheme", value: "https")

            let authority = h.headers[canonicalForm: "host"]
            if authority.count > 0 {
                precondition(authority.count == 1)
                h.headers.remove(name: "host")
                headerBlock.writeHeader(name: ":authority", value: authority[0])
            }

            headers = h.headers
        case .response(let h):
            headerBlock.writeHeader(name: ":status", value: String(h.status.code))
            headers = h.headers
        case .headers:
            preconditionFailure("Currently no support for non-final headers")
        }

        headers.forEach { headerBlock.writeHeader(name: $0.name, value: $0.value) }
    }
}

/// A `ContiguousHeaderBlock` is a series of HTTP headers, written
/// out in name-value order into the same contiguous chunk of memory.
///
/// For now, this exists basically solely because we can't get access to the memory used
/// by the HTTP/1 `HTTPHeaders` structure, and to provide us some convenience methods.
private struct ContiguousHeaderBlock {
    var headerBuffer: ByteBuffer
    var headerIndices: [(Int, Int, Int, Int)] = []

    init(buffer: ByteBuffer) {
        self.headerBuffer = buffer
    }

    /// Writes the given name/value pair into the header block and records where we
    /// wrote it.
    mutating func writeHeader(name: String, value: String) {
        let headerNameBegin = self.headerBuffer.writerIndex
        let headerNameLen = self.headerBuffer.write(string: name)!
        let headerValueBegin = self.headerBuffer.writerIndex
        let headerValueLen = self.headerBuffer.write(string: value)!
        self.headerIndices.append((headerNameBegin, headerNameLen, headerValueBegin, headerValueLen))
    }
}

extension nghttp2_headers_category {
    init(headersCategory: HTTP2HeadersCategory) {
        switch headersCategory {
        case .request:
            self = NGHTTP2_HCAT_REQUEST
        case .response:
            self = NGHTTP2_HCAT_RESPONSE
        case .pushResponse:
            self = NGHTTP2_HCAT_PUSH_RESPONSE
        case .headers:
            self = NGHTTP2_HCAT_HEADERS
        }
    }
}

// MARK:- Methods for creating `HTTPRequestHead`/`HTTPResponseHead` objects from header blocks generated by nghttp2.
internal extension HTTPRequestHead {
    /// Create a `HTTPRequestHead` from the header block produced by nghttp2.
    init(http2HeaderBlock headers: HTTPHeaders) {
        // Take a local copy here.
        var headers = headers

        // A request head should have only up to four psuedo-headers. We strip them off.
        // TODO(cory): Error handling!
        let method = HTTPMethod(methodString: headers.popPseudoHeader(name: ":method")!)
        let version = HTTPVersion(major: 2, minor: 0)
        let uri = headers.popPseudoHeader(name: ":path")!

        // TODO(cory): Right now we're just stripping these two, but they should probably be translated
        // into something else, authority in particular.
        headers.remove(name: ":scheme")
        headers.remove(name: ":authority")

        self.init(version: version, method: method, uri: uri)
        self.headers = headers
    }
}

private extension HTTPHeaders {
    /// Grabs a pseudo-header from a header block and removes it from that block.
    ///
    /// - parameter:
    ///     - name: The header name to remove.
    /// - returns: The array of values for this pseudo-header, or `nil` if the header
    ///     is not in the block.
    mutating func popPseudoHeader(name: String) -> String? {
        // TODO(cory): This should be upstreamed becuase right now we loop twice instead
        // of once.
        let value = self[name]
        if value.count == 1 {
            self.remove(name: name)
            return value.first!
        }
        // TODO(cory): Proper error handling here please.
        precondition(value.count == 0, "ETOOMANYPSEUDOHEADERVALUES")
        return nil
    }
}

private extension HTTPMethod {
    /// Create a `HTTPMethod` from the string representation of that method.
    init(methodString: String) {
        switch methodString {
        case "GET":
            self = .GET
        case "PUT":
            self = .PUT
        case "ACL":
            self = .ACL
        case "HEAD":
            self = .HEAD
        case "POST":
            self = .POST
        case "COPY":
             self = .COPY
        case "LOCK":
            self = .LOCK
        case "MOVE":
            self = .MOVE
        case "BIND":
            self = .BIND
        case "LINK":
            self = .LINK
        case "PATCH":
            self = .PATCH
        case "TRACE":
            self = .TRACE
        case "MKCOL":
            self = .MKCOL
        case "MERGE":
            self = .MERGE
        case "PURGE":
            self = .PURGE
        case "NOTIFY":
            self = .NOTIFY
        case "SEARCH":
            self = .SEARCH
        case "UNLOCK":
            self = .UNLOCK
        case "REBIND":
            self = .REBIND
        case "UNBIND":
            self = .UNBIND
        case "REPORT":
            self = .REPORT
        case "DELETE":
            self = .DELETE
        case "UNLINK":
            self = .UNLINK
        case "CONNECT":
            self = .CONNECT
        case "MSEARCH":
            self = .MSEARCH
        case "OPTIONS":
            self = .OPTIONS
        case "PROPFIND":
            self = .PROPFIND
        case "CHECKOUT":
            self = .CHECKOUT
        case "PROPPATCH":
            self = .PROPPATCH
        case "SUBSCRIBE":
            self = .SUBSCRIBE
        case "MKCALENDAR":
            self = .MKCALENDAR
        case "MKACTIVITY":
            self = .MKACTIVITY
        case "UNSUBSCRIBE":
            self = .UNSUBSCRIBE
        default:
            self = .RAW(value: methodString)
        }
    }
}

private extension String {
    /// Create a `HTTPMethod` from the string representation of that method.
    init(httpMethod: HTTPMethod) {
        switch httpMethod {
        case .GET:
            self = "GET"
        case .PUT:
            self = "PUT"
        case .ACL:
            self = "ACL"
        case .HEAD:
            self = "HEAD"
        case .POST:
            self = "POST"
        case .COPY:
            self = "COPY"
        case .LOCK:
            self = "LOCK"
        case .MOVE:
            self = "MOVE"
        case .BIND:
            self = "BIND"
        case .LINK:
            self = "LINK"
        case .PATCH:
            self = "PATCH"
        case .TRACE:
            self = "TRACE"
        case .MKCOL:
            self = "MKCOL"
        case .MERGE:
            self = "MERGE"
        case .PURGE:
            self = "PURGE"
        case .NOTIFY:
            self = "NOTIFY"
        case .SEARCH:
            self = "SEARCH"
        case .UNLOCK:
            self = "UNLOCK"
        case .REBIND:
            self = "REBIND"
        case .UNBIND:
            self = "UNBIND"
        case .REPORT:
            self = "REPORT"
        case .DELETE:
            self = "DELETE"
        case .UNLINK:
            self = "UNLINK"
        case .CONNECT:
            self = "CONNECT"
        case .MSEARCH:
            self = "MSEARCH"
        case .OPTIONS:
            self = "OPTIONS"
        case .PROPFIND:
            self = "PROPFIND"
        case .CHECKOUT:
            self = "CHECKOUT"
        case .PROPPATCH:
            self = "PROPPATCH"
        case .SUBSCRIBE:
            self = "SUBSCRIBE"
        case .MKCALENDAR:
            self = "MKCALENDAR"
        case .MKACTIVITY:
            self = "MKACTIVITY"
        case .UNSUBSCRIBE:
            self = "UNSUBSCRIBE"
        case .RAW(let v):
            self = v
        }
    }
}

