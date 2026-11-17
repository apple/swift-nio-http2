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

import NIOCore
import NIOEmbedded
import NIOHPACK
import Testing

@testable import NIOHTTP2

struct HTTP2QuiescedConnectionTests {
    private static let requestHeaders = HPACKHeaders([
        (":method", "GET"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
    ])
    private static let responseHeaders = HPACKHeaders([(":status", "200")])

    private let client = EmbeddedChannel()
    private let server = EmbeddedChannel()

    /// Sets up the client and server channels, delivers the client's preface and a complete request to the server, and
    /// reads the frames from the server's pipeline.
    private func connectAndSendRequest() throws {
        try self.client.pipeline.syncOperations.addHandler(NIOHTTP2Handler(mode: .client))
        try self.server.pipeline.syncOperations.addHandler(NIOHTTP2Handler(mode: .server))

        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        try self.client.connect(to: address).wait()
        try self.server.connect(to: address).wait()

        self.client.writeAndFlush(
            HTTP2Frame(streamID: 1, payload: .headers(.init(headers: Self.requestHeaders, endStream: true))),
            promise: nil
        )
        try self.deliver(from: self.client, to: self.server)

        // The server sees the client's SETTINGS frame, followed by the request headers.
        try self.server.expectSettings(nioDefaultSettings)
        try self.server.expectHeaders(Self.requestHeaders, streamID: 1)
        try self.server.expectNoMoreFrames()
    }

    /// Sends a GOAWAY with the last stream ID set to the maximum, then completes the response. This will drop the
    /// stream count to zero, which moves the server's connection state machine to the `fullyQuiesced` state.
    private func quiesceServerAndCompleteResponse() throws {
        self.server.writeAndFlush(
            HTTP2Frame(
                streamID: .rootStream,
                payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)
            ),
            promise: nil
        )
        self.server.writeAndFlush(
            HTTP2Frame(streamID: 1, payload: .headers(.init(headers: Self.responseHeaders, endStream: true))),
            promise: nil
        )
        self.server.embeddedEventLoop.run()
    }

    @Test func inFlightSettingsAckDoesNotFailAQuiescedConnection() throws {
        try self.connectAndSendRequest()

        // Let the client see the server's preface. The client will queue a SETTINGS ACK in response.
        try self.deliver(from: self.server, to: self.client)
        try self.client.expectSettings(nioDefaultSettings)
        try self.client.expectSettingsAck()
        try self.client.expectNoMoreFrames()

        // Now send the GOAWAY and the response from the server.
        try self.quiesceServerAndCompleteResponse()

        // The client queued a SETTINGS ACK when it received the server's preface. This SETTINGS ACK will now arrive at
        // the server who is in the `fullyQuiesced` state.
        try self.deliver(from: self.client, to: self.server)

        // The server should ignore the frame.
        try self.server.expectNoMoreFrames()

        // The client should see the GOAWAY and the response.
        try self.deliver(from: self.server, to: self.client)
        try self.client.expectGoAway()
        try self.client.expectHeaders(Self.responseHeaders, streamID: 1)
        try self.client.expectNoMoreFrames()
    }

    @Test func inFlightStreamWindowUpdateDoesNotFailAQuiescedConnection() throws {
        try self.connectAndSendRequest()

        // Send a WINDOW_UPDATE frame from the client, before it has seen the server's preface.
        self.client.writeAndFlush(
            HTTP2Frame(streamID: 1, payload: .windowUpdate(windowSizeIncrement: 1024)),
            promise: nil
        )

        // Now send the GOAWAY and the response from the server.
        try self.quiesceServerAndCompleteResponse()

        // The WINDOW_UPDATE will now arrive at the server who is in the `fullyQuiesced` state.
        try self.deliver(from: self.client, to: self.server)

        // The server should ignore the frame.
        try self.server.expectNoMoreFrames()

        // The client should now see the server's preface, the GOAWAY, and finally the response.
        try self.deliver(from: self.server, to: self.client)
        try self.client.expectSettings(nioDefaultSettings)
        try self.client.expectSettingsAck()
        try self.client.expectGoAway()
        try self.client.expectHeaders(Self.responseHeaders, streamID: 1)
        try self.client.expectNoMoreFrames()
    }

    @Test func pingAckBehindInFlightFramesReachesTheNextHandler() throws {
        try self.connectAndSendRequest()

        // Let the client see the server's preface. The client will queue a SETTINGS ACK in response.
        try self.deliver(from: self.server, to: self.client)
        try self.client.expectSettings(nioDefaultSettings)
        try self.client.expectSettingsAck()
        try self.client.expectNoMoreFrames()

        // More frames the client sends before it learns that the connection is finished.
        self.client.write(HTTP2Frame(streamID: 1, payload: .windowUpdate(windowSizeIncrement: 1024)), promise: nil)
        self.client.write(
            HTTP2Frame(streamID: .rootStream, payload: .windowUpdate(windowSizeIncrement: 1024)),
            promise: nil
        )
        self.client.write(
            HTTP2Frame(streamID: 1, payload: .priority(.init(exclusive: false, dependency: .rootStream, weight: 16))),
            promise: nil
        )
        self.client.flush()

        // Send a GOAWAY, followed by a PING, from the server.
        let pingData = HTTP2PingData(withInteger: 42)
        self.server.write(
            HTTP2Frame(
                streamID: .rootStream,
                payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)
            ),
            promise: nil
        )
        self.server.write(HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: false)), promise: nil)
        // Now complete the response so that the server moves to the `.fullyQuiesced` state.
        self.server.write(
            HTTP2Frame(streamID: 1, payload: .headers(.init(headers: Self.responseHeaders, endStream: true))),
            promise: nil
        )
        self.server.flush()
        self.server.embeddedEventLoop.run()

        // The client receives the GOAWAY, the PING and the response, and sends a PING_ACK.
        try self.deliver(from: self.server, to: self.client)
        try self.client.expectGoAway()
        try self.client.expectPing(pingData, ack: false)
        try self.client.expectHeaders(Self.responseHeaders, streamID: 1)
        try self.client.expectNoMoreFrames()

        // Now the fully quiesced server reads (in a single call) all the frames the client sent after the request.
        try self.deliverInOneRead(from: self.client, to: self.server)

        // The SETTINGS ACK, WINDOW_UPDATEs and PRIORITY should be ignored. Only the PING ACK should be propagated.
        try self.server.expectPing(pingData, ack: true)
        try self.server.expectNoMoreFrames()

        // The server shouldn't respond to any of these frames.
        #expect(try self.server.readOutbound(as: ByteBuffer.self) == nil)
    }

    @Test func tooManyInFlightFramesFailAQuiescedConnection() throws {
        try self.connectAndSendRequest()

        // Now send the GOAWAY and the response from the server.
        try self.quiesceServerAndCompleteResponse()

        // The fully quiesced server ignores as many in-flight frames as a well-behaved peer could have sent...
        let windowUpdate = HTTP2Frame(streamID: 1, payload: .windowUpdate(windowSizeIncrement: 1))
        for _ in 0..<HTTP2ConnectionStateMachine.maximumIgnoredFramesWhenFullyQuiesced {
            self.client.write(windowUpdate, promise: nil)
        }
        self.client.flush()
        try self.deliver(from: self.client, to: self.server)
        try self.server.expectNoMoreFrames()

        // ... but one more fails the connection.
        self.client.writeAndFlush(windowUpdate, promise: nil)
        #expect(throws: NIOHTTP2Errors.ExcessiveNumberOfGlitches.self) {
            try self.deliver(from: self.client, to: self.server)
        }

        // The client sees the server's preface, the GOAWAY and the response, then a second GOAWAY with the reason.
        try self.deliver(from: self.server, to: self.client)
        try self.client.expectSettings(nioDefaultSettings)
        try self.client.expectSettingsAck()
        try self.client.expectGoAway(lastStreamID: .maxID, errorCode: .noError)
        try self.client.expectHeaders(Self.responseHeaders, streamID: 1)
        try self.client.expectGoAway(lastStreamID: .rootStream, errorCode: .enhanceYourCalm)
        try self.client.expectNoMoreFrames()
    }

    /// Moves every currently flushed byte from `source` to `destination`.
    ///
    /// Throws if `destination`'s pipeline reports an error.
    private func deliver(from source: EmbeddedChannel, to destination: EmbeddedChannel) throws {
        while let buffer = try source.readOutbound(as: ByteBuffer.self) {
            if buffer.readableBytes > 0 {
                try destination.writeInbound(buffer)
            }
        }
    }

    /// Moves every currently flushed byte from `source` to `destination` as a single read.
    ///
    /// Throws if `destination`'s pipeline reports an error.
    private func deliverInOneRead(from source: EmbeddedChannel, to destination: EmbeddedChannel) throws {
        var bytes = source.allocator.buffer(capacity: 0)
        while var buffer = try source.readOutbound(as: ByteBuffer.self) {
            bytes.writeBuffer(&buffer)
        }
        try destination.writeInbound(bytes)
    }
}

extension EmbeddedChannel {
    fileprivate func expectSettings(
        _ expected: HTTP2Settings,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let frame = try #require(try self.readInbound(as: HTTP2Frame.self), sourceLocation: sourceLocation)
        guard case .settings(.settings(let settings)) = frame.payload, frame.streamID == .rootStream else {
            Issue.record("Expected SETTINGS, got \(frame)", sourceLocation: sourceLocation)
            return
        }
        #expect(settings == expected, sourceLocation: sourceLocation)
    }

    fileprivate func expectSettingsAck(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let frame = try #require(try self.readInbound(as: HTTP2Frame.self), sourceLocation: sourceLocation)
        guard case .settings(.ack) = frame.payload, frame.streamID == .rootStream else {
            Issue.record("Expected a SETTINGS ACK, got \(frame)", sourceLocation: sourceLocation)
            return
        }
    }

    /// Expects HEADERS with END_STREAM set.
    fileprivate func expectHeaders(
        _ expected: HPACKHeaders,
        streamID: HTTP2StreamID,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let frame = try #require(try self.readInbound(as: HTTP2Frame.self), sourceLocation: sourceLocation)
        guard case .headers(let headers) = frame.payload, frame.streamID == streamID else {
            Issue.record("Expected HEADERS on stream \(streamID), got \(frame)", sourceLocation: sourceLocation)
            return
        }
        #expect(headers.headers == expected, sourceLocation: sourceLocation)
        #expect(headers.endStream, sourceLocation: sourceLocation)
    }

    fileprivate func expectGoAway(
        lastStreamID expectedLastStreamID: HTTP2StreamID = .maxID,
        errorCode expectedErrorCode: HTTP2ErrorCode = .noError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let frame = try #require(try self.readInbound(as: HTTP2Frame.self), sourceLocation: sourceLocation)
        guard case .goAway(let lastStreamID, let errorCode, let opaqueData) = frame.payload,
            frame.streamID == .rootStream
        else {
            Issue.record("Expected a GOAWAY, got \(frame)", sourceLocation: sourceLocation)
            return
        }
        #expect(lastStreamID == expectedLastStreamID, sourceLocation: sourceLocation)
        #expect(errorCode == expectedErrorCode, sourceLocation: sourceLocation)
        #expect(opaqueData == nil, sourceLocation: sourceLocation)
    }

    fileprivate func expectPing(
        _ expected: HTTP2PingData,
        ack expectedAck: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let frame = try #require(try self.readInbound(as: HTTP2Frame.self), sourceLocation: sourceLocation)
        guard case .ping(let data, let ack) = frame.payload, frame.streamID == .rootStream else {
            Issue.record("Expected a PING, got \(frame)", sourceLocation: sourceLocation)
            return
        }
        #expect(data == expected, sourceLocation: sourceLocation)
        #expect(ack == expectedAck, sourceLocation: sourceLocation)
    }

    fileprivate func expectNoMoreFrames(sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try self.readInbound(as: HTTP2Frame.self) == nil, sourceLocation: sourceLocation)
    }
}
