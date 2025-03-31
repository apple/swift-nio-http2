//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import NIOHPACK  // For HPACKHeaders initializer access
@testable import NIOHTTP2

extension EmbeddedChannel {
    /// Assert that we received a request head.
    func assertReceivedServerRequestPart(
        _ part: HTTPServerRequestPart,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actualPart: HTTPServerRequestPart = try? assertNoThrowWithValue(self.readInbound()) else {
            XCTFail("No data received", file: (file), line: line)
            return
        }

        XCTAssertEqual(actualPart, part, file: (file), line: line)
    }

    func assertReceivedClientResponsePart(
        _ part: HTTPClientResponsePart,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actualPart: HTTPClientResponsePart = try? assertNoThrowWithValue(self.readInbound()) else {
            XCTFail("No data received", file: (file), line: line)
            return
        }

        XCTAssertEqual(actualPart, part, file: (file), line: line)
    }
}

extension HTTPHeaders {
    static func + (lhs: HTTPHeaders, rhs: HTTPHeaders) -> HTTPHeaders {
        var new = lhs
        for (name, value) in rhs {
            new.add(name: name, value: value)
        }

        return new
    }
}

extension HPACKHeaders {
    static func + (lhs: HPACKHeaders, rhs: HPACKHeaders) -> HPACKHeaders {
        var new = lhs
        for (name, value, index) in rhs {
            new.add(name: name, value: value, indexing: index)
        }
        return new
    }
}

/// A simple channel handler that records the promises sent through it.
final class PromiseRecorder: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var recordedPromises: [EventLoopPromise<Void>?] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        recordedPromises.append(promise)
        context.write(data, promise: promise)
    }
}

final class HTTP2ToHTTP1CodecTests: XCTestCase {
    var channel: EmbeddedChannel!

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        self.channel = nil
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testBasicRequestServerSide() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"), (":authority", "example.org"),
            ("other", "header"),
        ])
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        )

        var expectedRequestHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0), method: .POST, uri: "/post")
        expectedRequestHead.headers.add(name: "host", value: "example.org")
        expectedRequestHead.headers.add(name: "transfer-encoding", value: "chunked")
        expectedRequestHead.headers.add(name: "other", value: "header")
        self.channel.assertReceivedServerRequestPart(.head(expectedRequestHead))

        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        let dataFrame = HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(bodyData), endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        self.channel.assertReceivedServerRequestPart(.body(bodyData))
        self.channel.assertReceivedServerRequestPart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testRequestWithOnlyHeadServerSide() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/get"), (":method", "GET"), (":scheme", "https"), (":authority", "example.org"),
            ("other", "header"),
        ])
        let headersFrame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: requestHeaders, endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(headersFrame))

        var expectedRequestHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0), method: .GET, uri: "/get")
        expectedRequestHead.headers.add(name: "host", value: "example.org")
        expectedRequestHead.headers.add(name: "other", value: "header")
        self.channel.assertReceivedServerRequestPart(.head(expectedRequestHead))
        self.channel.assertReceivedServerRequestPart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testRequestWithTrailers() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/get"), (":method", "GET"), (":scheme", "https"), (":authority", "example.org"),
            ("other", "header"),
        ])
        let headersFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(headersFrame))

        var expectedRequestHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0), method: .GET, uri: "/get")
        expectedRequestHead.headers.add(name: "host", value: "example.org")
        expectedRequestHead.headers.add(name: "other", value: "header")
        self.channel.assertReceivedServerRequestPart(.head(expectedRequestHead))

        // Ok, we're going to send trailers.
        let trailers = HPACKHeaders([("a trailer", "yes"), ("another trailer", "also yes")])
        let trailersFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: trailers, endStream: true)))
        XCTAssertNoThrow(try self.channel.writeInbound(trailersFrame))

        self.channel.assertReceivedServerRequestPart(.end(HTTPHeaders(regularHeadersFrom: trailers)))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testSendingSimpleResponse() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic response.
        let responseHeaders = HPACKHeaders([("server", "swift-nio"), ("other", "header")])
        let responseHead = HTTPResponseHead(
            version: .init(major: 2, minor: 0),
            status: .ok,
            headers: HTTPHeaders(regularHeadersFrom: responseHeaders)
        )
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedResponseHeaders = HPACKHeaders([(":status", "200")]) + responseHeaders
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedResponseHeaders
        )

        // Now body.
        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        self.channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bodyData)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFrame(endStream: false, streamID: 1, payload: bodyData)

        // Now trailers.
        let trailers = HPACKHeaders([("a-trailer", "yes"), ("another-trailer", "still yes")])
        self.channel.writeAndFlush(HTTPServerResponsePart.end(HTTPHeaders(regularHeadersFrom: trailers)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 3)
        writeRecorder.flushedWrites[2].assertHeadersFrame(endStream: true, streamID: 1, headers: trailers)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testResponseWithoutTrailers() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic response.
        let responseHeaders = HPACKHeaders([("server", "swift-nio"), ("other", "header")])
        let responseHead = HTTPResponseHead(
            version: .init(major: 2, minor: 0),
            status: .ok,
            headers: HTTPHeaders(regularHeadersFrom: responseHeaders)
        )
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedResponseHeaders = HPACKHeaders([(":status", "200")]) + responseHeaders
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedResponseHeaders
        )

        // No trailers, just end.
        let emptyBuffer = self.channel.allocator.buffer(capacity: 0)
        self.channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFrame(endStream: true, streamID: 1, payload: emptyBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testResponseWith100Blocks() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // First, we're going to send a few 103 blocks.
        let informationalResponseHeaders = HPACKHeaders([("link", "no link really")])
        let informationalResponseHead = HTTPResponseHead(
            version: .init(major: 2, minor: 0),
            status: .custom(code: 103, reasonPhrase: "Early Hints"),
            headers: HTTPHeaders(regularHeadersFrom: informationalResponseHeaders)
        )
        for _ in 0..<3 {
            self.channel.write(HTTPServerResponsePart.head(informationalResponseHead), promise: nil)
        }
        self.channel.flush()

        let expectedInformationalResponseHeaders = HPACKHeaders([(":status", "103")]) + informationalResponseHeaders
        XCTAssertEqual(writeRecorder.flushedWrites.count, 3)
        for idx in 0..<3 {
            writeRecorder.flushedWrites[idx].assertHeadersFrame(
                endStream: false,
                streamID: 1,
                headers: expectedInformationalResponseHeaders
            )
        }

        // Now we finish up with a basic response.
        let responseHeaders = HPACKHeaders([("server", "swift-nio"), ("other", "header")])
        let responseHead = HTTPResponseHead(
            version: .init(major: 2, minor: 0),
            status: .ok,
            headers: HTTPHeaders(regularHeadersFrom: responseHeaders)
        )
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)
        self.channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)

        let expectedResponseHeaders = HPACKHeaders([(":status", "200")]) + responseHeaders
        let emptyBuffer = self.channel.allocator.buffer(capacity: 0)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 5)
        writeRecorder.flushedWrites[3].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedResponseHeaders
        )
        writeRecorder.flushedWrites[4].assertDataFrame(endStream: true, streamID: 1, payload: emptyBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testPassingPromisesThroughWritesOnServer() throws {
        let streamID = HTTP2StreamID(1)
        let promiseRecorder = PromiseRecorder()

        let promises: [EventLoopPromise<Void>] = (0..<3).map { _ in self.channel.eventLoop.makePromise() }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(promiseRecorder))
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic response.
        let responseHeaders = HTTPHeaders([("server", "swift-nio"), ("other", "header")])
        let responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok, headers: responseHeaders)
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: promises[0])

        // Now body.
        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        self.channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bodyData)), promise: promises[1])

        // Now trailers.
        let trailers = HTTPHeaders([("a trailer", "yes"), ("another trailer", "still yes")])
        self.channel.writeAndFlush(HTTPServerResponsePart.end(trailers), promise: promises[2])

        XCTAssertEqual(promiseRecorder.recordedPromises.count, 3)
        for (idx, promise) in promiseRecorder.recordedPromises.enumerated() {
            XCTAssertTrue(promise!.futureResult === promises[idx].futureResult)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testBasicResponseClientSide() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))

        // A basic response.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("other", "header")])
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTP2Frame(
                    streamID: streamID,
                    payload: .headers(.init(headers: HPACKHeaders(httpHeaders: responseHeaders)))
                )
            )
        )

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "transfer-encoding", value: "chunked")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))

        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        let dataFrame = HTTP2Frame(
            streamID: streamID,
            payload: .data(.init(data: .byteBuffer(bodyData), endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(dataFrame))
        self.channel.assertReceivedClientResponsePart(.body(bodyData))
        self.channel.assertReceivedClientResponsePart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testResponseWithOnlyHeadClientSide() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))

        // A basic response.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("other", "header")])
        let headersFrame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: HPACKHeaders(httpHeaders: responseHeaders), endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(headersFrame))

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "content-length", value: "0")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))
        self.channel.assertReceivedClientResponsePart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testResponseWithTrailers() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))

        // A basic response.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("other", "header")])
        let headersFrame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: HPACKHeaders(httpHeaders: responseHeaders)))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(headersFrame))

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "transfer-encoding", value: "chunked")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))

        // Ok, we're going to send trailers.
        let trailers = HTTPHeaders([("a trailer", "yes"), ("another trailer", "also yes")])
        let trailersFrame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: HPACKHeaders(httpHeaders: trailers), endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(trailersFrame))

        self.channel.assertReceivedClientResponsePart(.end(trailers))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testSendingSimpleRequest() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([("host", "example.org"), ("other", "header")])
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/post")
        requestHead.headers = HTTPHeaders(regularHeadersFrom: requestHeaders)
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"), (":authority", "example.org"),
            ("other", "header"),
        ])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders
        )

        // Now body.
        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        self.channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(bodyData)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFrame(endStream: false, streamID: 1, payload: bodyData)

        // Now trailers.
        let trailers = HPACKHeaders([("a-trailer", "yes"), ("another-trailer", "still yes")])
        self.channel.writeAndFlush(HTTPClientRequestPart.end(HTTPHeaders(regularHeadersFrom: trailers)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 3)
        writeRecorder.flushedWrites[2].assertHeadersFrame(endStream: true, streamID: 1, headers: trailers)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testRequestWithoutTrailers() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .http)
            )
        )

        // A basic request.
        let requestHeaders = HTTPHeaders([("host", "example.org"), ("other", "header")])
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/post")
        requestHead.headers = requestHeaders
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "http"), (":authority", "example.org"),
            ("other", "header"),
        ])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders
        )

        // No trailers, just end.
        let emptyBuffer = self.channel.allocator.buffer(capacity: 0)
        self.channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFrame(endStream: true, streamID: 1, payload: emptyBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testResponseWith100BlocksClientSide() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))

        // Start with a few 100 blocks.
        let informationalResponseHeaders = HTTPHeaders([(":status", "103"), ("link", "example")])
        for _ in 0..<3 {
            XCTAssertNoThrow(
                try self.channel.writeInbound(
                    HTTP2Frame(
                        streamID: streamID,
                        payload: .headers(.init(headers: HPACKHeaders(httpHeaders: informationalResponseHeaders)))
                    )
                )
            )
        }

        var expectedInformationalResponseHead = HTTPResponseHead(
            version: .init(major: 2, minor: 0),
            status: .custom(code: 103, reasonPhrase: "")
        )
        expectedInformationalResponseHead.headers.add(name: "link", value: "example")
        for _ in 0..<3 {
            self.channel.assertReceivedClientResponsePart(.head(expectedInformationalResponseHead))
        }

        // Now a response.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("other", "header")])
        let responseFrame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: HPACKHeaders(httpHeaders: responseHeaders), endStream: true))
        )
        XCTAssertNoThrow(try self.channel.writeInbound(responseFrame))

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "content-length", value: "0")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))
        self.channel.assertReceivedClientResponsePart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testPassingPromisesThroughWritesOnClient() throws {
        let streamID = HTTP2StreamID(1)
        let promiseRecorder = PromiseRecorder()

        let promises: [EventLoopPromise<Void>] = (0..<3).map { _ in self.channel.eventLoop.makePromise() }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(promiseRecorder))
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic response.
        let requestHeaders = HTTPHeaders([("host", "example.org"), ("other", "header")])
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/post")
        requestHead.headers = requestHeaders
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: promises[0])

        // Now body.
        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        self.channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(bodyData)), promise: promises[1])

        // Now trailers.
        let trailers = HTTPHeaders([("a trailer", "yes"), ("another trailer", "still yes")])
        self.channel.writeAndFlush(HTTPClientRequestPart.end(trailers), promise: promises[2])

        XCTAssertEqual(promiseRecorder.recordedPromises.count, 3)
        for (idx, promise) in promiseRecorder.recordedPromises.enumerated() {
            XCTAssertTrue(promise!.futureResult === promises[idx].futureResult)
        }

        XCTAssertNoThrow(try self.channel.finish())
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithoutMethod() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":scheme", "https"), (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.MissingPseudoHeader(":method"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithDuplicateMethod() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "GET"), (":method", "GET"), (":scheme", "https"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.DuplicatePseudoHeader(":method")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithoutPath() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":method", "GET"), (":scheme", "https"), (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.MissingPseudoHeader(":path"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithDuplicatePath() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":path", "/post"), (":method", "GET"), (":scheme", "https"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.DuplicatePseudoHeader(":path")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithoutAuthority() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":method", "GET"), (":scheme", "https"), (":path", "/post"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.MissingPseudoHeader,
                NIOHTTP2Errors.MissingPseudoHeader(":authority")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithDuplicateAuthority() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "GET"), (":scheme", "https"), (":authority", "example.org"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.DuplicatePseudoHeader(":authority")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithoutScheme() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":method", "GET"), (":authority", "example.org"), (":path", "/post"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.MissingPseudoHeader(":scheme"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveRequestWithDuplicateScheme() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "GET"), (":scheme", "https"), (":scheme", "https"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.DuplicatePseudoHeader(":scheme")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveResponseWithoutStatus() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic response.
        let requestHeaders = HPACKHeaders([("other", "header")])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.MissingPseudoHeader(":status"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveResponseWithDuplicateStatus() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([(":status", "200"), (":status", "404"), ("other", "header")])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.DuplicatePseudoHeader(":status")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testReceiveResponseWithNonNumericalStatus() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))

        // A basic response.
        let requestHeaders = HPACKHeaders([(":status", "captivating")])
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: requestHeaders)))
            )
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.InvalidStatusValue,
                NIOHTTP2Errors.InvalidStatusValue("captivating")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testSendRequestWithoutHost() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request without Host.
        let request = HTTPClientRequestPart.head(.init(version: .init(major: 1, minor: 1), method: .GET, uri: "/"))
        XCTAssertThrowsError(try self.channel.writeOutbound(request)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingHostHeader, NIOHTTP2Errors.MissingHostHeader())
        }

        // We check the channel for an error as the above only checks the promise.
        XCTAssertThrowsError(try self.channel.finish()) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingHostHeader, NIOHTTP2Errors.MissingHostHeader())
        }
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testSendRequestWithDuplicateHost() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request with too many host headers.
        var requestHead = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/")
        requestHead.headers.add(name: "Host", value: "fish")
        requestHead.headers.add(name: "Host", value: "cat")
        let request = HTTPClientRequestPart.head(requestHead)
        XCTAssertThrowsError(try self.channel.writeOutbound(request)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.DuplicateHostHeader, NIOHTTP2Errors.DuplicateHostHeader())
        }

        // We check the channel for an error as the above only checks the promise.
        XCTAssertThrowsError(try self.channel.finish()) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.DuplicateHostHeader, NIOHTTP2Errors.DuplicateHostHeader())
        }
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testFramesWithoutHTTP1EquivalentAreIgnored() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(
                    streamID: streamID,
                    httpProtocol: .https
                )
            )
        )

        let headers = HPACKHeaders([(":method", "GET"), (":scheme", "https"), (":path", "/x")])
        let frames: [HTTP2Frame.FramePayload] = [
            .alternativeService(origin: nil, field: nil),
            .rstStream(.init(networkCode: 1)),
            .priority(.init(exclusive: true, dependency: streamID, weight: 1)),
            .windowUpdate(windowSizeIncrement: 1),
            .settings(.ack),
            .pushPromise(.init(pushedStreamID: HTTP2StreamID(2), headers: headers)),
            .ping(.init(withInteger: 123), ack: true),
            .goAway(lastStreamID: streamID, errorCode: .init(networkCode: 1), opaqueData: nil),
            .origin([]),
        ]
        for payload in frames {
            let frame = HTTP2Frame(streamID: streamID, payload: payload)
            XCTAssertNoThrow(try self.channel.writeInbound(frame), "error on \(frame)")
        }
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWeTolerateUpperCasedHTTP1HeadersForRequests() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/post")
        requestHead.headers = HTTPHeaders([("host", "example.org"), ("UpperCased", "Header")])
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"), (":authority", "example.org"),
            ("uppercased", "Header"),
        ])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders,
            type: .request
        )
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWeTolerateUpperCasedHTTP1HeadersForResponses() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        var responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        responseHead.headers = HTTPHeaders([("UpperCased", "Header")])
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([(":status", "200"), ("uppercased", "Header")])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders,
            type: .response
        )
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWeDoNotNormalizeHeadersIfUserAskedUsNotToForRequests() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(
                    streamID: streamID,
                    httpProtocol: .https,
                    normalizeHTTPHeaders: false
                )
            )
        )

        // A basic request.
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/post")
        requestHead.headers = HTTPHeaders([("host", "example.org"), ("UpperCased", "Header")])
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"),
            (":authority", "example.org"), ("UpperCased", "Header"),
        ])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders,
            type: .doNotValidate
        )
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWeDoNotNormalizeHeadersIfUserAskedUsNotToForResponses() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ServerCodec(
                    streamID: streamID,
                    normalizeHTTPHeaders: false
                )
            )
        )

        var responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        responseHead.headers = HTTPHeaders([("UpperCased", "Header")])
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([(":status", "200"), ("UpperCased", "Header")])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders,
            type: .doNotValidate
        )
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWeStripIllegalHeadersAsWellAsTheHeadersNominatedByTheConnectionHeaderForRequests() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https)
            )
        )

        // A basic request.
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/post")
        requestHead.headers = HTTPHeaders([
            ("host", "example.org"), ("connection", "keep-alive, also-to-be-removed"),
            ("keep-alive", "foo"), ("also-to-be-removed", "yes"), ("should", "stay"),
            ("Proxy-Connection", "bad"), ("Transfer-Encoding", "also bad"),
        ])
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"),
            (":authority", "example.org"), ("should", "stay"),
        ])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders,
            type: .request
        )
    }

    @available(*, deprecated, message: "Deprecated so deprecated functionality can be tested without warnings")
    func testWeStripIllegalHeadersAsWellAsTheHeadersNominatedByTheConnectionHeaderForResponses() throws {
        let streamID = HTTP2StreamID(1)
        let writeRecorder = FrameWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(HTTP2ToHTTP1ServerCodec(streamID: streamID))
        )

        var responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        responseHead.headers = HTTPHeaders([
            ("connection", "keep-alive, also-to-be-removed"),
            ("keep-alive", "foo"), ("also-to-be-removed", "yes"), ("should", "stay"),
            ("Proxy-Connection", "bad"), ("Transfer-Encoding", "also bad"),
        ])
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([(":status", "200"), ("should", "stay")])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFrame(
            endStream: false,
            streamID: 1,
            headers: expectedRequestHeaders,
            type: .response
        )
    }
}
