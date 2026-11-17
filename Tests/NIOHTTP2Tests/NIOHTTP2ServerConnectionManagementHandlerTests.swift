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
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(expectedSecondGOAWAYStreamID: 0)
        )

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
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(expectedSecondGOAWAYStreamID: 1)
        )

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
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(expectedSecondGOAWAYStreamID: 3)
        )

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
            pingAckConfiguration: .enable(
                openStreamBeforeSending: 1,
                expectedSecondGOAWAYStreamID: 1
            )
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
            pingAckConfiguration: .enable(
                openStreamBeforeSending: 1,
                expectedSecondGOAWAYStreamID: 1
            )
        )

        // Wait out the grace period without closing the stream.
        connection.advanceTime(by: .seconds(5))
        try connection.waitUntilClosed()
    }

    @Test("Connection is forcefully closed after timeout when the client does not send a PING ACK")
    func connectionForcefullyClosedWhenPingAckDoesNotArrive() throws {
        let connection = try Connection(
            maxIdleTime: .minutes(1),
            maxGraceTime: .seconds(5)
        )
        try connection.activate()

        // The idle timer will trigger the graceful shutdown.
        connection.advanceTime(by: .minutes(1))

        try self.testGracefulShutdown(
            connection: connection,
            // The client will not send a PING ACK.
            pingAckConfiguration: .disable
        )

        // Wait 4 seconds. The connection should still be open.
        connection.advanceTime(by: .seconds(4))
        #expect(connection.channel.isActive)

        // Once the grace period passes, the connection should be forcefully closed.
        connection.advanceTime(by: .seconds(1))

        try #require(!connection.channel.isActive)
        #expect(try connection.readFrame() == nil)
        try connection.waitUntilClosed()
    }

    @Test("Grace period starts when the first GOAWAY is sent")
    func graceTimerStartsAtFirstGoAway() throws {
        let connection = try Connection(
            maxIdleTime: .minutes(1),
            maxGraceTime: .seconds(5)
        )
        try connection.activate()

        // The idle timer will trigger the graceful shutdown.
        connection.advanceTime(by: .minutes(1))

        // Open a stream so that the PING ACK doesn't immediately close the connection.
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(
                openStreamBeforeSending: 1,
                delay: .seconds(3),
                expectedSecondGOAWAYStreamID: 1
            )
        )

        // The stream should still be open.
        #expect(connection.channel.isActive)

        // The grace period should be measured from the first GOAWAY. Therefore, the connection should forcefully close
        // after 2 seconds.
        connection.advanceTime(by: .seconds(2))
        try #require(!connection.channel.isActive)
        #expect(try connection.readFrame() == nil)

        try connection.waitUntilClosed()
    }

    @Test("Graceful close half-closes output before full close (no streams)")
    func gracefulCloseHalfClosesBeforeFullCloseWithNoStreams() throws {
        let connection = try Connection(maxIdleTime: .minutes(1))
        let recorder = CloseRecorder()
        try connection.channel.pipeline.syncOperations.addHandler(recorder, position: .first)
        try connection.activate()

        connection.advanceTime(by: .minutes(1))
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(expectedSecondGOAWAYStreamID: 0)
        )

        // The ping-ack is the trigger for closing output. The recording handler stores the promise
        // which will be succeeded in a moment.
        #expect(recorder.modes == [.output])

        // Complete the half-close promise. Doing that triggers the full close.
        recorder.completeOutput()
        #expect(recorder.modes == [.output, .all])

        try connection.waitUntilClosed()
    }

    @Test("Graceful close half-closes output before full close (last stream closes)")
    func gracefulCloseHalfClosesBeforeFullCloseOnLastStreamClose() throws {
        let connection = try Connection(maxIdleTime: .minutes(1))
        let recorder = CloseRecorder()
        try connection.channel.pipeline.syncOperations.addHandler(recorder, position: .first)
        try connection.activate()

        connection.advanceTime(by: .minutes(1))
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(openStreamBeforeSending: 1, expectedSecondGOAWAYStreamID: 1)
        )

        // Stream still open after second GOAWAY: no close yet.
        #expect(recorder.modes.isEmpty)

        // Closing the last stream schedules a graceful close on the event loop.
        connection.streamClosed(1)
        connection.loop.run()

        // The recording handler stores the promise which will be succeeded in a moment.
        #expect(recorder.modes == [.output])

        // Complete the half-close promise. Doing that triggers the full close.
        recorder.completeOutput()
        #expect(recorder.modes == [.output, .all])

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
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(expectedSecondGOAWAYStreamID: 0)
        )

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
        try self.testGracefulShutdown(
            connection: connection,
            pingAckConfiguration: .enable(expectedSecondGOAWAYStreamID: 0)
        )
        // Closed because no streams were open.
        try connection.waitUntilClosed()
    }
}

extension NIOHTTP2ServerConnectionManagementHandlerTests {
    /// Configure how the client responds to the PING that the server sends after the first GOAWAY.
    enum PingAckConfiguration {
        /// Send a PING ACK, then expect the server to send a second GOAWAY.
        ///
        /// - Parameters:
        ///   - openStreamBeforeSending: The ID of a stream to open before sending the PING ACK, if any.
        ///   - delay: The delay after which the PING ACK is sent.
        ///   - expectedSecondGOAWAYStreamID: The expected stream ID value contained in the second GOAWAY.
        case enable(
            openStreamBeforeSending: HTTP2StreamID? = nil,
            delay: TimeAmount? = nil,
            expectedSecondGOAWAYStreamID: HTTP2StreamID
        )

        // Do not respond to the PING received from the server.
        case disable
    }

    private func testGracefulShutdown(
        connection: Connection,
        pingAckConfiguration: PingAckConfiguration
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

            switch pingAckConfiguration {
            case .enable(let streamToOpenBeforePingAck, let delay, let expectedSecondGOAWAYStreamID):
                if let streamToOpenBeforePingAck {
                    connection.streamOpened(streamToOpenBeforePingAck)
                }

                if let delay {
                    connection.advanceTime(by: delay)
                }

                // Send the PING ACK.
                try connection.ping(data: data, ack: true)

                // PING ACK triggers another GOAWAY.
                let frame = try #require(try connection.readFrame())
                #expect(frame.streamID == .rootStream)

                let (streamID, errorCode, _) = try #require(frame.payload.goAway)
                #expect(streamID == expectedSecondGOAWAYStreamID)
                #expect(errorCode == .noError)

            case .disable:
                ()
            }
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

private final class CloseRecorder: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny

    private(set) var modes: [CloseMode] = []
    private var halfClosePromise: EventLoopPromise<Void>?

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.modes.append(mode)
        switch mode {
        case .output:
            self.halfClosePromise = promise
        default:
            context.close(mode: mode, promise: promise)
        }
    }

    func completeOutput() {
        self.halfClosePromise?.succeed(())
        self.halfClosePromise = nil
    }
}
