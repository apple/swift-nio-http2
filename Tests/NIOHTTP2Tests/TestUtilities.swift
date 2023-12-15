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

#if canImport(Darwin)
import Darwin.C
#elseif os(Linux) || os(FreeBSD) || os(Android)
import Glibc
#else
#endif

import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import NIOHTTP2
import NIOHPACK

struct NoFrameReceived: Error { }

// MARK:- Test helpers we use throughout these tests to encapsulate verbose
// and noisy code.
extension XCTestCase {
    /// Have two `EmbeddedChannel` objects send and receive data from each other until
    /// they make no forward progress.
    func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel, file: StaticString = #filePath, line: UInt = #line) {
        var operated: Bool

        func readBytesFromChannel(_ channel: EmbeddedChannel) -> ByteBuffer? {
            guard let data = try? assertNoThrowWithValue(channel.readOutbound(as: IOData.self)) else {
                return nil
            }
            switch data {
            case .byteBuffer(let b):
                return b
            case .fileRegion(let f):
                return f.asByteBuffer(allocator: channel.allocator)
            }
        }

        repeat {
            operated = false

            if let data = readBytesFromChannel(first) {
                operated = true
                XCTAssertNoThrow(try second.writeInbound(data), file: (file), line: line)
            }
            if let data = readBytesFromChannel(second) {
                operated = true
                XCTAssertNoThrow(try first.writeInbound(data), file: (file), line: line)
            }
        } while operated
    }

    /// Have two `NIOAsyncTestingChannel` objects send and receive data from each other until
    /// they make no forward progress.
    ///
    /// ** This function is racy and can lead to deadlocks, prefer the one-way variant which is less error-prone**
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func interactInMemory(_ first: NIOAsyncTestingChannel, _ second: NIOAsyncTestingChannel, file: StaticString = #filePath, line: UInt = #line) async throws {
        var operated: Bool

        func readBytesFromChannel(_ channel: NIOAsyncTestingChannel) async -> ByteBuffer? {
            return try? await assertNoThrowWithValue(await channel.readOutbound(as: ByteBuffer.self))
        }

        repeat {
            operated = false

            if let data = await readBytesFromChannel(first) {
                operated = true
                try await assertNoThrow(try await second.writeInbound(data), file: file, line: line)
            }
            if let data = await readBytesFromChannel(second) {
                operated = true
                try await assertNoThrow(try await first.writeInbound(data), file: file, line: line)
            }
        } while operated
    }

    /// Have a `NIOAsyncTestingChannel` send data to another until it makes no forward progress.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    static func deliverAllBytes(from source: NIOAsyncTestingChannel, to destination: NIOAsyncTestingChannel, file: StaticString = #filePath, line: UInt = #line) async throws {
        var operated: Bool

        func readBytesFromChannel(_ channel: NIOAsyncTestingChannel) async -> ByteBuffer? {
            return try? await assertNoThrowWithValue(await channel.readOutbound(as: ByteBuffer.self))
        }

        repeat {
            operated = false
            if let data = await readBytesFromChannel(source) {
                operated = true
                try await assertNoThrow(try await destination.writeInbound(data), file: file, line: line)
            }
        } while operated
    }

    /// Deliver all the bytes currently flushed on `sourceChannel` to `targetChannel`.
    func deliverAllBytes(from sourceChannel: EmbeddedChannel, to targetChannel: EmbeddedChannel, file: StaticString = #filePath, line: UInt = #line) {
        // Collect the serialized data.
        var frameBuffer = sourceChannel.allocator.buffer(capacity: 1024)
        while case .some(.byteBuffer(var buf)) = try? assertNoThrowWithValue(sourceChannel.readOutbound(as: IOData.self)) {
            frameBuffer.writeBuffer(&buf)
        }

        XCTAssertNoThrow(try targetChannel.writeInbound(frameBuffer), file: (file), line: line)
    }

    /// Given two `EmbeddedChannel` objects, verify that each one performs the handshake: specifically,
    /// that each receives a SETTINGS frame from its peer and a SETTINGS ACK for its own settings frame.
    ///
    /// If the handshake has not occurred, this will definitely call `XCTFail`. It may also throw if the
    /// channel is now in an indeterminate state.
    func assertDoHandshake(client: EmbeddedChannel, server: EmbeddedChannel,
                           clientSettings: [HTTP2Setting] = nioDefaultSettings, serverSettings: [HTTP2Setting] = nioDefaultSettings,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        // This connects are not semantically right, but are required in order to activate the
        // channels.
        //! FIXME: Replace with registerAlreadyConfigured0 once EmbeddedChannel propagates this
        //         call to its channelcore.
        let socket = try SocketAddress(unixDomainSocketPath: "/fake")
        _ = try client.connect(to: socket).wait()
        _ = try server.connect(to: socket).wait()

        // First the channels need to interact.
        self.interactInMemory(client, server, file: (file), line: line)

        // Now keep an eye on things. Each channel should first have been sent a SETTINGS frame.
        let clientReceivedSettings = try client.assertReceivedFrame(file: (file), line: line)
        let serverReceivedSettings = try server.assertReceivedFrame(file: (file), line: line)

        // Each channel should also have a settings ACK.
        let clientReceivedSettingsAck = try client.assertReceivedFrame(file: (file), line: line)
        let serverReceivedSettingsAck = try server.assertReceivedFrame(file: (file), line: line)

        // Check that these SETTINGS frames are ok.
        clientReceivedSettings.assertSettingsFrame(expectedSettings: serverSettings, ack: false, file: (file), line: line)
        serverReceivedSettings.assertSettingsFrame(expectedSettings: clientSettings, ack: false, file: (file), line: line)
        clientReceivedSettingsAck.assertSettingsFrame(expectedSettings: [], ack: true, file: (file), line: line)
        serverReceivedSettingsAck.assertSettingsFrame(expectedSettings: [], ack: true, file: (file), line: line)

        client.assertNoFramesReceived(file: (file), line: line)
        server.assertNoFramesReceived(file: (file), line: line)
    }

    /// Given two `NIOAsyncTestingChannel` objects, verify that each one performs the handshake: specifically,
    /// that each receives a SETTINGS frame from its peer and a SETTINGS ACK for its own settings frame.
    ///
    /// If the handshake has not occurred, this will definitely call `XCTFail`. It may also throw if the
    /// channel is now in an indeterminate state.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func assertDoHandshake(client: NIOAsyncTestingChannel, server: NIOAsyncTestingChannel,
                           clientSettings: [HTTP2Setting] = nioDefaultSettings, serverSettings: [HTTP2Setting] = nioDefaultSettings,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        // This connects are not semantically right, but are required in order to activate the
        // channels.
        //! FIXME: Replace with registerAlreadyConfigured0 once EmbeddedChannel propagates this
        //         call to its channelcore.
        let socket = try SocketAddress(unixDomainSocketPath: "/fake")
        _ = try await client.connect(to: socket).get()
        _ = try await server.connect(to: socket).get()

        // First the channels need to interact.
        try await self.interactInMemory(client, server, file: file, line: line)

        // Now keep an eye on things. Each channel should first have been sent a SETTINGS frame.
        let clientReceivedSettings = try await client.assertReceivedFrame(file: file, line: line)
        let serverReceivedSettings = try await server.assertReceivedFrame(file: file, line: line)

        // Each channel should also have a settings ACK.
        let clientReceivedSettingsAck = try await client.assertReceivedFrame(file: file, line: line)
        let serverReceivedSettingsAck = try await server.assertReceivedFrame(file: file, line: line)

        // Check that these SETTINGS frames are ok.
        clientReceivedSettings.assertSettingsFrame(expectedSettings: serverSettings, ack: false, file: file, line: line)
        serverReceivedSettings.assertSettingsFrame(expectedSettings: clientSettings, ack: false, file: file, line: line)
        clientReceivedSettingsAck.assertSettingsFrame(expectedSettings: [], ack: true, file: file, line: line)
        serverReceivedSettingsAck.assertSettingsFrame(expectedSettings: [], ack: true, file: file, line: line)

        await client.assertNoFramesReceived(file: file, line: line)
        await server.assertNoFramesReceived(file: file, line: line)
    }

    /// Assert that sending the given `frames` into `sender` causes them all to pop back out again at `receiver`,
    /// and that `sender` has received no frames.
    ///
    /// Optionally returns the frames received.
    @discardableResult
    func assertFramesRoundTrip(frames: [HTTP2Frame], sender: EmbeddedChannel, receiver: EmbeddedChannel, file: StaticString = #filePath, line: UInt = #line) throws -> [HTTP2Frame] {
        for frame in frames {
            sender.write(frame, promise: nil)
        }
        sender.flush()
        self.interactInMemory(sender, receiver, file: (file), line: line)
        sender.assertNoFramesReceived(file: (file), line: line)

        var receivedFrames = [HTTP2Frame]()

        for frame in frames {
            let receivedFrame = try receiver.assertReceivedFrame(file: (file), line: line)
            receivedFrame.assertFrameMatches(this: frame, file: (file), line: line)
            receivedFrames.append(receivedFrame)
        }

        return receivedFrames
    }

    /// Asserts that sending new settings from `sender` to `receiver` leads to an appropriate settings ACK. Does not assert that no other frames have been
    /// received.
    func assertSettingsUpdateWithAck(_ newSettings: HTTP2Settings, sender: EmbeddedChannel, receiver: EmbeddedChannel, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(newSettings)))
        sender.writeAndFlush(frame, promise: nil)
        self.interactInMemory(sender, receiver, file: (file), line: line)

        try receiver.assertReceivedFrame(file: (file), line: line).assertFrameMatches(this: frame)
        try sender.assertReceivedFrame(file: (file), line: line).assertFrameMatches(this: HTTP2Frame(streamID: .rootStream, payload: .settings(.ack)))
    }
}

extension EmbeddedChannel {
    /// This function attempts to obtain a HTTP/2 frame from a connection. It must already have been
    /// sent, as this function does not call `interactInMemory`. If no frame has been received, this
    /// will call `XCTFail` and then throw: this will ensure that the test will not proceed past
    /// this point if no frame was received.
    func assertReceivedFrame(file: StaticString = #filePath, line: UInt = #line) throws -> HTTP2Frame {
        guard let frame: HTTP2Frame = try assertNoThrowWithValue(self.readInbound()) else {
            XCTFail("Did not receive frame", file: (file), line: line)
            throw NoFrameReceived()
        }

        return frame
    }

    /// Asserts that the connection has not received a HTTP/2 frame at this time.
    func assertNoFramesReceived(file: StaticString = #filePath, line: UInt = #line) {
        let content: HTTP2Frame? = try? assertNoThrowWithValue(self.readInbound())
        XCTAssertNil(content, "Received unexpected content: \(content!)", file: (file), line: line)
    }

    /// Retrieve all sent frames.
    func sentFrames(file: StaticString = #filePath, line: UInt = #line) throws -> [HTTP2Frame] {
        var receivedFrames: [HTTP2Frame] = Array()

        while let frame = try assertNoThrowWithValue(self.readOutbound(as: HTTP2Frame.self), file: (file), line: line) {
            receivedFrames.append(frame)
        }

        return receivedFrames
    }

    /// Retrieve all sent frames.
    func decodedSentFrames(file: StaticString = #filePath, line: UInt = #line) throws -> [HTTP2Frame] {
        var receivedFrames: [HTTP2Frame] = Array()

        var frameDecoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        while let buffer = try assertNoThrowWithValue(self.readOutbound(as: ByteBuffer.self), file: (file), line: line) {
            frameDecoder.append(bytes: buffer)
            if let (frame, _) = try frameDecoder.nextFrame() {
                receivedFrames.append(frame)
            }
        }

        return receivedFrames
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOAsyncTestingChannel {
    /// This function attempts to obtain a HTTP/2 frame from a connection. It must already have been
    /// sent, as this function does not call `interactInMemory`. If no frame has been received, this
    /// will call `XCTFail` and then throw: this will ensure that the test will not proceed past
    /// this point if no frame was received.
    func assertReceivedFrame(file: StaticString = #filePath, line: UInt = #line) async throws -> HTTP2Frame {
        guard let frame: HTTP2Frame = try await assertNoThrowWithValue(await self.readInbound()) else {
            XCTFail("Did not receive frame", file: file, line: line)
            throw NoFrameReceived()
        }

        return frame
    }

    /// Asserts that the connection has not received a HTTP/2 frame at this time.
    func assertNoFramesReceived(file: StaticString = #filePath, line: UInt = #line) async {
        let content: HTTP2Frame? = try? await assertNoThrowWithValue(await self.readInbound())
        XCTAssertNil(content, "Received unexpected content: \(content!)", file: file, line: line)
    }
}

extension HTTP2Frame {
    /// Asserts that the given frame is a SETTINGS frame.
    func assertSettingsFrame(expectedSettings: [HTTP2Setting], ack: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, .rootStream, "Got unexpected stream ID for SETTINGS: \(self.streamID)",
                       file: (file), line: line)
        self.payload.assertSettingsFramePayload(expectedSettings: expectedSettings, ack: ack, file: (file), line: line)
    }

    func assertSettingsFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, .rootStream, "Got unexpected stream ID for SETTINGS: \(self.streamID)",
                       file: (file), line: line)
        self.payload.assertSettingsFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    /// Asserts that this frame matches a give other frame.
    func assertFrameMatches(this frame: HTTP2Frame, dataFileRegionToByteBuffer: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        switch frame.payload {
        case .headers:
            self.assertHeadersFrameMatches(this: frame, file: (file), line: line)
        case .data:
            self.assertDataFrameMatches(this: frame, fileRegionToByteBuffer: dataFileRegionToByteBuffer, file: (file), line: line)
        case .goAway:
            self.assertGoAwayFrameMatches(this: frame, file: (file), line: line)
        case .ping:
            self.assertPingFrameMatches(this: frame, file: (file), line: line)
        case .settings:
            self.assertSettingsFrameMatches(this: frame, file: (file), line: line)
        case .rstStream:
            self.assertRstStreamFrameMatches(this: frame, file: (file), line: line)
        case .priority:
            self.assertPriorityFrameMatches(this: frame, file: (file), line: line)
        case .pushPromise:
            self.assertPushPromiseFrameMatches(this: frame, file: (file), line: line)
        case .windowUpdate:
            self.assertWindowUpdateFrameMatches(this: frame, file: (file), line: line)
        case .alternativeService:
            self.assertAlternativeServiceFrameMatches(this: frame, file: (file), line: line)
        case .origin:
            self.assertOriginFrameMatches(this: frame, file: (file), line: line)
        }
    }

    /// Asserts that a given frame is a HEADERS frame matching this one.
    func assertHeadersFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, frame.streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID)", file: (file), line: line)
        self.payload.assertHeadersFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    enum HeadersType {
        case request
        case response
        case trailers
        case doNotValidate
    }

    /// Asserts the given frame is a HEADERS frame.
    func assertHeadersFrame(endStream: Bool, streamID: HTTP2StreamID, headers: HPACKHeaders,
                            priority: HTTP2Frame.StreamPriorityData? = nil,
                            type: HeadersType? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID)", file: (file), line: line)
        self.payload.assertHeadersFramePayload(endStream: endStream, headers: headers, priority: priority, type: type, file: file, line: line)
    }

    /// Asserts that a given frame is a DATA frame matching this one.
    ///
    /// This function always converts the DATA frame to a bytebuffer, for use with round-trip testing.
    func assertDataFrameMatches(this frame: HTTP2Frame, fileRegionToByteBuffer: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, frame.streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID)", file: (file), line: line)
        self.payload.assertDataFramePayloadMatches(this: frame.payload, fileRegionToByteBuffer: fileRegionToByteBuffer, file: (file), line: line)
    }

    /// Assert the given frame is a DATA frame with the appropriate settings.
    func assertDataFrame(endStream: Bool, streamID: HTTP2StreamID, payload: ByteBuffer, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID)", file: (file), line: line)
        self.payload.assertDataFramePayload(endStream: endStream, payload: payload, file: file, line: line)
    }

    func assertGoAwayFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, .rootStream, "Goaway frame must be on the root stream!", file: (file), line: line)
        self.payload.assertGoAwayFramePayloadMatches(this: frame.payload)
    }

    func assertGoAwayFrame(lastStreamID: HTTP2StreamID, errorCode: UInt32, opaqueData: [UInt8]?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, .rootStream, "Goaway frame must be on the root stream!", file: (file), line: line)
        self.payload.assertGoAwayFramePayload(lastStreamID: lastStreamID, errorCode: errorCode, opaqueData: opaqueData, file: (file), line: line)
    }

    func assertPingFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, .rootStream, "Ping frame must be on the root stream!", file: (file), line: line)
        self.payload.assertPingFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    func assertPingFrame(ack: Bool, opaqueData: HTTP2PingData, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, .rootStream, "Ping frame must be on the root stream!", file: (file), line: line)
        self.payload.assertPingFramePayload(ack: ack, opaqueData: opaqueData, file: (file), line: line)
    }

    func assertWindowUpdateFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, frame.streamID, "Unexpected stream ID!", file: (file), line: line)
        self.payload.assertWindowUpdateFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    func assertWindowUpdateFrame(streamID: HTTP2StreamID, windowIncrement: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, streamID, "Unexpected stream ID!", file: (file), line: line)
        self.payload.assertWindowUpdateFramePayload(windowIncrement: windowIncrement, file: (file), line: line)
    }

    func assertRstStreamFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, frame.streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: (file), line: line)
        self.payload.assertRstStreamFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    func assertRstStreamFrame(streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: (file), line: line)
        self.payload.assertRstStreamFramePayload(errorCode: errorCode, file: (file), line: line)
    }

    func assertPriorityFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, frame.streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: (file), line: line)
        self.payload.assertPriorityFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    func assertPriorityFrame(streamPriorityData: HTTP2Frame.StreamPriorityData, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: (file), line: line)
        self.payload.assertPriorityFramePayload(streamPriorityData: streamPriorityData, file: (file), line: line)
    }

    func assertPushPromiseFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, frame.streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: (file), line: line)
        self.payload.assertPushPromiseFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    func assertPushPromiseFrame(streamID: HTTP2StreamID, pushedStreamID: HTTP2StreamID, headers: HPACKHeaders, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.streamID, streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: (file), line: line)
        self.payload.assertPushPromiseFramePayload(pushedStreamID: pushedStreamID, headers: headers, file: (file), line: line)
    }

    func assertAlternativeServiceFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(.rootStream, self.streamID, "ALTSVC frame must be on the root stream!, got \(self.streamID)!", file: (file), line: line)
        self.payload.assertAlternativeServiceFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    func assertAlternativeServiceFrame(origin: String?, field: ByteBuffer?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(.rootStream, self.streamID, "ALTSVC frame must be on the root stream!, got \(self.streamID)!", file: (file), line: line)
        self.payload.assertAlternativeServiceFramePayload(origin: origin, field: field, file: (file), line: line)
    }

    func assertOriginFrameMatches(this frame: HTTP2Frame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(.rootStream, self.streamID, "ORIGIN frame must be on the root stream!, got \(self.streamID)!", file: (file), line: line)
        self.payload.assertOriginFramePayloadMatches(this: frame.payload, file: (file), line: line)
    }

    func assertOriginFrame(streamID: HTTP2StreamID, origins: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(.rootStream, self.streamID, "ORIGIN frame must be on the root stream!, got \(self.streamID)!", file: (file), line: line)
        self.payload.assertOriginFramePayload(origins: origins, file: (file), line: line)
    }
}

extension HTTP2Frame.FramePayload {
    func assertFramePayloadMatches(this payload: HTTP2Frame.FramePayload, dataFileRegionToByteBuffer: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        switch self {
        case .headers:
            self.assertHeadersFramePayloadMatches(this: payload, file: (file), line: line)
        case .data:
            self.assertDataFramePayloadMatches(this: payload, fileRegionToByteBuffer: dataFileRegionToByteBuffer, file: (file), line: line)
        case .goAway:
            self.assertGoAwayFramePayloadMatches(this: payload, file: (file), line: line)
        case .ping:
            self.assertPingFramePayloadMatches(this: payload, file: (file), line: line)
        case .settings:
            self.assertSettingsFramePayloadMatches(this: payload, file: (file), line: line)
        case .rstStream:
            self.assertRstStreamFramePayloadMatches(this: payload, file: (file), line: line)
        case .priority:
            self.assertPriorityFramePayloadMatches(this: payload, file: (file), line: line)
        case .pushPromise:
            self.assertPushPromiseFramePayloadMatches(this: payload, file: (file), line: line)
        case .windowUpdate:
            self.assertWindowUpdateFramePayloadMatches(this: payload, file: (file), line: line)
        case .alternativeService:
            self.assertAlternativeServiceFramePayloadMatches(this: payload, file: (file), line: line)
        case .origin:
            self.assertOriginFramePayloadMatches(this: payload, file: (file), line: line)
        }
    }

    /// Asserts that a given frame is a HEADERS frame matching this one.
    func assertHeadersFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .headers(let payload) = self else {
            preconditionFailure("Headers frames can never match non-headers frames")
        }
        self.assertHeadersFramePayload(endStream: payload.endStream,
                                       headers: payload.headers,
                                       priority: payload.priorityData,
                                       file: file,
                                       line: line)
    }

    func assertHeadersFramePayload(endStream: Bool, headers: HPACKHeaders,
                                   priority: HTTP2Frame.StreamPriorityData? = nil,
                                   type: HTTP2Frame.HeadersType? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .headers(let actualPayload) = self else {
            XCTFail("Expected HEADERS payload, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(actualPayload.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(actualPayload.endStream)", file: (file), line: line)
        XCTAssertEqual(headers, actualPayload.headers, "Non-equal headers: expected \(headers), got \(actualPayload.headers)", file: (file), line: line)
        XCTAssertEqual(priority, actualPayload.priorityData, "Non-equal priorities: expected \(String(describing: priority)), got \(String(describing: actualPayload.priorityData))", file: (file), line: line)

        switch type {
        case .some(.request):
            XCTAssertNoThrow(try actualPayload.headers.validateRequestBlock(),
                             "\(actualPayload.headers) not a valid \(type!) headers block", file: (file), line: line)
        case .some(.response):
            XCTAssertNoThrow(try actualPayload.headers.validateResponseBlock(),
                             "\(actualPayload.headers) not a valid \(type!) headers block", file: (file), line: line)
        case .some(.trailers):
            XCTAssertNoThrow(try actualPayload.headers.validateTrailersBlock(),
                             "\(actualPayload.headers) not a valid \(type!) headers block", file: (file), line: line)
        case .some(.doNotValidate):
            () // alright, let's not validate then
        case .none:
            XCTAssertTrue((try? actualPayload.headers.validateRequestBlock()) != nil ||
                            (try? actualPayload.headers.validateResponseBlock()) != nil ||
                            (try? actualPayload.headers.validateTrailersBlock()) != nil,
                          "\(actualPayload.headers) not a valid request/response/trailers header block",
                          file: (file), line: line)
        }
    }

    /// Asserts that a given frame is a DATA frame matching this one.
    ///
    /// This function always converts the DATA frame to a bytebuffer, for use with round-trip testing.
    func assertDataFramePayloadMatches(this payload: HTTP2Frame.FramePayload, fileRegionToByteBuffer: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        guard case .data(let actualPayload) = payload else {
            XCTFail("Expected DATA frame, got \(self) instead", file: (file), line: line)
            return
        }

        switch (actualPayload.data, fileRegionToByteBuffer) {
        case (.byteBuffer(let bufferPayload), _):
            self.assertDataFramePayload(endStream: actualPayload.endStream,
                                        payload: bufferPayload,
                                        file: (file),
                                        line: line)
        case (.fileRegion(let filePayload), true):
            // Sorry about creating an allocator from thin air here!
            let expectedPayload = filePayload.asByteBuffer(allocator: ByteBufferAllocator())
            self.assertDataFramePayload(endStream: actualPayload.endStream,
                                        payload: expectedPayload,
                                        file: (file),
                                        line: line)
        case (.fileRegion(let filePayload), false):
            self.assertDataFramePayload(endStream: actualPayload.endStream,
                                        payload: filePayload,
                                        file: (file),
                                        line: line)
        }
    }

    func assertDataFramePayload(endStream: Bool, payload: ByteBuffer, file: StaticString = #filePath, line: UInt = #line) {
        guard case .data(let actualFrameBody) = self else {
            XCTFail("Expected DATA payload, got \(self) instead", file: (file), line: line)
            return
        }

        guard case .byteBuffer(let actualPayload) = actualFrameBody.data else {
            XCTFail("Expected ByteBuffer DATA payload, got \(actualFrameBody.data) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(actualFrameBody.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(actualFrameBody.endStream)", file: (file), line: line)
        XCTAssertEqual(actualPayload, payload,
                       "Unexpected body: expected \(payload), got \(actualPayload)", file: (file), line: line)
    }

    func assertDataFramePayload(endStream: Bool, payload: FileRegion, file: StaticString = #filePath, line: UInt = #line) {
        guard case .data(let actualFrameBody) = self else {
            XCTFail("Expected DATA frame, got \(self) instead", file: (file), line: line)
            return
        }

        guard case .fileRegion(let actualPayload) = actualFrameBody.data else {
            XCTFail("Expected FileRegion DATA frame, got \(actualFrameBody.data) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(actualFrameBody.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(actualFrameBody.endStream)", file: (file), line: line)
        XCTAssertEqual(actualPayload, payload,
                       "Unexpected body: expected \(payload), got \(actualPayload)", file: (file), line: line)

    }

    func assertGoAwayFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .goAway(let lastStreamID, let errorCode, let opaqueData) = payload else {
            preconditionFailure("Goaway frames can never match non-Goaway frames.")
        }
        self.assertGoAwayFramePayload(lastStreamID: lastStreamID,
                                      errorCode: UInt32(http2ErrorCode: errorCode),
                                      opaqueData: opaqueData.flatMap { $0.getBytes(at: $0.readerIndex, length: $0.readableBytes) },
                                      file: (file),
                                      line: line)
    }

    func assertGoAwayFramePayload(lastStreamID: HTTP2StreamID, errorCode: UInt32, opaqueData: [UInt8]?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .goAway(let actualLastStreamID, let actualErrorCode, let actualOpaqueData) = self else {
            XCTFail("Expected GOAWAY frame, got \(self) instead", file: (file), line: line)
            return
        }

        let integerErrorCode = UInt32(http2ErrorCode: actualErrorCode)
        let byteArrayOpaqueData = actualOpaqueData.flatMap { $0.getBytes(at: $0.readerIndex, length: $0.readableBytes) }

        XCTAssertEqual(lastStreamID, actualLastStreamID,
                       "Unexpected last stream ID: expected \(lastStreamID), got \(actualLastStreamID)", file: (file), line: line)
        XCTAssertEqual(integerErrorCode, errorCode,
                       "Unexpected error code: expected \(errorCode), got \(integerErrorCode)", file: (file), line: line)
        XCTAssertEqual(byteArrayOpaqueData, opaqueData,
                       "Unexpected opaque data: expected \(String(describing: opaqueData)), got \(String(describing: byteArrayOpaqueData))", file: (file), line: line)
    }

    func assertPingFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ping(let opaqueData, let ack) = payload else {
            preconditionFailure("Ping frames can never match non-Ping frames.")
        }
        self.assertPingFramePayload(ack: ack, opaqueData: opaqueData, file: (file), line: line)
    }

    func assertPingFramePayload(ack: Bool, opaqueData: HTTP2PingData, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ping(let actualPingData, let actualAck) = self else {
            XCTFail("Expected PING frame, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(actualAck, ack, "Non-matching ACK: expected \(ack), got \(actualAck)", file: (file), line: line)
        XCTAssertEqual(actualPingData, opaqueData, "Non-matching ping data: expected \(opaqueData), got \(actualPingData)",
                       file: (file), line: line)
    }

    /// Asserts that the given frame is a SETTINGS frame.
    func assertSettingsFramePayload(expectedSettings: [HTTP2Setting], ack: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard case .settings(let payload) = self else {
            XCTFail("Expected SETTINGS frame, got \(self) instead", file: (file), line: line)
            return
        }

        switch payload {
        case .ack:
            XCTAssertEqual(expectedSettings, [], "Got unexpected settings: expected \(expectedSettings), got []", file: (file), line: line)
            XCTAssertTrue(ack, "Got unexpected value for ack: expected \(ack), got true", file: (file), line: line)
        case .settings(let actualSettings):
            XCTAssertEqual(expectedSettings, actualSettings, "Got unexpected settings: expected \(expectedSettings), got \(actualSettings)", file: (file), line: line)
            XCTAssertFalse(false, "Got unexpected value for ack: expected \(ack), got false", file: (file), line: line)
        }
    }

    func assertSettingsFramePayloadMatches(this framePayload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .settings(let payload) = framePayload else {
            preconditionFailure("Settings frames can never match non-settings frames")
        }

        switch payload {
        case .ack:
            self.assertSettingsFramePayload(expectedSettings: [], ack: true, file: (file), line: line)
        case .settings(let expectedSettings):
            self.assertSettingsFramePayload(expectedSettings: expectedSettings, ack: false, file: (file), line: line)
        }
    }

    func assertWindowUpdateFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .windowUpdate(let increment) = payload else {
            XCTFail("WINDOW_UPDATE frames can never match non-WINDOW_UPDATE frames", file: (file), line: line)
            return
        }
        self.assertWindowUpdateFramePayload(windowIncrement: increment)
    }

    func assertWindowUpdateFramePayload(windowIncrement: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard case .windowUpdate(let actualWindowIncrement) = self else {
            XCTFail("Expected WINDOW_UPDATE frame, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(windowIncrement, actualWindowIncrement, "Unexpected window increment!", file: (file), line: line)
    }

    func assertRstStreamFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .rstStream(let errorCode) = payload else {
            preconditionFailure("RstStream frames can never match non-RstStream frames.")
        }
        self.assertRstStreamFramePayload(errorCode: errorCode, file: (file), line: line)
    }

    func assertRstStreamFramePayload(errorCode: HTTP2ErrorCode, file: StaticString = #filePath, line: UInt = #line) {
        guard case .rstStream(let actualErrorCode) = self else {
            XCTFail("Expected RST_STREAM frame, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(actualErrorCode, errorCode, "Non-matching error-code: expected \(errorCode), got \(actualErrorCode)", file: (file), line: line)
    }

    func assertPriorityFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .priority(let expectedPriorityData) = payload else {
            preconditionFailure("Priority frames can never match non-Priority frames.")
        }
        self.assertPriorityFramePayload(streamPriorityData: expectedPriorityData, file: (file), line: line)
    }

    func assertPriorityFramePayload(streamPriorityData: HTTP2Frame.StreamPriorityData, file: StaticString = #filePath, line: UInt = #line) {
        guard case .priority(let actualPriorityData) = self else {
            XCTFail("Expected PRIORITY frame, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(streamPriorityData, actualPriorityData, file: (file), line: line)
    }

    func assertPushPromiseFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .pushPromise(let payload) = payload else {
            preconditionFailure("PushPromise frames can never match non-PushPromise frames.")
        }
        self.assertPushPromiseFramePayload(pushedStreamID: payload.pushedStreamID, headers: payload.headers, file: (file), line: line)
    }

    func assertPushPromiseFramePayload(pushedStreamID: HTTP2StreamID, headers: HPACKHeaders, file: StaticString = #filePath, line: UInt = #line) {
        guard case .pushPromise(let actualPayload) = self else {
            XCTFail("Expected PUSH_PROMISE frame, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(pushedStreamID, actualPayload.pushedStreamID, "Non matching pushed stream IDs: expected \(pushedStreamID), got \(actualPayload.pushedStreamID)", file: (file), line: line)
        XCTAssertEqual(headers, actualPayload.headers, "Non matching pushed headers: expected \(headers), got \(actualPayload.headers)", file: (file), line: line)
    }

    func assertAlternativeServiceFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .alternativeService(let origin, let field) = payload else {
            preconditionFailure("AltSvc frames can never match non-AltSvc frames.")
        }
        self.assertAlternativeServiceFramePayload(origin: origin, field: field, file: (file), line: line)
    }

    func assertAlternativeServiceFramePayload(origin: String?, field: ByteBuffer?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .alternativeService(let actualOrigin, let actualField) = self else {
            XCTFail("Expected ALTSVC frame, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(origin,
                       actualOrigin,
                       "Non matching origins: expected \(String(describing: origin)), got \(String(describing: actualOrigin))",
                       file: (file), line: line)
        XCTAssertEqual(field,
                       actualField,
                       "Non matching field: expected \(String(describing: field)), got \(String(describing: actualField))",
                       file: (file), line: line)
    }

    func assertOriginFramePayloadMatches(this payload: HTTP2Frame.FramePayload, file: StaticString = #filePath, line: UInt = #line) {
        guard case .origin(let origins) = payload else {
            preconditionFailure("ORIGIN frames can never match non-ORIGIN frames.")
        }
        self.assertOriginFramePayload(origins: origins, file: (file), line: line)
    }

    func assertOriginFramePayload(origins: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard case .origin(let actualPayload) = self else {
            XCTFail("Expected ORIGIN frame, got \(self) instead", file: (file), line: line)
            return
        }

        XCTAssertEqual(origins, actualPayload, "Non matching origins: expected \(origins), got \(actualPayload)", file: (file), line: line)
    }
}

extension Array where Element == HTTP2Frame {
    func assertFramesMatch<Candidate: Collection>(_ target: Candidate, dataFileRegionToByteBuffer: Bool = true, file: StaticString = #filePath, line: UInt = #line) where Candidate.Element == HTTP2Frame {
        guard self.count == target.count else {
            XCTFail("Different numbers of frames: expected \(target.count), got \(self.count)", file: (file), line: line)
            return
        }

        for (expected, actual) in zip(target, self) {
            expected.assertFrameMatches(this: actual, dataFileRegionToByteBuffer: dataFileRegionToByteBuffer, file: (file), line: line)
        }
    }
}

extension Array where Element == HTTP2Frame.FramePayload {
    func assertFramePayloadsMatch<Candidate: Collection>(_ target: Candidate, dataFileRegionToByteBuffer: Bool = true, file: StaticString = #filePath, line: UInt = #line) where Candidate.Element == HTTP2Frame.FramePayload {
        guard self.count == target.count else {
            XCTFail("Different numbers of frame payloads: expected \(target.count), got \(self.count)", file: (file), line: line)
            return
        }

        for (expected, actual) in zip(target, self) {
            expected.assertFramePayloadMatches(this: actual, dataFileRegionToByteBuffer: dataFileRegionToByteBuffer, file: (file), line: line)
        }
    }
}

/// Runs the body with a temporary file, optionally containing some file content.
func withTemporaryFile<T>(content: String? = nil, _ body: (NIOFileHandle, String) throws -> T) rethrows -> T {
    let (fd, path) = openTemporaryFile()
    let fileHandle = NIOFileHandle(descriptor: fd)
    defer {
        XCTAssertNoThrow(try fileHandle.close())
        XCTAssertEqual(0, unlink(path))
    }
    if let content = content {
        Array(content.utf8).withUnsafeBufferPointer { ptr in
            var toWrite = ptr.count
            var start = ptr.baseAddress!
            while toWrite > 0 {
                let rc = write(fd, start, toWrite)
                if rc >= 0 {
                    toWrite -= rc
                    start = start + rc
                } else {
                    fatalError("Hit error: \(String(cString: strerror(errno)))")
                }
            }
            XCTAssertEqual(0, lseek(fd, 0, SEEK_SET))
        }
    }
    return try body(fileHandle, path)
}

func openTemporaryFile() -> (CInt, String) {
    let template = "\(FileManager.default.temporaryDirectory.path)/niotestXXXXXXX"
    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    let fd = templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { (ptr: UnsafeMutablePointer<Int8>) in
            return mkstemp(ptr)
        }
    }
    templateBytes.removeLast()
    return (fd, String(decoding: templateBytes, as: UTF8.self))
}

extension FileRegion {
    func asByteBuffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        var fileBuffer = allocator.buffer(capacity: self.readableBytes)
        fileBuffer.writeWithUnsafeMutableBytes(minimumWritableBytes: self.readableBytes) { ptr in
            let rc = try! self.fileHandle.withUnsafeFileDescriptor { fd -> Int in
                lseek(fd, off_t(self.readerIndex), SEEK_SET)
                return read(fd, ptr.baseAddress!, self.readableBytes)
            }
            precondition(rc == self.readableBytes)
            return rc
        }
        precondition(fileBuffer.readableBytes == self.readableBytes)
        return fileBuffer
    }
}

extension NIOCore.NIOFileHandle {
    func appendBuffer(_ buffer: ByteBuffer) {
        var written = 0

        while written < buffer.readableBytes {
            let rc = buffer.withUnsafeReadableBytes { ptr in
                try! self.withUnsafeFileDescriptor { fd -> Int in
                    lseek(fd, 0, SEEK_END)
                    return write(fd, ptr.baseAddress! + written, ptr.count - written)
                }
            }
            precondition(rc > 0)
            written += rc
        }
    }
}

func assertNoThrowWithValue<T>(
    _ body: @autoclosure () throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
func assertNoThrowWithValue<T>(
    _ body: @autoclosure () async throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    do {
        return try await body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
func assertNoThrow<T>(
    _ body: @autoclosure () async throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    do {
        try await _ = body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
        throw error
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func assertNil(
    _ expression: @autoclosure () async throws -> Any?,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
    let result = try await expression()
    XCTAssertNil(result, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func assertEqual<T: Equatable>(
    _ expression1: @autoclosure () async throws -> T?,
    _ expression2: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
    let result1 = try await expression1()
    let result2 = try await expression2()
    XCTAssertEqual(result1, result2, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func assertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expression did not throw error", file: file, line: line)
    } catch {
        verify(error)
    }
}

