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

// MARK: - Client

fileprivate struct BaseClientCodec {
    private let protocolString: String
    private let normalizeHTTPHeaders: Bool

    private var headerStateMachine: HTTP2HeadersStateMachine = HTTP2HeadersStateMachine(mode: .client)

    /// Initializes a `BaseClientCodec`.
    ///
    /// - parameters:
    ///    - httpProtocol: The protocol (usually `"http"` or `"https"` that is used).
    ///    - normalizeHTTPHeaders: Whether to automatically normalize the HTTP headers to be suitable for HTTP/2.
    ///                            The normalization will for example lower-case all header names (as required by the
    ///                            HTTP/2 spec) and remove headers that are unsuitable for HTTP/2 such as
    ///                            headers related to HTTP/1's keep-alive behaviour. Unless you are sure that all your
    ///                            headers conform to the HTTP/2 spec, you should leave this parameter set to `true`.
    fileprivate init(httpProtocol: HTTP2FramePayloadToHTTP1ClientCodec.HTTPProtocol, normalizeHTTPHeaders: Bool) {
        self.normalizeHTTPHeaders = normalizeHTTPHeaders

        switch httpProtocol {
        case .http:
            self.protocolString = "http"
        case .https:
            self.protocolString = "https"
        }
    }

    mutating func processInboundData(_ data: HTTP2Frame.FramePayload) throws -> (first: HTTPClientResponsePart?, second: HTTPClientResponsePart?) {
        switch data {
        case .headers(let headerContent):
            if case .trailer = try self.headerStateMachine.newHeaders(block: headerContent.headers) {
                return (first: .end(HTTPHeaders(regularHeadersFrom: headerContent.headers)), second: nil)
            } else {
                let respHead = try HTTPResponseHead(http2HeaderBlock: headerContent.headers)
                let first = HTTPClientResponsePart.head(respHead)
                var second: HTTPClientResponsePart? = nil
                if headerContent.endStream {
                    second = .end(nil)
                }
                return (first: first, second: second)
            }
        case .data(let content):
            guard case .byteBuffer(let b) = content.data else {
                preconditionFailure("Received DATA frame with non-bytebuffer IOData")
            }

            let first = HTTPClientResponsePart.body(b)
            var second: HTTPClientResponsePart? = nil
            if content.endStream {
                second = .end(nil)
            }
            return (first: first, second: second)
        case .alternativeService, .rstStream, .priority, .windowUpdate, .settings, .pushPromise, .ping, .goAway, .origin:
            // These don't have an HTTP/1 equivalent, so let's drop them.
            return (first: nil, second: nil)
        }
    }

    mutating func processOutboundData(_ data: HTTPClientRequestPart, allocator: ByteBufferAllocator) throws -> HTTP2Frame.FramePayload {
        switch data {
        case .head(let head):
            let h1Headers = try HTTPHeaders(requestHead: head, protocolString: self.protocolString)
            let headerContent = HTTP2Frame.FramePayload.Headers(headers: HPACKHeaders(httpHeaders: h1Headers,
                                                                                      normalizeHTTPHeaders: self.normalizeHTTPHeaders))
            return .headers(headerContent)
        case .body(let body):
            return .data(HTTP2Frame.FramePayload.Data(data: body))
        case .end(let trailers):
            if let trailers = trailers {
                return .headers(.init(headers: HPACKHeaders(httpHeaders: trailers,
                                                            normalizeHTTPHeaders: self.normalizeHTTPHeaders),
                                      endStream: true))
            } else {
                return .data(.init(data: .byteBuffer(allocator.buffer(capacity: 0)), endStream: true))
            }
        }
    }
}

/// A simple channel handler that translates HTTP/2 concepts into HTTP/1 data types,
/// and vice versa, for use on the client side.
///
/// This channel handler should be used alongside the `HTTP2StreamMultiplexer` to
/// help provide a HTTP/1.1-like abstraction on top of a HTTP/2 multiplexed
/// connection.
@available(*, deprecated, renamed: "HTTP2FramePayloadToHTTP1ClientCodec")
public final class HTTP2ToHTTP1ClientCodec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPClientResponsePart

    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTP2Frame

    /// The HTTP protocol scheme being used on this connection.
    public typealias HTTPProtocol = HTTP2FramePayloadToHTTP1ClientCodec.HTTPProtocol

    private let streamID: HTTP2StreamID
    private var baseCodec: BaseClientCodec

    /// Initializes a `HTTP2ToHTTP1ClientCodec` for the given `HTTP2StreamID`.
    ///
    /// - parameters:
    ///    - streamID: The HTTP/2 stream ID this `HTTP2ToHTTP1ClientCodec` will be used for
    ///    - httpProtocol: The protocol (usually `"http"` or `"https"` that is used).
    ///    - normalizeHTTPHeaders: Whether to automatically normalize the HTTP headers to be suitable for HTTP/2.
    ///                            The normalization will for example lower-case all header names (as required by the
    ///                            HTTP/2 spec) and remove headers that are unsuitable for HTTP/2 such as
    ///                            headers related to HTTP/1's keep-alive behaviour. Unless you are sure that all your
    ///                            headers conform to the HTTP/2 spec, you should leave this parameter set to `true`.
    public init(streamID: HTTP2StreamID, httpProtocol: HTTPProtocol, normalizeHTTPHeaders: Bool) {
        self.streamID = streamID
        self.baseCodec = BaseClientCodec(httpProtocol: httpProtocol, normalizeHTTPHeaders: normalizeHTTPHeaders)
    }

    /// Initializes a `HTTP2ToHTTP1ClientCodec` for the given `HTTP2StreamID`.
    ///
    /// - parameters:
    ///    - streamID: The HTTP/2 stream ID this `HTTP2ToHTTP1ClientCodec` will be used for
    ///    - httpProtocol: The protocol (usually `"http"` or `"https"` that is used).
    public convenience init(streamID: HTTP2StreamID, httpProtocol: HTTPProtocol) {
        self.init(streamID: streamID, httpProtocol: httpProtocol, normalizeHTTPHeaders: true)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        do {
            let (first, second) = try self.baseCodec.processInboundData(frame.payload)
            if let first = first {
                context.fireChannelRead(self.wrapInboundOut(first))
            }
            if let second = second {
                context.fireChannelRead(self.wrapInboundOut(second))
            }
        } catch {
            context.fireErrorCaught(error)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let responsePart = self.unwrapOutboundIn(data)

        do {
            let transformedPayload = try self.baseCodec.processOutboundData(responsePart, allocator: context.channel.allocator)
            let part = HTTP2Frame(streamID: self.streamID, payload: transformedPayload)
            context.write(self.wrapOutboundOut(part), promise: promise)
        } catch {
            promise?.fail(error)
            context.fireErrorCaught(error)
        }
    }
}

/// A simple channel handler that translates HTTP/2 concepts into HTTP/1 data types,
/// and vice versa, for use on the client side.
///
/// This channel handler should be used alongside the `HTTP2StreamMultiplexer` to
/// help provide a HTTP/1.1-like abstraction on top of a HTTP/2 multiplexed
/// connection.
///
/// This handler uses `HTTP2Frame.FramePayload` as its HTTP/2 currency type.
public final class HTTP2FramePayloadToHTTP1ClientCodec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame.FramePayload
    public typealias InboundOut = HTTPClientResponsePart

    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTP2Frame.FramePayload

    private var baseCodec: BaseClientCodec

    /// The HTTP protocol scheme being used on this connection.
    public enum HTTPProtocol {
        case https
        case http
    }

    /// Initializes a `HTTP2PayloadToHTTP1ClientCodec`.
    ///
    /// - parameters:
    ///    - httpProtocol: The protocol (usually `"http"` or `"https"` that is used).
    ///    - normalizeHTTPHeaders: Whether to automatically normalize the HTTP headers to be suitable for HTTP/2.
    ///                            The normalization will for example lower-case all header names (as required by the
    ///                            HTTP/2 spec) and remove headers that are unsuitable for HTTP/2 such as
    ///                            headers related to HTTP/1's keep-alive behaviour. Unless you are sure that all your
    ///                            headers conform to the HTTP/2 spec, you should leave this parameter set to `true`.
    public init(httpProtocol: HTTPProtocol, normalizeHTTPHeaders: Bool = true) {
        self.baseCodec = BaseClientCodec(httpProtocol: httpProtocol, normalizeHTTPHeaders: normalizeHTTPHeaders)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)
        do {
            let (first, second) = try self.baseCodec.processInboundData(payload)
            if let first = first {
                context.fireChannelRead(self.wrapInboundOut(first))
            }
            if let second = second {
                context.fireChannelRead(self.wrapInboundOut(second))
            }
        } catch {
            context.fireErrorCaught(error)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let responsePart = self.unwrapOutboundIn(data)

        do {
            let transformedPayload = try self.baseCodec.processOutboundData(responsePart, allocator: context.channel.allocator)
            context.write(self.wrapOutboundOut(transformedPayload), promise: promise)
        } catch {
            promise?.fail(error)
            context.fireErrorCaught(error)
        }
    }
}

// MARK: - Server

fileprivate struct BaseServerCodec {
    private let normalizeHTTPHeaders: Bool
    private var headerStateMachine: HTTP2HeadersStateMachine = HTTP2HeadersStateMachine(mode: .server)

    init(normalizeHTTPHeaders: Bool) {
        self.normalizeHTTPHeaders = normalizeHTTPHeaders
    }

    mutating func processInboundData(_ data: HTTP2Frame.FramePayload) throws -> (first: HTTPServerRequestPart?, second: HTTPServerRequestPart?) {
        switch data {
        case .headers(let headerContent):
            if case .trailer = try self.headerStateMachine.newHeaders(block: headerContent.headers) {
                return (first: .end(HTTPHeaders(regularHeadersFrom: headerContent.headers)), second: nil)
            } else {
                let reqHead = try HTTPRequestHead(http2HeaderBlock: headerContent.headers)

                let first = HTTPServerRequestPart.head(reqHead)
                var second: HTTPServerRequestPart? = nil
                if headerContent.endStream {
                    second = .end(nil)
                }
                return (first: first, second: second)
            }
        case .data(let dataContent):
            guard case .byteBuffer(let b) = dataContent.data else {
                preconditionFailure("Received non-byteBuffer IOData from network")
            }
            let first = HTTPServerRequestPart.body(b)
            var second: HTTPServerRequestPart? = nil
            if dataContent.endStream {
                second = .end(nil)
            }
            return (first: first, second: second)
        default:
            // Any other frame type is ignored.
            return (first: nil, second: nil)
        }
    }

    mutating func processOutboundData(_ data: HTTPServerResponsePart, allocator: ByteBufferAllocator) -> HTTP2Frame.FramePayload {
        switch data {
        case .head(let head):
            let h1 = HTTPHeaders(responseHead: head)
            let payload = HTTP2Frame.FramePayload.Headers(headers: HPACKHeaders(httpHeaders: h1,
                                                                                normalizeHTTPHeaders: self.normalizeHTTPHeaders))
            return .headers(payload)
        case .body(let body):
            let payload = HTTP2Frame.FramePayload.Data(data: body)
            return .data(payload)
        case .end(let trailers):
            if let trailers = trailers {
                return .headers(.init(headers: HPACKHeaders(httpHeaders: trailers,
                                                            normalizeHTTPHeaders: self.normalizeHTTPHeaders),
                                      endStream: true))
            } else {
                return .data(.init(data: .byteBuffer(allocator.buffer(capacity: 0)), endStream: true))
            }
        }
    }
}


/// A simple channel handler that translates HTTP/2 concepts into HTTP/1 data types,
/// and vice versa, for use on the server side.
///
/// This channel handler should be used alongside the `HTTP2StreamMultiplexer` to
/// help provide a HTTP/1.1-like abstraction on top of a HTTP/2 multiplexed
/// connection.
@available(*, deprecated, renamed: "HTTP2FramePayloadToHTTP1ServerCodec")
public final class HTTP2ToHTTP1ServerCodec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPServerRequestPart

    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTP2Frame

    private let streamID: HTTP2StreamID
    private var baseCodec: BaseServerCodec

    /// Initializes a `HTTP2ToHTTP1ServerCodec` for the given `HTTP2StreamID`.
    ///
    /// - parameters:
    ///    - streamID: The HTTP/2 stream ID this `HTTP2ToHTTP1ServerCodec` will be used for
    ///    - normalizeHTTPHeaders: Whether to automatically normalize the HTTP headers to be suitable for HTTP/2.
    ///                            The normalization will for example lower-case all header names (as required by the
    ///                            HTTP/2 spec) and remove headers that are unsuitable for HTTP/2 such as
    ///                            headers related to HTTP/1's keep-alive behaviour. Unless you are sure that all your
    ///                            headers conform to the HTTP/2 spec, you should leave this parameter set to `true`.
    public init(streamID: HTTP2StreamID, normalizeHTTPHeaders: Bool) {
        self.streamID = streamID
        self.baseCodec = BaseServerCodec(normalizeHTTPHeaders: normalizeHTTPHeaders)
    }

    public convenience init(streamID: HTTP2StreamID) {
        self.init(streamID: streamID, normalizeHTTPHeaders: true)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        do {
            let (first, second) = try self.baseCodec.processInboundData(frame.payload)
            if let first = first {
                context.fireChannelRead(self.wrapInboundOut(first))
            }
            if let second = second {
                context.fireChannelRead(self.wrapInboundOut(second))
            }
        } catch {
            context.fireErrorCaught(error)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let responsePart = self.unwrapOutboundIn(data)
        let transformedPayload = self.baseCodec.processOutboundData(responsePart, allocator: context.channel.allocator)
        let part = HTTP2Frame(streamID: self.streamID, payload: transformedPayload)
        context.write(self.wrapOutboundOut(part), promise: promise)
    }
}

/// A simple channel handler that translates HTTP/2 concepts into HTTP/1 data types,
/// and vice versa, for use on the server side.
///
/// This channel handler should be used alongside the `HTTP2StreamMultiplexer` to
/// help provide a HTTP/1.1-like abstraction on top of a HTTP/2 multiplexed
/// connection.
///
/// This handler uses `HTTP2Frame.FramePayload` as its HTTP/2 currency type.
public final class HTTP2FramePayloadToHTTP1ServerCodec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame.FramePayload
    public typealias InboundOut = HTTPServerRequestPart

    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTP2Frame.FramePayload

    private var baseCodec: BaseServerCodec

    /// Initializes a `HTTP2PayloadToHTTP1ServerCodec`.
    ///
    /// - parameters:
    ///    - normalizeHTTPHeaders: Whether to automatically normalize the HTTP headers to be suitable for HTTP/2.
    ///                            The normalization will for example lower-case all header names (as required by the
    ///                            HTTP/2 spec) and remove headers that are unsuitable for HTTP/2 such as
    ///                            headers related to HTTP/1's keep-alive behaviour. Unless you are sure that all your
    ///                            headers conform to the HTTP/2 spec, you should leave this parameter set to `true`.
    public init(normalizeHTTPHeaders: Bool = true) {
        self.baseCodec = BaseServerCodec(normalizeHTTPHeaders: normalizeHTTPHeaders)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)

        do {
            let (first, second) = try self.baseCodec.processInboundData(payload)
            if let first = first {
                context.fireChannelRead(self.wrapInboundOut(first))
            }
            if let second = second {
                context.fireChannelRead(self.wrapInboundOut(second))
            }
        } catch {
            context.fireErrorCaught(error)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let responsePart = self.unwrapOutboundIn(data)
        let transformedPayload = self.baseCodec.processOutboundData(responsePart, allocator: context.channel.allocator)
        context.write(self.wrapOutboundOut(transformedPayload), promise: promise)
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


internal extension String {
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
        case .SOURCE:
            self = "SOURCE"
        case .RAW(let v):
            self = v
        }
    }
}


// MARK:- Methods for creating `HTTPRequestHead`/`HTTPResponseHead` objects from
// header blocks generated by the HTTP/2 layer.
internal extension HTTPRequestHead {
    /// Create a `HTTPRequestHead` from the header block produced by nghttp2.
    init(http2HeaderBlock headers: HPACKHeaders) throws {
        // A request head should have only up to four psuedo-headers.
        let method = HTTPMethod(methodString: try headers.peekPseudoHeader(name: ":method"))
        let version = HTTPVersion(major: 2, minor: 0)
        let uri = try headers.peekPseudoHeader(name: ":path")

        // Here we peek :scheme just to confirm it's there: we want the throw effect, but we don't care about the value.
        _ = try headers.peekPseudoHeader(name: ":scheme")

        let authority = try headers.peekPseudoHeader(name: ":authority")

        // We do a manual implementation of HTTPHeaders(regularHeadersFrom:) here because we may need to add an extra Host:
        // header here, and that can cause copies if we're unlucky. We need headers.count - 3 spaces: we remove :method,
        // :path, :scheme, and :authority, but we may add in Host.
        var rawHeaders: [(String, String)] = []
        rawHeaders.reserveCapacity(headers.count - 3)
        if !headers.contains(name: "host") {
            rawHeaders.append(("host", authority))
        }
        rawHeaders.appendRegularHeaders(from: headers)

        self.init(version: version, method: method, uri: uri, headers: HTTPHeaders(rawHeaders))
    }
}


internal extension HTTPResponseHead {
    /// Create a `HTTPResponseHead` from the header block produced by nghttp2.
    init(http2HeaderBlock headers: HPACKHeaders) throws {
        // A response head should have only one psuedo-header. We strip it off.
        let statusHeader = try headers.peekPseudoHeader(name: ":status")
        guard let integerStatus = Int(statusHeader, radix: 10) else {
            throw NIOHTTP2Errors.invalidStatusValue(statusHeader)
        }
        let status = HTTPResponseStatus(statusCode: integerStatus)
        self.init(version: .init(major: 2, minor: 0), status: status, headers: HTTPHeaders(regularHeadersFrom: headers))
    }
}


extension HPACKHeaders {
    /// Grabs a pseudo-header from a header block. Does not remove it.
    ///
    /// - parameter:
    ///     - name: The header name to find.
    /// - returns: The value for this pseudo-header.
    /// - throws: If there is no such header, or multiple.
    internal func peekPseudoHeader(name: String) throws -> String {
        // This could be done with .lazy.filter.map but that generates way more ARC traffic.
        var headerValue: String? = nil

        for (fieldName, fieldValue, _) in self {
            if name == fieldName {
                guard headerValue == nil else {
                    throw NIOHTTP2Errors.duplicatePseudoHeader(name)
                }
                headerValue = fieldValue
            }
        }

        if let headerValue = headerValue {
            return headerValue
        } else {
            throw NIOHTTP2Errors.missingPseudoHeader(name)
        }
    }
}


extension HTTPHeaders {
    fileprivate init(requestHead: HTTPRequestHead, protocolString: String) throws {
        // To avoid too much allocation we create an array first, and then initialize the HTTPHeaders from it.
        // We want to ensure this array is large enough so we only have to allocate once. We will need an
        // array that is the same as the number of headers in requestHead.headers + 3: we're adding :path,
        // :method, and :scheme, and transforming Host to :authority.
        var newHeaders: [(String, String)] = []
        newHeaders.reserveCapacity(requestHead.headers.count + 3)

        // TODO(cory): This is potentially wrong if the URI contains more than just a path.
        newHeaders.append((":path", requestHead.uri))
        newHeaders.append((":method", String(httpMethod: requestHead.method)))
        newHeaders.append((":scheme", protocolString))

        // We store a place for the :authority header, even though we don't know what it is. We'll find it later and
        // change it when we do. This avoids us needing to potentially search this header block twice.
        var authorityHeader: String? = nil
        newHeaders.append((":authority", ""))

        // Now fill in the others, except for any Host header we might find, which will become an :authority header.
        for header in requestHead.headers {
            if header.name.lowercased() == "host" {
                if authorityHeader != nil {
                    throw NIOHTTP2Errors.duplicateHostHeader()
                }

                authorityHeader = header.value
            } else {
                newHeaders.append((header.name, header.value))
            }
        }

        // Now we go back and fill in the authority header.
        guard let actualAuthorityHeader = authorityHeader else {
            throw NIOHTTP2Errors.missingHostHeader()
        }
        newHeaders[3].1 = actualAuthorityHeader

        self.init(newHeaders)
    }

    fileprivate init(responseHead: HTTPResponseHead) {
        // To avoid too much allocation we create an array first, and then initialize the HTTPHeaders from it.
        // This array will need to be the size of the response headers + 1, for the :status field.
        var newHeaders: [(String, String)] = []
        newHeaders.reserveCapacity(responseHead.headers.count + 1)
        newHeaders.append((":status", String(responseHead.status.code)))
        responseHead.headers.forEach { newHeaders.append(($0.name, $0.value)) }

        self.init(newHeaders)
    }

    internal init(regularHeadersFrom oldHeaders: HPACKHeaders) {
        // We need to create an array to write the header fields into.
        var newHeaders: [(String, String)] = []
        newHeaders.reserveCapacity(oldHeaders.count)
        newHeaders.appendRegularHeaders(from: oldHeaders)
        self.init(newHeaders)
    }
}


extension Array where Element == (String, String) {
    mutating func appendRegularHeaders(from headers: HPACKHeaders) {
        for (name, value, _) in headers {
            if name.first == ":" {
                continue
            }

            self.append((name, value))
        }
    }
}
