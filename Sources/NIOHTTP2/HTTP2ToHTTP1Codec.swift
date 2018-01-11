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
        ctx.channel.write(self.wrapOutboundOut(HTTPServerResponsePart.head(HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok))), promise: nil)
        ctx.channel.writeAndFlush(self.wrapOutboundOut(HTTPServerResponsePart.end(nil))).whenComplete {
            ctx.close(promise: nil)
        }
    }
}

public final class HTTP2ToHTTP1Codec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPServerRequestPart

    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = (Int32, HTTP2Frame.FramePayload)

    private let streamID: Int32

    public init(streamID: Int32) {
        self.streamID = streamID
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.payload {
        case .headers(_, let h2Headers):
            let reqHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0),
                                          method: HTTPMethod(http2Method: h2Headers[":method"].first!)!,
                                          uri: h2Headers[":path"].first!)
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
            let payload = HTTP2Frame.FramePayload.headers(.response, head.headers)
            ctx.channel.parent!.write(self.wrapOutboundOut((self.streamID, payload: payload)), promise: promise)
        case .end(_):
            // FIXME: trailers
            promise?.succeed(result: ())
            ()
        default:
            fatalError("unimplemented \(responsePart)")
        }
    }
}
