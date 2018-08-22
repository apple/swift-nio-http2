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
import CNIONghttp2
import NIOHTTP1


fileprivate extension HTTPHeaders {
    fileprivate init(requestHead: HTTPRequestHead, protocolString: String) {
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

    fileprivate init(responseHead: HTTPResponseHead) {
        self.init()
        
        self.add(name: ":status", value: String(responseHead.status.code))
        responseHead.headers.forEach { self.add(name: $0.name, value: $0.value) }
    }
}


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
    // This looks odd, but this normally tracks *sent* headers, while we want to track *received* ones.
    // For that reason, we set the mode to server here.
    private var headerStateMachine: HTTP2HeadersStateMachine = HTTP2HeadersStateMachine(mode: .server)

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
        case .headers(let headers):
            if case .trailer = self.headerStateMachine.newHeaders(block: headers) {
                ctx.fireChannelRead(self.wrapInboundOut(.end(headers)))
            } else {
                let respHead = HTTPResponseHead(http2HeaderBlock: headers)
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
            let frame = HTTP2Frame(streamID: self.streamID, payload: .headers(HTTPHeaders(requestHead: head, protocolString: self.protocolString)))
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .body(let body):
            let payload = HTTP2Frame.FramePayload.data(body)
            let frame = HTTP2Frame(streamID: self.streamID, payload: payload)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .end(let trailers):
            let payload: HTTP2Frame.FramePayload
            if let trailers = trailers {
                payload = .headers(trailers)
            } else {
                payload = HTTP2Frame.FramePayload.data(.byteBuffer(ctx.channel.allocator.buffer(capacity: 0)))
            }

            var frame = HTTP2Frame(streamID: self.streamID, payload: payload)
            frame.flags.insert(.endStream)
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
    // This looks odd, but this normally tracks *sent* headers, while we want to track *received* ones.
    // For that reason, we set the mode to client here.
    private var headerStateMachine: HTTP2HeadersStateMachine = HTTP2HeadersStateMachine(mode: .client)

    public init(streamID: HTTP2StreamID) {
        self.streamID = streamID
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.payload {
        case .headers(let headers):
            if case .trailer = self.headerStateMachine.newHeaders(block: headers) {
                ctx.fireChannelRead(self.wrapInboundOut(.end(headers)))
            } else {
                let reqHead = HTTPRequestHead(http2HeaderBlock: headers)
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
            let frame = HTTP2Frame(streamID: self.streamID, payload: .headers(HTTPHeaders(responseHead: head)))
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .body(let body):
            let payload = HTTP2Frame.FramePayload.data(body)
            let frame = HTTP2Frame(streamID: self.streamID, payload: payload)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        case .end(let trailers):
            let payload: HTTP2Frame.FramePayload
            if let trailers = trailers {
                payload = .headers(trailers)
            } else {
                payload = HTTP2Frame.FramePayload.data(.byteBuffer(ctx.channel.allocator.buffer(capacity: 0)))
            }

            var frame = HTTP2Frame(streamID: self.streamID, payload: payload)
            frame.flags.insert(.endStream)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        }
    }
}
