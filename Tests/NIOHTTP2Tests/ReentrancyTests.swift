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
import NIOHPACK
import NIOHTTP1
import NIOHTTP2
import XCTest

/// A `ChannelInboundHandler` that re-entrantly calls into a handler that just passed
/// it `channelRead`.
final class ReenterOnReadHandler: ChannelInboundHandler {
    public typealias InboundIn = Any

    // We only want to re-enter once. Otherwise we could loop indefinitely.
    private var shouldReenter = true

    private let reEnterCallback: (ChannelPipeline) -> Void

    init(reEnterCallback: @escaping (ChannelPipeline) -> Void) {
        self.reEnterCallback = reEnterCallback
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard self.shouldReenter else {
            context.fireChannelRead(data)
            return
        }
        self.shouldReenter = false
        context.fireChannelRead(data)
        self.reEnterCallback(context.pipeline)
    }
}

final class WindowUpdatedEventHandler: ChannelInboundHandler, Sendable {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    init() {
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is NIOHTTP2WindowUpdatedEvent else { return }

        let frame = HTTP2Frame(streamID: .rootStream, payload: .windowUpdate(windowSizeIncrement: 1))
        context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
    }
}

// Tests that the HTTP2Parser is safely re-entrant.
//
// These tests ensure that we don't ever call into the HTTP/2 session more than once at a time.
final class ReentrancyTests: XCTestCase {
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
        XCTAssertNoThrow(try self.clientChannel.pipeline.syncOperations.addHandler(NIOHTTP2Handler(mode: .client)))
        XCTAssertNoThrow(try self.serverChannel.pipeline.syncOperations.addHandler(NIOHTTP2Handler(mode: .server)))
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)
    }

    func testReEnterReadOnRead() throws {
        // Start by setting up the connection.
        try self.basicHTTP2Connection()

        // Here we're going to prepare some frames: specifically, we're going to send a SETTINGS frame and a PING frame at the same time.
        // We need to send two frames to try to catch any ordering problems we might hit.
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .enablePush, value: 0), HTTP2Setting(parameter: .maxConcurrentStreams, value: 5),
        ]
        let settingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        self.clientChannel.write(settingsFrame, promise: nil)
        self.clientChannel.write(pingFrame, promise: nil)
        self.clientChannel.flush()

        // Collect the serialized frames.
        var frameBuffer = self.clientChannel.allocator.buffer(capacity: 1024)
        while case .some(.byteBuffer(var buf)) = try assertNoThrowWithValue(
            self.clientChannel.readOutbound(as: IOData.self)
        ) {
            frameBuffer.writeBuffer(&buf)
        }

        // Ok, now we can add in the re-entrancy handler to the server channel. When it first gets a frame it's
        // going to fire in the buffer again.
        let reEntrancyHandler = ReenterOnReadHandler { $0.fireChannelRead(frameBuffer) }
        XCTAssertNoThrow(try self.serverChannel.pipeline.syncOperations.addHandler(reEntrancyHandler))

        // Now we can deliver these bytes.
        XCTAssertTrue(try self.serverChannel.writeInbound(frameBuffer).isFull)

        // If this worked, we want to see that the server received SETTINGS, PING, SETTINGS, PING. No other order is
        // ok, no errors should have been hit.
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: settingsFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: pingFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: settingsFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: pingFrame)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testReenterInactiveOnRead() throws {
        // Start by setting up the connection.
        try self.basicHTTP2Connection()

        // Here we're going to prepare some frames: specifically, we're going to send a SETTINGS frame and a PING frame at the same time.
        // We need to send two frames to try to catch any ordering problems we might hit.
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .enablePush, value: 0), HTTP2Setting(parameter: .maxConcurrentStreams, value: 5),
        ]
        let settingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        self.clientChannel.write(settingsFrame, promise: nil)
        self.clientChannel.write(pingFrame, promise: nil)
        self.clientChannel.flush()

        // Ok, now we can add in the re-entrancy handler to the server channel. When it first gets a frame it's
        // going to fire channelInactive.
        let reEntrancyHandler = ReenterOnReadHandler { $0.fireChannelInactive() }
        XCTAssertNoThrow(try self.serverChannel.pipeline.syncOperations.addHandler(reEntrancyHandler))

        // Now we can deliver these bytes.
        self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)

        // If this worked, we want to see that the server received SETTINGS. The PING frame should not be produced, as
        // the channelInactive has been fired. No other order is ok, no errors should have been hit, and the channel
        // should now be closed.
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: settingsFrame)

        XCTAssertNoThrow(try self.clientChannel.finish())
    }

    func testReenterReadEOFOnRead() throws {
        // Start by setting up the connection.
        try self.basicHTTP2Connection()

        // Here we're going to prepare some frames: specifically, we're going to send a SETTINGS frame and a PING frame at the same time.
        // We need to send two frames to try to catch any ordering problems we might hit.
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .enablePush, value: 0), HTTP2Setting(parameter: .maxConcurrentStreams, value: 5),
        ]
        let settingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5), ack: false))
        self.clientChannel.write(settingsFrame, promise: nil)
        self.clientChannel.write(pingFrame, promise: nil)
        self.clientChannel.flush()

        // Ok, now we can add in the re-entrancy handler to the server channel. When it first gets a frame it's
        // going to fire channelInactive.
        let reEntrancyHandler = ReenterOnReadHandler { $0.fireUserInboundEventTriggered(ChannelEvent.inputClosed) }
        XCTAssertNoThrow(try self.serverChannel.pipeline.syncOperations.addHandler(reEntrancyHandler))

        // Now we can deliver these bytes.
        self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)

        // If this worked, we want to see that the server received SETTINGS then PING. No other order is
        // ok, no errors should have been hit, and the channel should now be closed.
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: settingsFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: pingFrame)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testReenterAutomaticFrames() throws {
        // Start by setting up the connection.
        try self.basicHTTP2Connection()
        let windowUpdateFrameHandler = WindowUpdatedEventHandler()
        XCTAssertNoThrow(try self.serverChannel.pipeline.addHandler(windowUpdateFrameHandler).wait())

        // Write and flush the header from the client to open a stream
        let headers = HPACKHeaders([
            (":path", "/"), (":method", "POST"), (":scheme", "https"), (":authority", "localhost"),
        ])
        let reqFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: headers))
        self.clientChannel.writeAndFlush(HTTP2Frame(streamID: 1, payload: reqFramePayload), promise: nil)
        self.interactInMemory(clientChannel, serverChannel)

        // Write and flush the header from the server
        let resHeaders = HPACKHeaders([(":status", "200")])
        let resFramePayload = HTTP2Frame.FramePayload.headers(.init(headers: resHeaders))
        self.serverChannel.writeAndFlush(HTTP2Frame(streamID: 1, payload: resFramePayload), promise: nil)

        // Write lots of small data frames and flush them all at once
        var requestBody = self.serverChannel.allocator.buffer(capacity: 1)
        requestBody.writeBytes(Array(repeating: UInt8(0x04), count: 1))
        var reqBodyFramePayload = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(requestBody)))
        for _ in 0..<10000 {
            serverChannel.write(HTTP2Frame(streamID: 1, payload: reqBodyFramePayload), promise: nil)
        }
        reqBodyFramePayload = .data(.init(data: .byteBuffer(requestBody), endStream: true))
        serverChannel.writeAndFlush(HTTP2Frame(streamID: 1, payload: reqBodyFramePayload), promise: nil)

        // Now we can deliver these bytes.
        self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
