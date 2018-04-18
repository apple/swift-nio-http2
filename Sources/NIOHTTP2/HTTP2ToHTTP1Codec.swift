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

public final class HTTP2ToHTTP1Codec: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTPServerRequestPart

    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTP2Frame

    private let streamID: Int32

    public init(streamID: Int) {
        self.streamID = Int32(streamID)
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
            var frame = HTTP2Frame(streamID: self.streamID, payload: .headers(.response(head)))
            frame.endHeaders = true
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
