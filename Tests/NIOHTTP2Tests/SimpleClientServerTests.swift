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

    func testNothingButGoaway() throws {
        // A simple connection with a goaway should be no big deal.
        try self.basicHTTP2Connection()
        let goAwayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .rootStream, errorCode: .noError, opaqueData: nil))
        self.clientChannel.writeAndFlush(goAwayFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The server should have received a GOAWAY. Nothing else should have happened.
        let receivedGoawayFrame = try self.serverChannel.assertReceivedFrame()
        receivedGoawayFrame.assertFrameMatches(this: goAwayFrame)

        // Send the GOAWAY back to the client. Should be safe.
        self.serverChannel.writeAndFlush(goAwayFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // The client should not receive this GOAWAY frame, as it has shut down.
        self.clientChannel.assertNoFramesReceived()

        // All should be good.
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testGoAwayWithStreamsUpQuiescing() throws {
        // A simple connection with a goaway should be no big deal.
        try self.basicHTTP2Connection()

        // We're going to send a HEADERS frame from the client to the server.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        var reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        reqFrame.endHeaders = true
        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Now the server is going to send a GOAWAY frame with the maximum stream ID. This should quiesce the connection:
        // futher frames on stream 1 are allowed, but nothing else.
        let serverGoaway = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil))
        try self.assertFramesRoundTrip(frames: [serverGoaway], sender: self.serverChannel, receiver: self.clientChannel)

        // We should still be able to send DATA frames on stream 1 now.
        var requestBody = self.clientChannel.allocator.buffer(capacity: 128)
        requestBody.write(staticString: "A simple HTTP/2 request.")
        var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(requestBody)))
        reqBodyFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel)

        // The server will respond, closing this stream.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
        respFrame.endHeaders = true
        respFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        // The server can now GOAWAY down to stream 1. We evaluate the bytes here ourselves becuase the client won't see this frame.
        let secondServerGoaway = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: serverStreamID, errorCode: .noError, opaqueData: nil))
        self.serverChannel.writeAndFlush(secondServerGoaway, promise: nil)
        guard case .some(.byteBuffer(let bytes)) = self.serverChannel.readOutbound() else {
            XCTFail("No data sent from server")
            return
        }
        // A GOAWAY frame (type 7, 8 bytes long, no flags, on stream 0), with error code 0 and last stream ID 1.
        let expectedFrameBytes: [UInt8] = [0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        XCTAssertEqual(bytes.getBytes(at: bytes.readerIndex, length: bytes.readableBytes)!, expectedFrameBytes)

        // At this stage, everything is shut down.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()
        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testLargeDataFramesAreSplit() throws {
        // Big DATA frames get split up.
        try self.basicHTTP2Connection()

        // Start by opening the stream.
        let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
        let clientStreamID = HTTP2StreamID()
        var reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
        reqFrame.endHeaders = true
        let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

        // Confirm there's no bonus frame sitting around.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        // Now we're going to send in a frame that's just a bit larger than the max frame size of 1<<14.
        let frameSize = (1<<14) + 8
        var buffer = self.clientChannel.allocator.buffer(capacity: frameSize)

        /// To write this in as fast as possible, we're going to fill the buffer one int at a time.
        for val in (0..<(frameSize / MemoryLayout<Int>.size)) {
            buffer.write(integer: val)
        }

        // Now we'll try to send this in a DATA frame.
        var dataFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.byteBuffer(buffer)))
        dataFrame.endStream = true
        self.clientChannel.writeAndFlush(dataFrame, promise: nil)
        self.interactInMemory(self.clientChannel, self.serverChannel)

        // This should have produced two frames in the server. Both are DATA, one is max frame size and the other
        // is not.
        let firstFrame = try self.serverChannel.assertReceivedFrame()
        firstFrame.assertDataFrame(endStream: false, streamID: serverStreamID.networkStreamID!, payload: buffer.getSlice(at: 0, length: 1<<14)!)
        let secondFrame = try self.serverChannel.assertReceivedFrame()
        secondFrame.assertDataFrame(endStream: true, streamID: serverStreamID.networkStreamID!, payload: buffer.getSlice(at: 1<<14, length: 8)!)

        // The client should have got nothing.
        self.clientChannel.assertNoFramesReceived()

        // Now send a response from the server and shut things down.
        let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
        var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
        respFrame.endHeaders = true
        respFrame.endStream = true
        try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testSendingDataFrameWithSmallFile() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're now going to try to send a request from the client to the server with a file region for the body.
        let bodyContent = "Hello world, this is data from a file!"

        try withTemporaryFile(content: bodyContent) { (handle, path) in
            let region = try FileRegion(fileHandle: handle)
            let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let clientStreamID = HTTP2StreamID()
            var reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
            reqFrame.endHeaders = true
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.fileRegion(region)))
            reqBodyFrame.endStream = true

            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame, reqBodyFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Let's send a quick response back.
            let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
            respFrame.endHeaders = true
            respFrame.endStream = true
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testSendingDataFrameWithLargeFile() throws {
        // Begin by getting the connection up.
        try self.basicHTTP2Connection()

        // We're going to create a largish temp file: 3 data frames in size.
        var bodyData = self.clientChannel.allocator.buffer(capacity: 1<<14)
        for val in (0..<((1<<14) / MemoryLayout<Int>.size)) {
            bodyData.write(integer: val)
        }

        try withTemporaryFile { (handle, path) in
            for _ in (0..<3) {
                handle.appendBuffer(bodyData)
            }

            let region = try FileRegion(fileHandle: handle)

            // Start by sending the headers.
            let headers = HTTPHeaders([(":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost")])
            let clientStreamID = HTTP2StreamID()
            var reqFrame = HTTP2Frame(streamID: clientStreamID, payload: .headers(headers))
            reqFrame.endHeaders = true
            let serverStreamID = try self.assertFramesRoundTrip(frames: [reqFrame], sender: self.clientChannel, receiver: self.serverChannel).first!.streamID

            // Ok, we're gonna send the body here. This should create 4 streams.
            var reqBodyFrame = HTTP2Frame(streamID: clientStreamID, payload: .data(.fileRegion(region)))
            reqBodyFrame.endStream = true
            self.clientChannel.writeAndFlush(reqBodyFrame, promise: nil)
            self.interactInMemory(self.clientChannel, self.serverChannel)

            // We now expect 3 frames.
            for idx in (0..<3) {
                let frame = try self.serverChannel.assertReceivedFrame()
                frame.assertDataFrame(endStream: idx == 2, streamID: serverStreamID.networkStreamID!, payload: bodyData)
            }

            // Let's send a quick response back.
            let responseHeaders = HTTPHeaders([(":status", "200"), ("content-length", "0")])
            var respFrame = HTTP2Frame(streamID: serverStreamID, payload: .headers(responseHeaders))
            respFrame.endHeaders = true
            respFrame.endStream = true
            try self.assertFramesRoundTrip(frames: [respFrame], sender: self.serverChannel, receiver: self.clientChannel)

            // No frames left.
            self.clientChannel.assertNoFramesReceived()
            self.serverChannel.assertNoFramesReceived()
        }

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
