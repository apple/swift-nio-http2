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

public final class HTTP1TestServer: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var headers = HTTPHeaders()
        headers.add(name: "content-length", value: "5")
        headers.add(name: "x-cory-kicks-nghttp2s-ass", value: "true")
        ctx.channel.write(self.wrapOutboundOut(HTTPServerResponsePart.head(HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok, headers: headers))), promise: nil)

        var buffer = ctx.channel.allocator.buffer(capacity: 12)
        buffer.write(staticString: "hello")
        ctx.channel.write(self.wrapOutboundOut(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)

        ctx.channel.writeAndFlush(self.wrapOutboundOut(HTTPServerResponsePart.end(nil))).whenComplete {
            ctx.close(promise: nil)
        }
    }
}

public final class HTTP2ToHTTP1Codec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPServerRequestPart

    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTP2Frame

    private let streamID: Int32

    public init(streamID: Int32) {
        self.streamID = streamID
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.payload {
        case .headers(.request(let reqHead)):
            let req = InboundOut.head(reqHead)
            ctx.fireChannelRead(self.wrapInboundOut(req))
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
            let frame = HTTP2Frame(header: .init(streamID: self.streamID), payload: .headers(.response(head)))
            ctx.channel.parent!.write(self.wrapOutboundOut(frame), promise: promise)
        case .body(let body):
            let payload = HTTP2Frame.FramePayload.data(body)
            let frame = HTTP2Frame(header: .init(streamID: self.streamID), payload: payload)
            ctx.channel.parent!.write(self.wrapOutboundOut(frame), promise: promise)
        case .end(_):
            var header = HTTP2Frame.FrameHeader(streamID: self.streamID)
            header.endStream = true
            let payload = HTTP2Frame.FramePayload.data(.byteBuffer(ctx.channel.allocator.buffer(capacity: 0)))

            let frame = HTTP2Frame(header: header, payload: payload)
            ctx.channel.parent!.write(self.wrapOutboundOut(frame), promise: promise)
        }
    }
}
