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


/// A simple channel handler that translates HTTP/2 concepts into HTTP/1 data types,
/// and vice versa, for use on the client side.
///
/// This channel handler should be used alongside the `HTTP2StreamMultiplexer` to
/// help provide a HTTP/1.1-like abstraction on top of a HTTP/2 multiplexed
/// connection.
public final class HTTP2ToHTTP1ClientCodec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPClientResponsePart

    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTP2Frame

    /// The HTTP protocol scheme being used on this connection.
    public enum HTTPProtocol {
        case https
        case http
    }

    private let streamID: HTTP2StreamID
    private let protocolString: String

    private var headerStateMachine: HTTP2HeadersStateMachine = HTTP2HeadersStateMachine(mode: .client)

    public init(streamID: HTTP2StreamID, httpProtocol: HTTPProtocol) {
        self.streamID = streamID

        switch httpProtocol {
        case .http:
            self.protocolString = "http"
        case .https:
            self.protocolString = "https"
        }
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.payload {
        case .headers(let headers, _):
            if case .trailer = self.headerStateMachine.newHeaders(block: headers.asH1Headers()) {
                ctx.fireChannelRead(self.wrapInboundOut(.end(headers.asH1Headers())))
            } else {
                let respHead = HTTPResponseHead(http2HeaderBlock: headers.asH1Headers())
                ctx.fireChannelRead(self.wrapInboundOut(.head(respHead)))
                if frame.flags.contains(.endStream) {
                    ctx.fireChannelRead(self.wrapInboundOut(.end(nil)))
                }
            }
        case .data(.byteBuffer(let b)):
            ctx.fireChannelRead(self.wrapInboundOut(.body(b)))
            if frame.flags.contains(.endStream) {
                ctx.fireChannelRead(self.wrapInboundOut(.end(nil)))
            }
        case .alternativeService, .rstStream, .priority, .windowUpdate:
            // All these frames may be sent on a stream, but are ignored by the multiplexer and will be
            // handled elsewhere.
            return
        default:
            fatalError("unimplemented frame \(frame)")
        }
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let responsePart = self.unwrapOutboundIn(data)
        switch responsePart {
        case .head(let head):
            let h1Headers = HTTPHeaders(requestHead: head, protocolString: self.protocolString)
            let frame = HTTP2Frame(streamID: self.streamID, flags: .endHeaders, payload: .headers(HPACKHeaders(httpHeaders: h1Headers), nil))
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .body(let body):
            let payload = HTTP2Frame.FramePayload.data(body)
            let frame = HTTP2Frame(streamID: self.streamID, payload: payload)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .end(let trailers):
            let payload: HTTP2Frame.FramePayload
            var flags: HTTP2Frame.FrameFlags = .endStream
            if let trailers = trailers {
                payload = .headers(HPACKHeaders(httpHeaders: trailers), nil)
                flags.insert(.endHeaders)
            } else {
                payload = HTTP2Frame.FramePayload.data(.byteBuffer(ctx.channel.allocator.buffer(capacity: 0)))
            }

            let frame = HTTP2Frame(streamID: self.streamID, flags: flags, payload: payload)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        }
    }
}


/// A simple channel handler that translates HTTP/2 concepts into HTTP/1 data types,
/// and vice versa, for use on the server side.
///
/// This channel handler should be used alongside the `HTTP2StreamMultiplexer` to
/// help provide a HTTP/1.1-like abstraction on top of a HTTP/2 multiplexed
/// connection.
public final class HTTP2ToHTTP1ServerCodec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPServerRequestPart

    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTP2Frame

    private let streamID: HTTP2StreamID

    private var headerStateMachine: HTTP2HeadersStateMachine = HTTP2HeadersStateMachine(mode: .server)

    public init(streamID: HTTP2StreamID) {
        self.streamID = streamID
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.payload {
        case .headers(let headers, _):
            if case .trailer = self.headerStateMachine.newHeaders(block: headers.asH1Headers()) {
                ctx.fireChannelRead(self.wrapInboundOut(.end(headers.asH1Headers())))
            } else {
                let reqHead = HTTPRequestHead(http2HeaderBlock: headers.asH1Headers())
                ctx.fireChannelRead(self.wrapInboundOut(.head(reqHead)))
                if frame.flags.contains(.endStream) {
                    ctx.fireChannelRead(self.wrapInboundOut(.end(nil)))
                }
            }
        case .data(.byteBuffer(let b)):
            ctx.fireChannelRead(self.wrapInboundOut(.body(b)))
            if frame.flags.contains(.endStream) {
                ctx.fireChannelRead(self.wrapInboundOut(.end(nil)))
            }
        case .alternativeService, .rstStream, .priority, .windowUpdate:
            // All these frames may be sent on a stream, but are ignored by the multiplexer and will be
            // handled elsewhere.
            return
        default:
            fatalError("unimplemented frame \(frame)")
        }
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let responsePart = self.unwrapOutboundIn(data)
        switch responsePart {
        case .head(let head):
            let h1 = HTTPHeaders(responseHead: head)
            let frame = HTTP2Frame(streamID: self.streamID, flags: .endHeaders, payload: .headers(HPACKHeaders(httpHeaders: h1), nil))
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .body(let body):
            let payload = HTTP2Frame.FramePayload.data(body)
            let frame = HTTP2Frame(streamID: self.streamID, payload: payload)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .end(let trailers):
            let payload: HTTP2Frame.FramePayload
            var flags: HTTP2Frame.FrameFlags = .endStream
            if let trailers = trailers {
                payload = .headers(HPACKHeaders(httpHeaders: trailers), nil)
                flags.insert(.endHeaders)
            } else {
                payload = HTTP2Frame.FramePayload.data(.byteBuffer(ctx.channel.allocator.buffer(capacity: 0)))
            }

            let frame = HTTP2Frame(streamID: self.streamID, flags: flags, payload: payload)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        }
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
        case .RAW(let v):
            self = v
        }
    }
}


// MARK:- Methods for creating `HTTPRequestHead`/`HTTPResponseHead` objects from
// header blocks generated by the HTTP/2 layer.
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

        // TODO(cory): Right now we're just stripping authority, but it should probably
        // be used.
        headers.remove(name: ":scheme")

        // This block works only if the HTTP/2 implementation rejects requests with
        // mismatched :authority and host headers.
        let authority = headers.popPseudoHeader(name: ":authority")!
        if !headers.contains(name: "host") {
            headers.add(name: "host", value: authority)
        }

        self.init(version: version, method: method, uri: uri)
        self.headers = headers
    }
}


internal extension HTTPResponseHead {
    /// Create a `HTTPResponseHead` from the header block produced by nghttp2.
    init(http2HeaderBlock headers: HTTPHeaders) {
        // Take a local copy here.
        var headers = headers

        // A response head should have only one psuedo-header. We strip it off.
        // TODO(cory): Error handling!
        let status = HTTPResponseStatus(statusCode: Int(headers.popPseudoHeader(name: ":status")!, radix: 10)!)
        self.init(version: .init(major: 2, minor: 0), status: status, headers: headers)
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


fileprivate extension HTTPHeaders {
    init(requestHead: HTTPRequestHead, protocolString: String) {
        self.init()

        // TODO(cory): This is potentially wrong if the URI contains more than just a path.
        self.add(name: ":path", value: requestHead.uri)
        self.add(name: ":method", value: String(httpMethod: requestHead.method))
        self.add(name: ":scheme", value: protocolString)

        // Attempt to set the :authority pseudo-header. We don't error if this fails, we allow
        // the rest of the components to do so to avoid needing to maintain too much state here.
        var headers = requestHead.headers
        let authority = headers[canonicalForm: "host"]
        if authority.count > 0 {
            precondition(authority.count == 1)
            headers.remove(name: "host")
            self.add(name: ":authority", value: authority[0])
        }

        headers.forEach { self.add(name: $0.name, value: $0.value) }
    }

    init(responseHead: HTTPResponseHead) {
        self.init()

        self.add(name: ":status", value: String(responseHead.status.code))
        responseHead.headers.forEach { self.add(name: $0.name, value: $0.value) }
    }
}


extension HPACKHeaders {
    func asH1Headers() -> HTTPHeaders {
        return HTTPHeaders(self.map { ($0.0, $0.1) })
    }
}
