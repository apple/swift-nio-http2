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

private extension HTTPMethod {
    init?(http2Method: String) {
        switch http2Method {
        case "GET":
            self = .GET
        default:
            return nil
        }
    }
}

fileprivate extension HTTPHeaders {
    fileprivate init(requestHead: HTTPRequestHead) {
        self.init()

        // TODO(cory): This is potentially wrong if the URI contains more than just a path.
        self.add(name: ":path", value: requestHead.uri)
        self.add(name: ":method", value: String(httpMethod: requestHead.method))

        // TODO(cory): This is very wrong.
        self.add(name: ":scheme", value: "https")

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


public final class HTTP2ToHTTP1Codec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPServerRequestPart

    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTP2Frame

    private let streamID: HTTP2StreamID

    public init(streamID: HTTP2StreamID) {
        self.streamID = streamID
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.payload {
        case .headers(let headers):
            let reqHead = HTTPRequestHead(http2HeaderBlock: headers)
            ctx.fireChannelRead(self.wrapInboundOut(.head(reqHead)))
        case .settings(_), .windowUpdate(windowSizeIncrement: _):
            // FIXME: ignored
            ()
        case .goAway:
            ctx.close(promise: nil)
        case .rstStream:
            print(self.streamID)
            // FIXME: ignored
            ()
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
        case .end(_):
            let payload = HTTP2Frame.FramePayload.data(.byteBuffer(ctx.channel.allocator.buffer(capacity: 0)))
            var frame = HTTP2Frame(streamID: self.streamID, payload: payload)
            frame.endStream = true
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
        }
    }
}
