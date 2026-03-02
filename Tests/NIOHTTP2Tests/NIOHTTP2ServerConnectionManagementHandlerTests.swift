//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// swift-format-ignore: NoBlockComments
/*
 * Copyright 2024, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import NIOCore
import NIOEmbedded
import NIOHPACK
import Testing

@testable import NIOHTTP2

struct NIOHTTP2ServerConnectionManagementHandlerTests {
    @Test("Idle timeout on new connection")
    func idleTimeoutOnNewConnection() throws {
        let connection = try Connection(maxIdleTime: .minutes(1))
        try connection.activate()
        // Hit the max idle time.
        connection.advanceTime(by: .minutes(1))

        // Follow the graceful shutdown flow.
        try self.testGracefulShutdown(connection: connection, lastStreamID: 0)

        // Closed because no streams were open.
        try connection.waitUntilClosed()
    }

    @Test("Idle timeout is cancelled when stream is opened")
    func idleTimerIsCancelledWhenStreamIsOpened() throws {
        let connection = try Connection(maxIdleTime: .minutes(1))
        try connection.activate()

        // Open a stream to cancel the idle timer and run through the max idle time.
        connection.streamOpened(1)
        connection.advanceTime(by: .minutes(1))

        // No GOAWAY frame means the timer was cancelled.
        #expect(try connection.readFrame() == nil)
    }

    @Test("Idle timer starts when all streams are closed")
    func idleTimerStartsWhenAllStreamsAreClosed() throws {
        let connection = try Connection(maxIdleTime: .minutes(1))
        try connection.activate()

        // Open a stream to cancel the idle timer and run through the max idle time.
        connection.streamOpened(1)
        connection.advanceTime(by: .minutes(1))
        #expect(try connection.readFrame() == nil)

        // Close the stream to start the timer again.
        connection.streamClosed(1)
        connection.advanceTime(by: .minutes(1))

        // Follow the graceful shutdown flow.
        try self.testGracefulShutdown(connection: connection, lastStreamID: 1)

        // Closed because no streams were open.
        try connection.waitUntilClosed()
    }

    @Test("Connection shutdown after max age is reached")
    func maxAge() throws {
        let connection = try Connection(maxAge: .minutes(1))
        try connection.activate()

        // Open some streams.
        connection.streamOpened(1)
        connection.streamOpened(3)

        // Run to the max age and follow the graceful shutdown flow.
        connection.advanceTime(by: .minutes(1))
        try self.testGracefulShutdown(connection: connection, lastStreamID: 3)

        // Close the streams.
        connection.streamClosed(1)
        connection.streamClosed(3)

        // Connection will be closed now.
        try connection.waitUntilClosed()
    }

    @Test("Graceful shutdown ratchets down last stream ID")
    func gracefulShutdownRatchetsDownStreamID() throws {
        // This test uses the idle timeout to trigger graceful shutdown. The mechanism is the same
        // regardless of how it's triggered.
        let connection = try Connection(maxIdleTime: .minutes(1))
        try connection.activate()

        // Trigger the shutdown, but open a stream during shutdown.
        connection.advanceTime(by: .minutes(1))
        try self.testGracefulShutdown(
            connection: connection,
            lastStreamID: 1,
            streamToOpenBeforePingAck: 1
        )

        // Close the stream to trigger closing the connection.
        connection.streamClosed(1)
        try connection.waitUntilClosed()
    }

    @Test("Graceful shutdown promoted to close after grace period")
    func gracefulShutdownGracePeriod() throws {
        // This test uses the idle timeout to trigger graceful shutdown. The mechanism is the same
        // regardless of how it's triggered.
        let connection = try Connection(
            maxIdleTime: .minutes(1),
            maxGraceTime: .seconds(5)
        )
        try connection.activate()

        // Trigger the shutdown, but open a stream during shutdown.
        connection.advanceTime(by: .minutes(1))
        try self.testGracefulShutdown(
            connection: connection,
            lastStreamID: 1,
            streamToOpenBeforePingAck: 1
        )

        // Wait out the grace period without closing the stream.
        connection.advanceTime(by: .seconds(5))
        try connection.waitUntilClosed()
    }

    @Test("Keepalive works on new connection")
    func keepaliveOnNewConnection() throws {
        let connection = try Connection(
            keepaliveConfiguration: .init(
                pingInterval: .minutes(5),
                ackTimeout: .seconds(5)
            )
        )
        try connection.activate()

        // Wait for the keep alive timer to fire which should cause the server to send a keep
        // alive PING.
        connection.advanceTime(by: .minutes(5))
        let frame1 = try #require(try connection.readFrame())
        #expect(frame1.streamID == .rootStream)
        let (data, ack) = try #require(frame1.payload.ping)
        #expect(!ack)
        // Data is opaque, send it back.
        try connection.ping(data: data, ack: true)

        // Run past the timeout, nothing should happen.
        connection.advanceTime(by: .seconds(5))
        #expect(try connection.readFrame() == nil)
    }

    @Test("Keepalive starts after read loop")
    func keepaliveStartsAfterReadLoop() throws {
        let connection = try Connection(
            keepaliveConfiguration: .init(
                pingInterval: .minutes(5),
                ackTimeout: .seconds(5)
            )
        )
        try connection.activate()

        // Write a frame into the channel _without_ calling channel read complete. This will cancel
        // the keep alive timer.
        let settings = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings([])))
        connection.channel.pipeline.fireChannelRead(settings)

        // Run out the keep alive timer, it shouldn't fire.
        connection.advanceTime(by: .minutes(5))
        #expect(try connection.readFrame() == nil)

        // Fire channel read complete to start the keep alive timer again.
        connection.channel.pipeline.fireChannelReadComplete()

        // Now expire the keep alive timer again, we should read out a PING frame.
        connection.advanceTime(by: .minutes(5))
        let frame1 = try #require(try connection.readFrame())
        #expect(frame1.streamID == .rootStream)
        let (_, ack) = try #require(frame1.payload.ping)
        #expect(!ack)
    }

    @Test("Keepalive works on new connection without response")
    func keepaliveOnNewConnectionWithoutResponse() throws {
        let connection = try Connection(
            keepaliveConfiguration: .init(
                pingInterval: .minutes(5),
                ackTimeout: .seconds(5)
            )
        )
        try connection.activate()

        // Wait for the keep alive timer to fire which should cause the server to send a keep
        // alive PING.
        connection.advanceTime(by: .minutes(5))
        let frame1 = try #require(try connection.readFrame())
        #expect(frame1.streamID == .rootStream)
        let (_, ack) = try #require(frame1.payload.ping)
        #expect(!ack)

        // We didn't ack the PING, the connection should shutdown after the timeout.
        connection.advanceTime(by: .seconds(5))
        try self.testGracefulShutdown(connection: connection, lastStreamID: 0)

        // Connection is closed now.
        try connection.waitUntilClosed()
    }

    @Test("Doesn't close on error")
    func doesNotCloseOnError() throws {
        let connection = try Connection(maxIdleTime: .minutes(1))
        try connection.activate()

        // Fire an arbitrary error: `ServerConnectionManagementHandler` should just be propagating it down the pipeline
        // and not be doing anything special.
        connection.channel.pipeline.fireErrorCaught(TestCaseError())

        // The channel should still be open.
        #expect(connection.channel.isActive == true)

        // Check the error has propagated.
        #expect(throws: TestCaseError.self) {
            try connection.channel.throwIfErrorCaught()
        }

        // Follow a normal flow to check the connection wasn't closed.
        //
        // Advance halfway through the max idle time.
        connection.advanceTime(by: .seconds(30))
        // Graceful shutdown shouldn't have been triggered yet.
        #expect(try connection.readFrame() == nil)

        // Now hit the max idle time.
        connection.advanceTime(by: .seconds(30))

        // Follow the graceful shutdown flow.
        try self.testGracefulShutdown(connection: connection, lastStreamID: 0)
        // Closed because no streams were open.
        try connection.waitUntilClosed()
    }
}

extension NIOHTTP2ServerConnectionManagementHandlerTests {
    private func testGracefulShutdown(
        connection: Connection,
        lastStreamID: HTTP2StreamID,
        streamToOpenBeforePingAck: HTTP2StreamID? = nil
    ) throws {
        do {
            let frame = try #require(try connection.readFrame())
            #expect(frame.streamID == .rootStream)

            let (streamID, errorCode, _) = try #require(frame.payload.goAway)
            #expect(streamID == .maxID)
            #expect(errorCode == .noError)
        }

        // Followed by a PING
        do {
            let frame = try #require(try connection.readFrame())
            #expect(frame.streamID == .rootStream)

            let (data, ack) = try #require(frame.payload.ping)
            #expect(!ack)

            if let id = streamToOpenBeforePingAck {
                connection.streamOpened(id)
            }

            // Send the PING ACK.
            try connection.ping(data: data, ack: true)
        }

        // PING ACK triggers another GOAWAY.
        do {
            let frame = try #require(try connection.readFrame())
            #expect(frame.streamID == .rootStream)

            let (streamID, errorCode, _) = try #require(frame.payload.goAway)
            #expect(streamID == lastStreamID)
            #expect(errorCode == .noError)
        }
    }
}
extension NIOHTTP2ServerConnectionManagementHandlerTests {
    struct Connection {
        let channel: EmbeddedChannel
        let streamDelegate: any NIOHTTP2StreamDelegate

        var loop: EmbeddedEventLoop {
            self.channel.embeddedEventLoop
        }

        init(
            maxIdleTime: TimeAmount? = nil,
            maxAge: TimeAmount? = nil,
            maxGraceTime: TimeAmount? = nil,
            keepaliveConfiguration: NIOHTTP2ServerConnectionManagementHandler.Configuration.Keepalive? = nil
        ) throws {
            let loop = EmbeddedEventLoop()
            let handler = NIOHTTP2ServerConnectionManagementHandler(
                eventLoop: loop,
                configuration: .init(
                    maxIdleTime: maxIdleTime,
                    maxAge: maxAge,
                    maxGraceTime: maxGraceTime,
                    keepalive: keepaliveConfiguration
                )
            )

            self.streamDelegate = handler.http2StreamDelegate
            self.channel = EmbeddedChannel(handler: handler, loop: loop)
        }

        func activate() throws {
            try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        }

        func advanceTime(by delta: TimeAmount) {
            self.loop.advanceTime(by: delta)
        }

        func streamOpened(_ id: HTTP2StreamID) {
            self.streamDelegate.streamCreated(id, channel: self.channel)
        }

        func streamClosed(_ id: HTTP2StreamID) {
            self.streamDelegate.streamClosed(id, channel: self.channel)
        }

        func ping(data: HTTP2PingData, ack: Bool) throws {
            let frame = HTTP2Frame(streamID: .rootStream, payload: .ping(data, ack: ack))
            try self.channel.writeInbound(frame)
        }

        func readFrame() throws -> HTTP2Frame? {
            try self.channel.readOutbound(as: HTTP2Frame.self)
        }

        func waitUntilClosed() throws {
            self.channel.embeddedEventLoop.run()
            try self.channel.closeFuture.wait()
        }
    }
}

extension HTTP2Frame.FramePayload {
    var goAway: (lastStreamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, opaqueData: ByteBuffer?)? {
        switch self {
        case .goAway(let lastStreamID, let errorCode, let opaqueData):
            return (lastStreamID, errorCode, opaqueData)
        default:
            return nil
        }
    }

    var ping: (data: HTTP2PingData, ack: Bool)? {
        switch self {
        case .ping(let data, let ack):
            return (data, ack)
        default:
            return nil
        }
    }
}
