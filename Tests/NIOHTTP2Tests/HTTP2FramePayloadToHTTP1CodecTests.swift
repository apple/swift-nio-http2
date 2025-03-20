//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
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
import NIOHPACK
import NIOHTTP1
import XCTest

@testable import NIOHTTP2

final class HTTP2FramePayloadToHTTP1CodecTests: XCTestCase {
    var channel: EmbeddedChannel!

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        self.channel = nil
    }

    func testBasicRequestServerSide() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"), (":authority", "example.org"),
            ("other", "header"),
        ])
        XCTAssertNoThrow(try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders))))

        var expectedRequestHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0), method: .POST, uri: "/post")
        expectedRequestHead.headers.add(name: "host", value: "example.org")
        expectedRequestHead.headers.add(name: "other", value: "header")
        expectedRequestHead.headers.add(name: "transfer-encoding", value: "chunked")
        self.channel.assertReceivedServerRequestPart(.head(expectedRequestHead))

        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: true))
        XCTAssertNoThrow(try self.channel.writeInbound(dataPayload))
        self.channel.assertReceivedServerRequestPart(.body(bodyData))
        self.channel.assertReceivedServerRequestPart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testRequestWithOnlyHeadServerSide() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/get"), (":method", "GET"), (":scheme", "https"), (":authority", "example.org"),
            ("other", "header"),
        ])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders, endStream: true))
        XCTAssertNoThrow(try self.channel.writeInbound(headersPayload))

        var expectedRequestHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0), method: .GET, uri: "/get")
        expectedRequestHead.headers.add(name: "host", value: "example.org")
        expectedRequestHead.headers.add(name: "other", value: "header")
        self.channel.assertReceivedServerRequestPart(.head(expectedRequestHead))
        self.channel.assertReceivedServerRequestPart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testRequestWithTrailers() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/get"), (":method", "GET"), (":scheme", "https"), (":authority", "example.org"),
            ("other", "header"),
        ])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders))
        XCTAssertNoThrow(try self.channel.writeInbound(headersPayload))

        var expectedRequestHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0), method: .GET, uri: "/get")
        expectedRequestHead.headers.add(name: "host", value: "example.org")
        expectedRequestHead.headers.add(name: "other", value: "header")
        self.channel.assertReceivedServerRequestPart(.head(expectedRequestHead))

        // Ok, we're going to send trailers.
        let trailers = HPACKHeaders([("a trailer", "yes"), ("another trailer", "also yes")])
        let trailersPayload = HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true))
        XCTAssertNoThrow(try self.channel.writeInbound(trailersPayload))

        self.channel.assertReceivedServerRequestPart(.end(HTTPHeaders(regularHeadersFrom: trailers)))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testSendingSimpleResponse() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

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
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(endStream: false, headers: expectedResponseHeaders)

        // Now body.
        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        self.channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bodyData)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFramePayload(endStream: false, payload: bodyData)

        // Now trailers.
        let trailers = HPACKHeaders([("a-trailer", "yes"), ("another-trailer", "still yes")])
        self.channel.writeAndFlush(HTTPServerResponsePart.end(HTTPHeaders(regularHeadersFrom: trailers)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 3)
        writeRecorder.flushedWrites[2].assertHeadersFramePayload(endStream: true, headers: trailers)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testResponseWithoutTrailers() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

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
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(endStream: false, headers: expectedResponseHeaders)

        // No trailers, just end.
        let emptyBuffer = self.channel.allocator.buffer(capacity: 0)
        self.channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFramePayload(endStream: true, payload: emptyBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testResponseWith100Blocks() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

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
            writeRecorder.flushedWrites[idx].assertHeadersFramePayload(
                endStream: false,
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
        writeRecorder.flushedWrites[3].assertHeadersFramePayload(endStream: false, headers: expectedResponseHeaders)
        writeRecorder.flushedWrites[4].assertDataFramePayload(endStream: true, payload: emptyBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testPassingPromisesThroughWritesOnServer() throws {
        let promiseRecorder = PromiseRecorder()

        let promises: [EventLoopPromise<Void>] = (0..<3).map { _ in self.channel.eventLoop.makePromise() }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(promiseRecorder))
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

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

    func testBasicResponseClientSide() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))
        let expectedRequestHeaders = HPACKHeaders([
            (":method", "GET"), (":path", "/"), (":authority", "example.org"), (":scheme", "https"),
        ])
        writeRecorder.flushedWrites.popLast()?.assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders
        )

        // A basic response.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("other", "header")])
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders(httpHeaders: responseHeaders)))
            )
        )

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "transfer-encoding", value: "chunked")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))

        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: true))
        XCTAssertNoThrow(try self.channel.writeInbound(dataPayload))
        self.channel.assertReceivedClientResponsePart(.body(bodyData))
        self.channel.assertReceivedClientResponsePart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testResponseWithOnlyHeadClientSide() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))
        let expectedRequestHeaders = HPACKHeaders([
            (":method", "GET"), (":path", "/"), (":authority", "example.org"), (":scheme", "https"),
        ])
        writeRecorder.flushedWrites.popLast()?.assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders
        )

        // A basic response.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("other", "header")])
        let headersPayload = HTTP2Frame.FramePayload.headers(
            .init(headers: HPACKHeaders(httpHeaders: responseHeaders), endStream: true)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(headersPayload))

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "content-length", value: "0")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))
        self.channel.assertReceivedClientResponsePart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testResponseWithTrailers() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request
        let http1Head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["host": "example.org"])
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(http1Head)))
        let expectedRequestHeaders = HPACKHeaders([
            (":method", "GET"), (":path", "/"), (":authority", "example.org"), (":scheme", "https"),
        ])
        writeRecorder.flushedWrites.popLast()?.assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders
        )

        // A basic response.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("other", "header")])
        let headersPayload = HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders(httpHeaders: responseHeaders)))
        XCTAssertNoThrow(try self.channel.writeInbound(headersPayload))

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "transfer-encoding", value: "chunked")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))

        // Ok, we're going to send trailers.
        let trailers = HTTPHeaders([("a trailer", "yes"), ("another trailer", "also yes")])
        let trailersPayload = HTTP2Frame.FramePayload.headers(
            .init(headers: HPACKHeaders(httpHeaders: trailers), endStream: true)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(trailersPayload))

        self.channel.assertReceivedClientResponsePart(.end(trailers))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testSendingSimpleRequest() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
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
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(endStream: false, headers: expectedRequestHeaders)

        // Now body.
        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        self.channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(bodyData)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFramePayload(endStream: false, payload: bodyData)

        // Now trailers.
        let trailers = HPACKHeaders([("a-trailer", "yes"), ("another-trailer", "still yes")])
        self.channel.writeAndFlush(HTTPClientRequestPart.end(HTTPHeaders(regularHeadersFrom: trailers)), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 3)
        writeRecorder.flushedWrites[2].assertHeadersFramePayload(endStream: true, headers: trailers)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testRequestWithoutTrailers() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .http)
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
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(endStream: false, headers: expectedRequestHeaders)

        // No trailers, just end.
        let emptyBuffer = self.channel.allocator.buffer(capacity: 0)
        self.channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        XCTAssertEqual(writeRecorder.flushedWrites.count, 2)
        writeRecorder.flushedWrites[1].assertDataFramePayload(endStream: true, payload: emptyBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testResponseWith100BlocksClientSide() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([("host", "example.org"), ("other", "header")])
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .GET, uri: "/get")
        requestHead.headers = HTTPHeaders(regularHeadersFrom: requestHeaders)
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: nil)

        // Start with a few 100 blocks.
        let informationalResponseHeaders = HTTPHeaders([(":status", "103"), ("link", "example")])
        for _ in 0..<3 {
            XCTAssertNoThrow(
                try self.channel.writeInbound(
                    HTTP2Frame.FramePayload.headers(
                        .init(headers: HPACKHeaders(httpHeaders: informationalResponseHeaders))
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
        let responsePayload = HTTP2Frame.FramePayload.headers(
            .init(headers: HPACKHeaders(httpHeaders: responseHeaders), endStream: true)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(responsePayload))

        var expectedResponseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        expectedResponseHead.headers.add(name: "other", value: "header")
        expectedResponseHead.headers.add(name: "content-length", value: "0")
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))
        self.channel.assertReceivedClientResponsePart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testPassingPromisesThroughWritesOnClient() throws {
        let promiseRecorder = PromiseRecorder()

        let promises: [EventLoopPromise<Void>] = (0..<3).map { _ in self.channel.eventLoop.makePromise() }
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(promiseRecorder))
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
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

    func testReceiveRequestWithoutMethod() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":scheme", "https"), (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.missingPseudoHeader(":method"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveRequestWithDuplicateMethod() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "GET"), (":method", "GET"), (":scheme", "https"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.duplicatePseudoHeader(":method")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveRequestWithoutPath() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":method", "GET"), (":scheme", "https"), (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.missingPseudoHeader(":path"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveRequestWithDuplicatePath() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":path", "/post"), (":method", "GET"), (":scheme", "https"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.duplicatePseudoHeader(":path")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveRequestWithoutAuthority() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":method", "GET"), (":scheme", "https"), (":path", "/post"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.MissingPseudoHeader,
                NIOHTTP2Errors.missingPseudoHeader(":authority")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveRequestWithDuplicateAuthority() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "GET"), (":scheme", "https"), (":authority", "example.org"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.duplicatePseudoHeader(":authority")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveRequestWithoutScheme() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":method", "GET"), (":authority", "example.org"), (":path", "/post"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.missingPseudoHeader(":scheme"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveRequestWithDuplicateScheme() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "GET"), (":scheme", "https"), (":scheme", "https"),
            (":authority", "example.org"), ("other", "header"),
        ])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.duplicatePseudoHeader(":scheme")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveResponseWithoutStatus() throws {
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic response.
        let requestHeaders = HPACKHeaders([("other", "header")])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingPseudoHeader, NIOHTTP2Errors.missingPseudoHeader(":status"))
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveResponseWithDuplicateStatus() throws {
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([(":status", "200"), (":status", "404"), ("other", "header")])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders)))
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.DuplicatePseudoHeader,
                NIOHTTP2Errors.duplicatePseudoHeader(":status")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testReceiveResponseWithNonNumericalStatus() throws {
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basis request
        let requestHeaders = HTTPHeaders([("host", "example.org"), ("other", "header")])
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .GET, uri: "/get")
        requestHead.headers = requestHeaders
        XCTAssertNoThrow(try self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead)).wait())

        // A basic response.
        let responseHeaders = HPACKHeaders([(":status", "captivating")])
        XCTAssertThrowsError(
            try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: responseHeaders)))
        ) { error in
            XCTAssertEqual(
                error as? NIOHTTP2Errors.InvalidStatusValue,
                NIOHTTP2Errors.invalidStatusValue("captivating")
            )
        }

        // We already know there's an error here.
        _ = try? self.channel.finish()
    }

    func testSendRequestWithoutHost() throws {
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request without Host.
        let request = HTTPClientRequestPart.head(.init(version: .init(major: 1, minor: 1), method: .GET, uri: "/"))
        XCTAssertThrowsError(try self.channel.writeOutbound(request)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingHostHeader, NIOHTTP2Errors.missingHostHeader())
        }

        // We check the channel for an error as the above only checks the promise.
        XCTAssertThrowsError(try self.channel.finish()) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.MissingHostHeader, NIOHTTP2Errors.missingHostHeader())
        }
    }

    func testSendRequestWithDuplicateHost() throws {
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request with too many host headers.
        var requestHead = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/")
        requestHead.headers.add(name: "Host", value: "fish")
        requestHead.headers.add(name: "Host", value: "cat")
        let request = HTTPClientRequestPart.head(requestHead)
        XCTAssertThrowsError(try self.channel.writeOutbound(request)) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.DuplicateHostHeader, NIOHTTP2Errors.duplicateHostHeader())
        }

        // We check the channel for an error as the above only checks the promise.
        XCTAssertThrowsError(try self.channel.finish()) { error in
            XCTAssertEqual(error as? NIOHTTP2Errors.DuplicateHostHeader, NIOHTTP2Errors.duplicateHostHeader())
        }
    }

    func testFramesWithoutHTTP1EquivalentAreIgnored() throws {
        let streamID = HTTP2StreamID(1)
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        let headers = HPACKHeaders([(":method", "GET"), (":scheme", "https"), (":path", "/x")])
        let payloads: [HTTP2Frame.FramePayload] = [
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
        for payload in payloads {
            XCTAssertNoThrow(try self.channel.writeInbound(payload), "error on \(payload)")
        }
        XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
    }

    func testWeTolerateUpperCasedHTTP1HeadersForRequests() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
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
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders,
            type: .request
        )
    }

    func testWeTolerateUpperCasedHTTP1HeadersForResponses() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        var responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        responseHead.headers = HTTPHeaders([("UpperCased", "Header")])
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([(":status", "200"), ("uppercased", "Header")])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders,
            type: .response
        )
    }

    func testWeDoNotNormalizeHeadersIfUserAskedUsNotToForRequests() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(
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
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders,
            type: .doNotValidate
        )
    }

    func testWeDoNotNormalizeHeadersIfUserAskedUsNotToForResponses() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ServerCodec(normalizeHTTPHeaders: false)
            )
        )

        var responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        responseHead.headers = HTTPHeaders([("UpperCased", "Header")])
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([(":status", "200"), ("UpperCased", "Header")])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders,
            type: .doNotValidate
        )
    }

    func testWeStripIllegalHeadersAsWellAsTheHeadersNominatedByTheConnectionHeaderForRequests() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
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
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders,
            type: .request
        )
    }

    func testWeStripTransferEncodingChunkedHeader() {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request.
        var requestHead = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .POST, uri: "/post")
        requestHead.headers = HTTPHeaders([
            ("host", "example.org"),
            ("Transfer-Encoding", "chunked"),
        ])
        self.channel.writeAndFlush(HTTPClientRequestPart.head(requestHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"),
            (":authority", "example.org"),
        ])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders,
            type: .request
        )
    }

    func testWeStripIllegalHeadersAsWellAsTheHeadersNominatedByTheConnectionHeaderForResponses() throws {
        let writeRecorder = FramePayloadWriteRecorder()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        var responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0), status: .ok)
        responseHead.headers = HTTPHeaders([
            ("connection", "keep-alive, also-to-be-removed"),
            ("keep-alive", "foo"), ("also-to-be-removed", "yes"), ("should", "stay"),
            ("Proxy-Connection", "bad"), ("Transfer-Encoding", "also bad"),
        ])
        self.channel.writeAndFlush(HTTPServerResponsePart.head(responseHead), promise: nil)

        let expectedRequestHeaders = HPACKHeaders([(":status", "200"), ("should", "stay")])
        XCTAssertEqual(writeRecorder.flushedWrites.count, 1)
        writeRecorder.flushedWrites[0].assertHeadersFramePayload(
            endStream: false,
            headers: expectedRequestHeaders,
            type: .response
        )
    }

    func testServerSideWithEmptyFinalPackage() throws {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

        // A basic request.
        let requestHeaders = HPACKHeaders([
            (":path", "/post"), (":method", "POST"), (":scheme", "https"), (":authority", "example.org"),
        ])
        XCTAssertNoThrow(try self.channel.writeInbound(HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders))))

        var expectedRequestHead = HTTPRequestHead(version: HTTPVersion(major: 2, minor: 0), method: .POST, uri: "/post")
        expectedRequestHead.headers.add(name: "host", value: "example.org")
        expectedRequestHead.headers.add(name: "transfer-encoding", value: "chunked")
        self.channel.assertReceivedServerRequestPart(.head(expectedRequestHead))

        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: false))
        XCTAssertNoThrow(try self.channel.writeInbound(dataPayload))
        self.channel.assertReceivedServerRequestPart(.body(bodyData))

        let endPayload = HTTP2Frame.FramePayload.data(
            .init(data: .byteBuffer(self.channel.allocator.buffer(capacity: 0)), endStream: true)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(endPayload))
        self.channel.assertReceivedServerRequestPart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testClientSideWithEmptyFinalPackage() throws {
        XCTAssertNoThrow(
            try self.channel.pipeline.syncOperations.addHandler(
                HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
            )
        )

        // A basic request.
        let requestHeaders = HPACKHeaders([("host", "example.org"), ("other", "header")])
        var requestHead = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/get")
        requestHead.headers = HTTPHeaders(regularHeadersFrom: requestHeaders)
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPClientRequestPart.head(requestHead)))

        // A basic response.
        let responseHeaders = HTTPHeaders([(":status", "200")])
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTP2Frame.FramePayload.headers(.init(headers: HPACKHeaders(httpHeaders: responseHeaders)))
            )
        )

        let expectedResponseHead = HTTPResponseHead(
            version: .init(major: 2, minor: 0),
            status: .ok,
            headers: ["transfer-encoding": "chunked"]
        )
        self.channel.assertReceivedClientResponsePart(.head(expectedResponseHead))

        var bodyData = self.channel.allocator.buffer(capacity: 12)
        bodyData.writeStaticString("hello, world!")
        let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: true))
        XCTAssertNoThrow(try self.channel.writeInbound(dataPayload))
        self.channel.assertReceivedClientResponsePart(.body(bodyData))

        let endPayload = HTTP2Frame.FramePayload.data(
            .init(data: .byteBuffer(self.channel.allocator.buffer(capacity: 0)), endStream: true)
        )
        XCTAssertNoThrow(try self.channel.writeInbound(endPayload))
        self.channel.assertReceivedClientResponsePart(.end(nil))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testRequestMethodsWithoutDefinedSemanticsForAPayloadDontGetTransferEncodingAdded() {
        let methods: [HTTPMethod] = [.GET, .HEAD, .DELETE, .CONNECT, .TRACE]
        for method in methods {
            let embedded = EmbeddedChannel()

            XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

            // A basic request.
            let requestHeaders = HPACKHeaders([
                (":path", "/"), (":method", "\(method)"), (":scheme", "https"), (":authority", "example.org"),
                ("other", "header"),
            ])
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders, endStream: false))
                )
            )
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(.init()), endStream: true))
                )
            )

            var expectedRequestHead = HTTPRequestHead(
                version: HTTPVersion(major: 2, minor: 0),
                method: method,
                uri: "/"
            )
            expectedRequestHead.headers.add(name: "host", value: "example.org")
            expectedRequestHead.headers.add(name: "other", value: "header")
            embedded.assertReceivedServerRequestPart(.head(expectedRequestHead))
            embedded.assertReceivedServerRequestPart(.end(nil))

            XCTAssertNoThrow(try embedded.finish())
        }
    }

    func testRequestMethodsWithoutDefinedSemanticsForAPayloadDontRemoveContentLengthIfSet() {
        let methods: [HTTPMethod] = [.GET, .HEAD, .DELETE, .CONNECT, .TRACE]
        for method in methods {
            let embedded = EmbeddedChannel()

            XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

            // A basic request.
            let requestHeaders = HPACKHeaders([
                (":path", "/"), (":method", "\(method)"), (":scheme", "https"), (":authority", "example.org"),
                ("content-length", "13"),
            ])
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders, endStream: false))
                )
            )

            let bodyData = embedded.allocator.buffer(string: "hello, world!")
            let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: true))
            XCTAssertNoThrow(try embedded.writeInbound(dataPayload))
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(.init()), endStream: true))
                )
            )

            var expectedRequestHead = HTTPRequestHead(
                version: HTTPVersion(major: 2, minor: 0),
                method: method,
                uri: "/"
            )
            expectedRequestHead.headers.add(name: "host", value: "example.org")
            expectedRequestHead.headers.add(name: "content-length", value: "13")
            embedded.assertReceivedServerRequestPart(.head(expectedRequestHead))
            embedded.assertReceivedServerRequestPart(.body(bodyData))
            embedded.assertReceivedServerRequestPart(.end(nil))

            XCTAssertNoThrow(try embedded.finish())
        }
    }

    func testRequestMethodsWithDefinedSemanticsForAPayloadAddContentLengthHeaderIfEmpty() {
        let methods: [HTTPMethod] = [
            .PUT, .ACL, .POST, .COPY, .LOCK, .MOVE, .BIND, .LINK, .PATCH, .MKCOL, .MERGE, .PURGE,
            .NOTIFY, .SEARCH, .UNLOCK, .REBIND, .UNBIND, .REPORT, .UNLINK, .MSEARCH, .OPTIONS,
            .PROPFIND, .CHECKOUT, .PROPPATCH, .SUBSCRIBE, .MKCALENDAR, .MKACTIVITY, .UNSUBSCRIBE,
            .SOURCE,
        ]

        for method in methods {
            let embedded = EmbeddedChannel()

            XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

            // A basic request.
            let requestHeaders = HPACKHeaders([
                (":path", "/"), (":method", "\(method)"), (":scheme", "https"), (":authority", "example.org"),
            ])
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders, endStream: true))
                )
            )

            var expectedRequestHead = HTTPRequestHead(
                version: HTTPVersion(major: 2, minor: 0),
                method: method,
                uri: "/"
            )
            expectedRequestHead.headers.add(name: "host", value: "example.org")
            expectedRequestHead.headers.add(name: "content-length", value: "0")
            embedded.assertReceivedServerRequestPart(.head(expectedRequestHead))
            embedded.assertReceivedServerRequestPart(.end(nil))

            XCTAssertNoThrow(try embedded.finish())
        }
    }

    func testRequestMethodsWithDefinedSemanticsForAPayloadAddTransferEncodingIfNotEmpty() {
        let methods: [HTTPMethod] = [
            .PUT, .ACL, .POST, .COPY, .LOCK, .MOVE, .BIND, .LINK, .PATCH, .MKCOL, .MERGE, .PURGE,
            .NOTIFY, .SEARCH, .UNLOCK, .REBIND, .UNBIND, .REPORT, .UNLINK, .MSEARCH, .OPTIONS,
            .PROPFIND, .CHECKOUT, .PROPPATCH, .SUBSCRIBE, .MKCALENDAR, .MKACTIVITY, .UNSUBSCRIBE,
            .SOURCE,
        ]

        for method in methods {
            let embedded = EmbeddedChannel()

            XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

            // A basic request.
            let requestHeaders = HPACKHeaders([
                (":path", "/"), (":method", "\(method)"), (":scheme", "https"), (":authority", "example.org"),
            ])
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders, endStream: false))
                )
            )
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(.init()), endStream: true))
                )
            )

            var expectedRequestHead = HTTPRequestHead(
                version: HTTPVersion(major: 2, minor: 0),
                method: method,
                uri: "/"
            )
            expectedRequestHead.headers.add(name: "host", value: "example.org")
            expectedRequestHead.headers.add(name: "transfer-encoding", value: "chunked")
            embedded.assertReceivedServerRequestPart(.head(expectedRequestHead))
            embedded.assertReceivedServerRequestPart(.end(nil))

            XCTAssertNoThrow(try embedded.finish())
        }
    }

    func testRequestContentLengthIsAlwaysPreserved() {
        let methods: [HTTPMethod] = [
            // methods in which a body has no defined meaning
            .GET, .HEAD, .DELETE, .CONNECT, .TRACE,

            // methods in which a body has a defined meaning
            .PUT, .ACL, .POST, .COPY, .LOCK, .MOVE, .BIND, .LINK, .PATCH, .MKCOL, .MERGE, .PURGE,
            .NOTIFY, .SEARCH, .UNLOCK, .REBIND, .UNBIND, .REPORT, .UNLINK, .MSEARCH, .OPTIONS,
            .PROPFIND, .CHECKOUT, .PROPPATCH, .SUBSCRIBE, .MKCALENDAR, .MKACTIVITY, .UNSUBSCRIBE,
            .SOURCE,
        ]

        for method in methods {
            let embedded = EmbeddedChannel()

            XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()))

            // A basic request.
            let requestHeaders = HPACKHeaders([
                (":path", "/"), (":method", "\(method)"), (":scheme", "https"), (":authority", "example.org"),
                ("content-length", "13"),
            ])
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders, endStream: false))
                )
            )

            let bodyData = embedded.allocator.buffer(string: "hello, world!")
            let dataPayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(bodyData), endStream: true))
            XCTAssertNoThrow(try embedded.writeInbound(dataPayload))
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(.init()), endStream: true))
                )
            )

            var expectedRequestHead = HTTPRequestHead(
                version: HTTPVersion(major: 2, minor: 0),
                method: method,
                uri: "/"
            )
            expectedRequestHead.headers.add(name: "host", value: "example.org")
            expectedRequestHead.headers.add(name: "content-length", value: "13")
            embedded.assertReceivedServerRequestPart(.head(expectedRequestHead))
            embedded.assertReceivedServerRequestPart(.body(bodyData))
            embedded.assertReceivedServerRequestPart(.end(nil))

            XCTAssertNoThrow(try embedded.finish())
        }
    }

    func testResponseTransferEncodingIsNotAddedInReponseToHEADorCONNECT() {
        let methods: [HTTPMethod] = [
            // methods in which a body has no defined meaning
            .HEAD, .CONNECT,
        ]

        for method in methods {
            let embedded = EmbeddedChannel()

            let writeRecorder = FramePayloadWriteRecorder()
            XCTAssertNoThrow(try embedded.pipeline.addHandler(writeRecorder).wait())
            XCTAssertNoThrow(
                try embedded.pipeline.syncOperations.addHandler(
                    HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https, normalizeHTTPHeaders: true)
                )
            )

            let requestHead = HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: "/",
                headers: ["Host": "example.org"]
            )
            XCTAssertNoThrow(try embedded.writeOutbound(HTTPClientRequestPart.head(requestHead)))
            XCTAssertNoThrow(try embedded.writeOutbound(HTTPClientRequestPart.end(nil)))

            let expectedRequestHeaders = HPACKHeaders([
                (":path", "/"), (":method", "\(method)"), (":scheme", "https"), (":authority", "example.org"),
            ])
            writeRecorder.flushedWrites[0].assertHeadersFramePayload(
                endStream: false,
                headers: expectedRequestHeaders,
                type: .doNotValidate
            )
            writeRecorder.flushedWrites[1].assertDataFramePayload(endStream: true, payload: ByteBuffer())

            let responseHeaders = HPACKHeaders(httpHeaders: [":status": "200"])
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.headers(.init(headers: responseHeaders, endStream: true))
                )
            )

            let expectedResponseHead = HTTPResponseHead(version: .http2, status: .ok)
            embedded.assertReceivedClientResponsePart(.head(expectedResponseHead))
            embedded.assertReceivedClientResponsePart(.end(nil))
        }
    }

    func testResponseTransferEncodingIsNotAddedInReponseWithStatus1xxor204or304() {
        let responseStatus: [HTTPResponseStatus] = [
            // methods in which a body has no defined meaning
            .continue, .switchingProtocols, .processing, .init(statusCode: 103, reasonPhrase: ""),
            .noContent, .notModified,
        ]

        for status in responseStatus {
            let embedded = EmbeddedChannel()

            let writeRecorder = FramePayloadWriteRecorder()
            XCTAssertNoThrow(try embedded.pipeline.addHandler(writeRecorder).wait())
            XCTAssertNoThrow(
                try embedded.pipeline.syncOperations.addHandler(
                    HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https, normalizeHTTPHeaders: true)
                )
            )

            let requestHead = HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/",
                headers: ["Host": "example.org"]
            )
            XCTAssertNoThrow(try embedded.writeOutbound(HTTPClientRequestPart.head(requestHead)))
            XCTAssertNoThrow(try embedded.writeOutbound(HTTPClientRequestPart.end(nil)))

            let expectedRequestHeaders = HPACKHeaders([
                (":path", "/"), (":method", "GET"), (":scheme", "https"), (":authority", "example.org"),
            ])
            writeRecorder.flushedWrites[0].assertHeadersFramePayload(
                endStream: false,
                headers: expectedRequestHeaders,
                type: .doNotValidate
            )
            writeRecorder.flushedWrites[1].assertDataFramePayload(endStream: true, payload: ByteBuffer())

            let responseHeaders = HPACKHeaders(httpHeaders: [":status": "\(status.code)"])
            XCTAssertNoThrow(
                try embedded.writeInbound(
                    HTTP2Frame.FramePayload.headers(.init(headers: responseHeaders, endStream: true))
                )
            )

            let expectedResponseHead = HTTPResponseHead(version: .http2, status: status)
            embedded.assertReceivedClientResponsePart(.head(expectedResponseHead))
            if status.code >= 200 {
                embedded.assertReceivedClientResponsePart(.end(nil))
            }
        }
    }

}
