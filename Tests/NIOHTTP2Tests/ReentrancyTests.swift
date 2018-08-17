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

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        guard self.shouldReenter else {
            ctx.fireChannelRead(data)
            return
        }
        self.shouldReenter = false
        ctx.fireChannelRead(data)
        self.reEnterCallback(ctx.pipeline)
    }
}

final class NoChannelReadAfterInactive: ChannelInboundHandler {
    public typealias InboundIn = Any

    private var inactive = false

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        XCTAssertFalse(self.inactive)
        ctx.fireChannelRead(data)
    }

    func channelInactive(ctx: ChannelHandlerContext) {
        self.inactive = true
        ctx.fireChannelInactive()
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            self.inactive = true
        }
        ctx.fireUserInboundEventTriggered(event)
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
        XCTAssertNoThrow(try self.clientChannel.pipeline.add(handler: HTTP2Parser(mode: .client)).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: HTTP2Parser(mode: .server)).wait())
        try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel)
    }

    func testReEnterReadOnRead() throws {
        // Start by setting up the connection.
        try self.basicHTTP2Connection()

        // Here we're going to prepare some frames: specifically, we're going to send a SETTINGS frame and a PING frame at the same time.
        // We need to send two frames to try to catch any ordering problems we might hit.
        let settings: [HTTP2Setting] = [HTTP2Setting(parameter: .enablePush, value: 0), HTTP2Setting(parameter: .maxConcurrentStreams, value: 5)]
        let settingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(settings))
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5)))
        self.clientChannel.write(settingsFrame, promise: nil)
        self.clientChannel.write(pingFrame, promise: nil)
        self.clientChannel.flush()

        // Collect the serialized frames.
        var frameBuffer = self.clientChannel.allocator.buffer(capacity: 1024)
        while case .some(.byteBuffer(var buf)) = self.clientChannel.readOutbound() {
            frameBuffer.write(buffer: &buf)
        }

        // Ok, now we can add in the re-entrancy handler to the server channel. When it first gets a frame it's
        // going to fire in the buffer again.
        let reEntrancyHandler = ReenterOnReadHandler { $0.fireChannelRead(NIOAny(frameBuffer)) }
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: reEntrancyHandler).wait())

        // Now we can deliver these bytes.
        XCTAssertTrue(try self.serverChannel.writeInbound(frameBuffer))

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
        let settings: [HTTP2Setting] = [HTTP2Setting(parameter: .enablePush, value: 0), HTTP2Setting(parameter: .maxConcurrentStreams, value: 5)]
        let settingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(settings))
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5)))
        self.clientChannel.write(settingsFrame, promise: nil)
        self.clientChannel.write(pingFrame, promise: nil)
        self.clientChannel.flush()

        // Ok, now we can add in the re-entrancy handler to the server channel. When it first gets a frame it's
        // going to fire channelInactive. We're also going to add an ordering requirement that channelInactive not
        // precede any frames.
        let reEntrancyHandler = ReenterOnReadHandler { $0.fireChannelInactive() }
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: reEntrancyHandler).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: NoChannelReadAfterInactive()).wait())

        // Now we can deliver these bytes.
        self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)

        // If this worked, we want to see that the server received SETTINGS then PING. No other order is
        // ok, no errors should have been hit, and the channel should now be closed.
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: settingsFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: pingFrame)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testReenterReadEOFOnRead() throws {
        // Start by setting up the connection.
        try self.basicHTTP2Connection()

        // Here we're going to prepare some frames: specifically, we're going to send a SETTINGS frame and a PING frame at the same time.
        // We need to send two frames to try to catch any ordering problems we might hit.
        let settings: [HTTP2Setting] = [HTTP2Setting(parameter: .enablePush, value: 0), HTTP2Setting(parameter: .maxConcurrentStreams, value: 5)]
        let settingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(settings))
        let pingFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: 5)))
        self.clientChannel.write(settingsFrame, promise: nil)
        self.clientChannel.write(pingFrame, promise: nil)
        self.clientChannel.flush()

        // Ok, now we can add in the re-entrancy handler to the server channel. When it first gets a frame it's
        // going to fire channelInactive. We're also going to add an ordering requirement that channelInactive not
        // precede any frames.
        let reEntrancyHandler = ReenterOnReadHandler { $0.fireUserInboundEventTriggered(ChannelEvent.inputClosed) }
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: reEntrancyHandler).wait())
        XCTAssertNoThrow(try self.serverChannel.pipeline.add(handler: NoChannelReadAfterInactive()).wait())

        // Now we can deliver these bytes.
        self.deliverAllBytes(from: self.clientChannel, to: self.serverChannel)

        // If this worked, we want to see that the server received SETTINGS then PING. No other order is
        // ok, no errors should have been hit, and the channel should now be closed.
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: settingsFrame)
        try self.serverChannel.assertReceivedFrame().assertFrameMatches(this: pingFrame)

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
