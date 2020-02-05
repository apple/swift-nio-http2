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

// This example server currently does not know how to negotiate HTTP/2. That will come in a future enhancement. For now, you can
// hit it with curl like so: curl --http2-prior-knowledge http://localhost:8888/


import NIO
import NIOHTTP1
import NIOHTTP2

final class HTTP1TestServer: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = self.unwrapInboundIn(data) else {
            return
        }

        // Insert an event loop tick here. This more accurately represents real workloads in SwiftNIO, which will not
        // re-entrantly write their response frames.
        context.eventLoop.execute {
            context.channel.getOption(HTTP2StreamChannelOptions.streamID).flatMap { (streamID) -> EventLoopFuture<Void> in
                var headers = HTTPHeaders()
                headers.add(name: "content-length", value: "5")
                headers.add(name: "x-stream-id", value: String(Int(streamID)))
                context.channel.write(self.wrapOutboundOut(HTTPServerResponsePart.head(HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok, headers: headers))), promise: nil)

                var buffer = context.channel.allocator.buffer(capacity: 12)
                buffer.writeStaticString("hello")
                context.channel.write(self.wrapOutboundOut(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                return context.channel.writeAndFlush(self.wrapOutboundOut(HTTPServerResponsePart.end(nil)))
            }.whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}

extension String {
    func chopPrefix(_ prefix: String) -> String? {
        if self.unicodeScalars.starts(with: prefix.unicodeScalars) {
            return String(self[self.index(self.startIndex, offsetBy: prefix.count)...])
        } else {
            return nil
        }
    }

    func containsDotDot() -> Bool {
        for idx in self.indices {
            if self[idx] == "." && idx < self.index(before: self.endIndex) && self[self.index(after: idx)] == "." {
                return true
            }
        }
        return false
    }
}

fileprivate func httpResponseHead(request: HTTPRequestHead, status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) -> HTTPResponseHead {
    HTTPResponseHead(version: .init(major: 2, minor: 0), status: status, headers: headers)
}

final class HTTPHandler: ChannelInboundHandler {
    private enum FileIOMethod {
        case sendfile
        case nonblockingFileIO
    }
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case waitingForRequestBody
        case sendingResponse

        mutating func requestReceived() {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody
        }

        mutating func requestComplete() {
            precondition(self == .waitingForRequestBody, "Invalid state for request complete: \(self)")
            self = .sendingResponse
        }

        mutating func responseComplete() {
            precondition(self == .sendingResponse, "Invalid state for response complete: \(self)")
            self = .idle
        }
    }

    private var buffer: ByteBuffer! = nil
    private var state = State.idle
    private let htdocsPath: String

    private var infoSavedRequestHead: HTTPRequestHead?
    private var infoSavedBodyBytes: Int = 0

    private var continuousCount: Int = 0

    private var handler: ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)?
    private var handlerFuture: EventLoopFuture<Void>?
    private let fileIO: NonBlockingFileIO
    private let defaultResponse = "Hello World\r\n"

    public init(fileIO: NonBlockingFileIO, htdocsPath: String) {
        self.htdocsPath = htdocsPath
        self.fileIO = fileIO
    }

    func handleInfo(context: ChannelHandlerContext, request: HTTPServerRequestPart) {
        switch request {
        case .head(let request):
            self.infoSavedRequestHead = request
            self.infoSavedBodyBytes = 0
            self.state.requestReceived()
        case .body(buffer: let buf):
            self.infoSavedBodyBytes += buf.readableBytes
        case .end:
            context.channel.getOption(HTTP2StreamChannelOptions.streamID).whenComplete { streamID in
                let streamInfo: String
                do {
                    streamInfo = try streamID.get().description
                }
                catch {
                    streamInfo = "<error: \(error)>"
                }
                self.state.requestComplete()
                let response = """
                HTTP method: \(self.infoSavedRequestHead!.method)\r
                URL: \(self.infoSavedRequestHead!.uri)\r
                body length: \(self.infoSavedBodyBytes)\r
                headers: \(self.infoSavedRequestHead!.headers)\r
                client: \(context.remoteAddress?.description ?? "zombie")\r
                stream: \(streamInfo)\r
                IO: SwiftNIO Electric Boogaloo™️\r\n
                """
                self.buffer.clear()
                self.buffer.writeString(response)
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "\(response.utf8.count)")
                context.write(self.wrapOutboundOut(.head(httpResponseHead(request: self.infoSavedRequestHead!, status: .ok, headers: headers))), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(self.buffer))), promise: nil)
                self.completeResponse(context, trailers: nil, promise: nil)
            }
        }
    }

    func handleEcho(context: ChannelHandlerContext, request: HTTPServerRequestPart) {
        self.handleEcho(context: context, request: request, balloonInMemory: false)
    }

    func handleEcho(context: ChannelHandlerContext, request: HTTPServerRequestPart, balloonInMemory: Bool = false) {
        switch request {
        case .head(let request):
            self.infoSavedRequestHead = request
            self.state.requestReceived()
            if balloonInMemory {
                self.buffer.clear()
            } else {
                context.writeAndFlush(self.wrapOutboundOut(.head(httpResponseHead(request: request, status: .ok))), promise: nil)
            }
        case .body(buffer: var buf):
            if balloonInMemory {
                self.buffer.writeBuffer(&buf)
            } else {
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            }
        case .end:
            self.state.requestComplete()
            if balloonInMemory {
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "\(self.buffer.readableBytes)")
                context.write(self.wrapOutboundOut(.head(httpResponseHead(request: self.infoSavedRequestHead!, status: .ok, headers: headers))), promise: nil)
                context.write(self.wrapOutboundOut(.body(.byteBuffer(self.buffer))), promise: nil)
                self.completeResponse(context, trailers: nil, promise: nil)
            } else {
                self.completeResponse(context, trailers: nil, promise: nil)
            }
        }
    }

    func handleJustWrite(context: ChannelHandlerContext, request: HTTPServerRequestPart, statusCode: HTTPResponseStatus = .ok, string: String, trailer: (String, String)? = nil, delay: TimeAmount = .nanoseconds(0)) {
        switch request {
        case .head(let request):
            self.state.requestReceived()
            context.writeAndFlush(self.wrapOutboundOut(.head(httpResponseHead(request: request, status: statusCode))), promise: nil)
        case .body(buffer: _):
            ()
        case .end:
            self.state.requestComplete()
            context.eventLoop.scheduleTask(in: delay) { () -> Void in
                var buf = context.channel.allocator.buffer(capacity: string.utf8.count)
                buf.writeString(string)
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                var trailers: HTTPHeaders? = nil
                if let trailer = trailer {
                    trailers = HTTPHeaders()
                    trailers?.add(name: trailer.0, value: trailer.1)
                }

                self.completeResponse(context, trailers: trailers, promise: nil)
            }
        }
    }

    func handleContinuousWrites(context: ChannelHandlerContext, request: HTTPServerRequestPart) {
        switch request {
        case .head(let request):
            self.continuousCount = 0
            self.state.requestReceived()
            func doNext() {
                self.buffer.clear()
                self.continuousCount += 1
                self.buffer.writeString("line \(self.continuousCount)\n")
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(self.buffer)))).map {
                    context.eventLoop.scheduleTask(in: .milliseconds(400), doNext)
                }.whenFailure { (_: Error) in
                    self.completeResponse(context, trailers: nil, promise: nil)
                }
            }
            context.writeAndFlush(self.wrapOutboundOut(.head(httpResponseHead(request: request, status: .ok))), promise: nil)
            doNext()
        case .end:
            self.state.requestComplete()
        default:
            break
        }
    }

    func handleMultipleWrites(context: ChannelHandlerContext, request: HTTPServerRequestPart, strings: [String], delay: TimeAmount) {
        switch request {
        case .head(let request):
            self.continuousCount = 0
            self.state.requestReceived()
            func doNext() {
                self.buffer.clear()
                self.buffer.writeString(strings[self.continuousCount])
                self.continuousCount += 1
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(self.buffer)))).whenSuccess {
                    if self.continuousCount < strings.count {
                        context.eventLoop.scheduleTask(in: delay, doNext)
                    } else {
                        self.completeResponse(context, trailers: nil, promise: nil)
                    }
                }
            }
            context.writeAndFlush(self.wrapOutboundOut(.head(httpResponseHead(request: request, status: .ok))), promise: nil)
            doNext()
        case .end:
            self.state.requestComplete()
        default:
            break
        }
    }

    func dynamicHandler(request reqHead: HTTPRequestHead) -> ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)? {
        if let howLong = reqHead.uri.chopPrefix("/dynamic/write-delay/") {
            return { context, req in
                self.handleJustWrite(context: context,
                                     request: req, string: self.defaultResponse,
                                     delay: Int64(howLong).map { .milliseconds($0) } ?? .seconds(0))
            }
        }

        switch reqHead.uri {
        case "/dynamic/echo":
            return self.handleEcho
        case "/dynamic/echo_balloon":
            return { self.handleEcho(context: $0, request: $1, balloonInMemory: true) }
        case "/dynamic/pid":
            return { context, req in self.handleJustWrite(context: context, request: req, string: "\(getpid())") }
        case "/dynamic/write-delay":
            return { context, req in self.handleJustWrite(context: context, request: req, string: self.defaultResponse, delay: .milliseconds(100)) }
        case "/dynamic/info":
            return self.handleInfo
        case "/dynamic/trailers":
            return { context, req in self.handleJustWrite(context: context, request: req, string: "\(getpid())\r\n", trailer: ("Trailer-Key", "Trailer-Value")) }
        case "/dynamic/continuous":
            return self.handleContinuousWrites
        case "/dynamic/count-to-ten":
            return { self.handleMultipleWrites(context: $0, request: $1, strings: (1...10).map { "\($0)" }, delay: .milliseconds(100)) }
        case "/dynamic/client-ip":
            return { context, req in self.handleJustWrite(context: context, request: req, string: "\(context.remoteAddress.debugDescription)") }
        default:
            return { context, req in self.handleJustWrite(context: context, request: req, statusCode: .notFound, string: "not found") }
        }
    }

    private func handleFile(context: ChannelHandlerContext, request: HTTPServerRequestPart, ioMethod: FileIOMethod, path: String) {
        self.buffer.clear()

        func sendErrorResponse(request: HTTPRequestHead, _ error: Error) {
            var body = context.channel.allocator.buffer(capacity: 128)
            let response = { () -> HTTPResponseHead in
                switch error {
                case let e as IOError where e.errnoCode == ENOENT:
                    body.writeStaticString("IOError (not found)\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                case let e as IOError:
                    body.writeStaticString("IOError (other)\r\n")
                    body.writeString(e.description)
                    body.writeStaticString("\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                default:
                    body.writeString("\(type(of: error)) error\r\n")
                    return httpResponseHead(request: request, status: .internalServerError)
                }
            }()
            body.writeString("\(error)")
            body.writeStaticString("\r\n")
            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.channel.close(promise: nil)
        }

        func responseHead(request: HTTPRequestHead, fileRegion region: FileRegion) -> HTTPResponseHead {
            var response = httpResponseHead(request: request, status: .ok)
            response.headers.add(name: "Content-Length", value: "\(region.endIndex)")
            response.headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            return response
        }

        switch request {
        case .head(let request):
            self.state.requestReceived()
            guard !request.uri.containsDotDot() else {
                let response = httpResponseHead(request: request, status: .forbidden)
                context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                self.completeResponse(context, trailers: nil, promise: nil)
                return
            }
            let path = self.htdocsPath + "/" + path
            let fileHandleAndRegion = self.fileIO.openFile(path: path, eventLoop: context.eventLoop)
            fileHandleAndRegion.whenFailure {
                sendErrorResponse(request: request, $0)
            }
            fileHandleAndRegion.whenSuccess { (file, region) in
                switch ioMethod {
                case .nonblockingFileIO:
                    var responseStarted = false
                    let response = responseHead(request: request, fileRegion: region)
                    if region.readableBytes == 0 {
                        responseStarted = true
                        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                    }
                    return self.fileIO.readChunked(fileRegion: region,
                                                   chunkSize: 32 * 1024,
                                                   allocator: context.channel.allocator,
                                                   eventLoop: context.eventLoop) { buffer in
                                                    if !responseStarted {
                                                        responseStarted = true
                                                        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                                                    }
                                                    return context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                    }.flatMap { () -> EventLoopFuture<Void> in
                        let p = context.eventLoop.makePromise(of: Void.self)
                        self.completeResponse(context, trailers: nil, promise: p)
                        return p.futureResult
                    }.flatMapError { error in
                        if !responseStarted {
                            let response = httpResponseHead(request: request, status: .ok)
                            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                            var buffer = context.channel.allocator.buffer(capacity: 100)
                            buffer.writeString("fail: \(error)")
                            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            self.state.responseComplete()
                            return context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
                        } else {
                            return context.close()
                        }
                    }.whenComplete { (_: Result<Void, Error>) in
                        _ = try? file.close()
                    }
                case .sendfile:
                    let response = responseHead(request: request, fileRegion: region)
                    context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.body(.fileRegion(region)))).flatMap {
                        let p = context.eventLoop.makePromise(of: Void.self)
                        self.completeResponse(context, trailers: nil, promise: p)
                        return p.futureResult
                    }.flatMapError { (_: Error) in
                        context.close()
                    }.whenComplete { (_: Result<Void, Error>) in
                        _ = try? file.close()
                    }
                }
        }
        case .end:
            self.state.requestComplete()
        default:
            fatalError("oh noes: \(request)")
        }
    }

    private func completeResponse(_ context: ChannelHandlerContext, trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?) {
        self.state.responseComplete()

        let promise = promise ?? context.eventLoop.makePromise()
        promise.futureResult.whenComplete { (_: Result<Void, Error>) in context.close(promise: nil) }
        self.handler = nil

        context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        if let handler = self.handler {
            handler(context, reqPart)
            return
        }

        switch reqPart {
        case .head(let request):
            if request.uri.unicodeScalars.starts(with: "/dynamic".unicodeScalars) {
                self.handler = self.dynamicHandler(request: request)
                self.handler!(context, reqPart)
                return
            } else if let path = request.uri.chopPrefix("/sendfile/") {
                self.handler = { self.handleFile(context: $0, request: $1, ioMethod: .sendfile, path: path) }
                self.handler!(context, reqPart)
                return
            } else if let path = request.uri.chopPrefix("/fileio/") {
                self.handler = { self.handleFile(context: $0, request: $1, ioMethod: .nonblockingFileIO, path: path) }
                self.handler!(context, reqPart)
                return
            }

            self.state.requestReceived()

            var responseHead = httpResponseHead(request: request, status: HTTPResponseStatus.ok)
            self.buffer.clear()
            self.buffer.writeString(self.defaultResponse)
            responseHead.headers.add(name: "content-length", value: "\(self.buffer!.readableBytes)")
            let response = HTTPServerResponsePart.head(responseHead)
            context.write(self.wrapOutboundOut(response), promise: nil)
        case .body:
            break
        case .end:
            self.state.requestComplete()
            let content = HTTPServerResponsePart.body(.byteBuffer(buffer!.slice()))
            context.write(self.wrapOutboundOut(content), promise: nil)
            self.completeResponse(context, trailers: nil, promise: nil)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.buffer = context.channel.allocator.buffer(capacity: 0)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // The remote peer half-closed the channel. At this time, any
            // outstanding response will now get the channel closed, and
            // if we are idle or waiting for a request body to finish we
            // will close the channel immediately.
            switch self.state {
            case .idle, .waitingForRequestBody:
                context.close(promise: nil)
            case .sendingResponse:
                break
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Server received error: \(error)")
        context.close(promise: nil)
    }
}


// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst().dropFirst().first
let arg3 = arguments.dropFirst().dropFirst().dropFirst().first

let defaultHost = "::1"
let defaultPort: Int = 8888
let defaultHtdocs = "/dev/null/"

enum BindTo {
    case ip(host: String, port: Int)
    case unixDomainSocket(path: String)
}

let htdocs: String
let bindTarget: BindTo

switch (arg1, arg1.flatMap(Int.init), arg2, arg2.flatMap(Int.init), arg3) {
case (.some(let h), _ , _, .some(let p), let maybeHtdocs):
    /* second arg an integer --> host port [htdocs] */
    bindTarget = .ip(host: h, port: p)
    htdocs = maybeHtdocs ?? defaultHtdocs
case (_, .some(let p), let maybeHtdocs, _, _):
    /* first arg an integer --> port [htdocs] */
    bindTarget = .ip(host: defaultHost, port: p)
    htdocs = maybeHtdocs ?? defaultHtdocs
case (.some(let portString), .none, let maybeHtdocs, .none, .none):
    /* couldn't parse as number --> uds-path [htdocs] */
    bindTarget = .unixDomainSocket(path: portString)
    htdocs = maybeHtdocs ?? defaultHtdocs
default:
    htdocs = defaultHtdocs
    bindTarget = BindTo.ip(host: defaultHost, port: defaultPort)
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
let threadPool = NIOThreadPool(numberOfThreads: 6)
threadPool.start()

let fileIO = NonBlockingFileIO(threadPool: threadPool)
let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

    // Set the handlers that are applied to the accepted Channels
    .childChannelInitializer { channel in
        return channel.configureHTTP2Pipeline(mode: .server) { (streamChannel, streamID) -> EventLoopFuture<Void> in
            return streamChannel.pipeline.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID)).flatMap { () -> EventLoopFuture<Void> in
                streamChannel.pipeline.addHandler(HTTPHandler(fileIO: fileIO, htdocsPath: htdocs))
            }.flatMap { () -> EventLoopFuture<Void> in
                streamChannel.pipeline.addHandler(ErrorHandler())
            }
        }.flatMap { (_: HTTP2StreamMultiplexer) in
            return channel.pipeline.addHandler(ErrorHandler())
        }
    }

    // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
    .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

defer {
    try! group.syncShutdownGracefully()
    try! threadPool.syncShutdownGracefully()
}

print("htdocs = \(htdocs)")

let channel = try { () -> Channel in
    switch bindTarget {
    case .ip(let host, let port):
        return try bootstrap.bind(host: host, port: port).wait()
    case .unixDomainSocket(let path):
        return try bootstrap.bind(unixDomainSocketPath: path).wait()
    }
}()

print("Server started and listening on \(channel.localAddress!), htdocs path \(htdocs)")

// This will never unblock as we don't close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
