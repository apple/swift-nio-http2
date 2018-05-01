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

    /// Establish a basic HTTP/2 connection.
    func basicHTTP2Connection() throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.add(handler: HTTP2Parser(mode: .client)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server)).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)
    }

    func testBasicRequestResponse() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        let clientStreamID = HTTP2StreamID()
        var reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        reqFrame.endHeaders = true
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true

        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Let's send a quick response back.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
        respFrame.endHeaders = true
        respFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testManyRequestsAtOnce() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        let requestHeaders = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")

        // We're going to send three requests before we flush.
        var clientStreamIDs = [HTTP2StreamID]()
        var headersFrames = [HTTP2Frame]()
        var dataFrames = [HTTP2Frame]()

        for _ in 0..<3 {
            let streamID = HTTP2StreamID()
            var reqFrame = HTTP2Frame(streamID: streamID, payload: .headers(requestHeaders))
            reqFrame.endHeaders = true
            var reqBodyFrame = HTTP2Frame(streamID: streamID, payload: .data(.byteBuffer(requestBody)))
            reqBodyFrame.endStream = true

            self.clientChannel.write(reqFrame, promise: nil)
            self.clientChannel.write(reqBodyFrame, promise: nil)

            clientStreamIDs.append(streamID)
            headersFrames.append(reqFrame)
            dataFrames.append(reqBodyFrame)
        }
        self.clientChannel.flush()
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // We expect to see all 3 headers frames emitted first, and then the data frames. This is an artefact of nghttp2,
        // but it's how it'll go.
        let frames = [headersFrames, dataFrames].flatMap { $0 }
        for frame in frames {
            let receivedFrame = try self.serverChannel.assertReceivedFrame()
            receivedFrame.assertFrameMatches(this: frame)
        }

        // There should be no frames here.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
