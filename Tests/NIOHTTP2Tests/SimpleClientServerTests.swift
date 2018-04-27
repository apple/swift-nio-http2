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

import XCTest
import NIO
import NIOHTTP1
import NIOHTTP2

class SimpleClientServerTests: XCTestCase {
    var clientChannel: EmbeddedChannel!
    var serverChannel: EmbeddedChannel!

    override func setUp() {
        self.clientChannel = EmbeddedChannel()
        self.serverChannel = EmbeddedChannel()
    }

    override func tearDown() {
        self.clientChannel = nil
        self.serverChannel = nil
    }

    func testBasicRequestResponse() throws {
        // Begin by getting the connection up.
        XCTAssertNoThrow(try self.clientChannel.pipeline.add(handler: HTTP2Parser(mode: .client)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server)).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)

        // We're now going to try to send a request from the client to the server.
        var requestHead = HTTPRequestHead(version: .init(major: 2, minor: 0), method: .POST, uri: "/")
        requestHead.headers.add(name: "host", value: "localhost")
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        var reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(.request(requestHead)))
        reqFrame.endHeaders = true
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        self.clientChannel.write(reqFrame, promise: nil)
        self.clientChannel.writeAndFlush(reqBodyFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        XCTAssertNil(self.clientChannel.readInbound())
        guard let firstFrame: HTTP2Frame = self.serverChannel.readInbound() else {
            XCTFail("No frame")
            return
        }
        XCTAssertEqual(firstFrame.streamID.networkStreamID!, clientStreamID.networkStreamID!)
        XCTAssertFalse(firstFrame.endStream)
        XCTAssertTrue(firstFrame.endHeaders)
        guard case .headers(.request(let receivedRequestHead)) = firstFrame.payload else {
            XCTFail("Payload incorrect")
            return
        }

        var expectedRequestHead = requestHead
        expectedRequestHead.headers.remove(name: "host")
        XCTAssertEqual(receivedRequestHead, expectedRequestHead)

        guard let secondFrame: HTTP2Frame = self.serverChannel.readInbound() else {
            XCTFail("No second frame")
            return
        }
        XCTAssertEqual(secondFrame.streamID.networkStreamID!, clientStreamID.networkStreamID!)
        XCTAssertTrue(secondFrame.endStream)
        guard case .data(.byteBuffer(let receivedData)) = secondFrame.payload else {
            XCTFail("Payload incorrect")
            return
        }

        XCTAssertEqual(receivedData, requestBody)

        // Let's send a quick response back.
        let responseHead = HTTPResponseHead(version: .init(major: 2, minor: 0),
                                            status: .ok,
                                            headers: HTTPHeaders([("content-length", "0")]))
        var respFrame = HTTP2Frame(streamID: firstFrame.streamID, payload: .headers(.response(responseHead)))
        respFrame.endHeaders = true
        respFrame.endStream = true
        self.serverChannel.writeAndFlush(respFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The client should have seen this.
        guard let receivedResponseFrame: HTTP2Frame = self.clientChannel.readInbound() else {
            XCTFail("No frame")
            return
        }
        XCTAssertEqual(receivedResponseFrame.streamID, clientStreamID)
        XCTAssertTrue(receivedResponseFrame.endStream)
        XCTAssertTrue(receivedResponseFrame.endHeaders)
        guard case .headers(.response(let receivedResponseHead)) = receivedResponseFrame.payload else {
            XCTFail("Payload incorrect")
            return
        }

        XCTAssertEqual(receivedResponseHead, responseHead)
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
