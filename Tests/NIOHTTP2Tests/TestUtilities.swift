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

struct NoFrameReceived: Error { }

// MARK:- Test helpers we use throughout these tests to encapsulate verbose
// and noisy code.
extension XCTestCase {
    /// Have two `EmbeddedChannel` objects send and receive data from each other until
    /// they make no forward progress.
    func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel, file: StaticString = #file, line: UInt = #line) {
        var operated: Bool

        repeat {
            operated = false

            if case .some(.byteBuffer(let data)) = first.readOutbound() {
                operated = true
                XCTAssertNoThrow(try second.writeInbound(data), file: file, line: line)
            }
            if case .some(.byteBuffer(let data)) = second.readOutbound() {
                operated = true
                XCTAssertNoThrow(try first.writeInbound(data), file: file, line: line)
            }
        } while operated
    }

    /// Given two `EmbeddedChannel` objects, verify that each one performs the handshake: specifically,
    /// that each receives a SETTINGS frame from its peer and a SETTINGS ACK for its own settings frame.
    ///
    /// If the handshake has not occurred, this will definitely call `XCTFail`. It may also throw if the
    /// channel is now in an indeterminate state.
    func assertDoHandshake(client: EmbeddedChannel, server: EmbeddedChannel, file: StaticString = #file, line: UInt = #line) throws {
        // First the channels need to interact.
        self.interactInMemory(client, server, file: file, line: line)

        // Now keep an eye on things. Each channel should first have been sent a SETTINGS frame.
        let clientReceivedSettings = try client.assertReceivedFrame(file: file, line: line)
        let serverReceivedSettings = try server.assertReceivedFrame(file: file, line: line)

        // Each channel should also have a settings ACK.
        let clientReceivedSettingsAck = try client.assertReceivedFrame(file: file, line: line)
        let serverReceivedSettingsAck = try server.assertReceivedFrame(file: file, line: line)

        // Check that these SETTINGS frames are ok. Currently we don't actually set any values in here,
        // but when we do this function can be enhanced to tolerate it.
        clientReceivedSettings.assertSettingsFrame(ack: false, file: file, line: line)
        serverReceivedSettings.assertSettingsFrame(ack: false, file: file, line: line)
        clientReceivedSettingsAck.assertSettingsFrame(ack: true, file: file, line: line)
        serverReceivedSettingsAck.assertSettingsFrame(ack: true, file: file, line: line)
    }

    /// Assert that sending the given `frames` into `sender` causes them all to pop back out again at `receiver`,
    /// and that `sender` has received no frames.
    ///
    /// Optionally returns the frames received.
    @discardableResult
    func assertFramesRoundTrip(frames: [HTTP2Frame], sender: EmbeddedChannel, receiver: EmbeddedChannel, file: StaticString = #file, line: UInt = #line) throws -> [HTTP2Frame] {
        for frame in frames {
            sender.write(frame, promise: nil)
        }
        sender.flush()
        self.interactInMemory(sender, receiver)

        XCTAssertNil(sender.readInbound())

        var receivedFrames = [HTTP2Frame]()

        for frame in frames {
            let receivedFrame = try receiver.assertReceivedFrame()
            receivedFrame.assertFrameMatches(this: frame, file: file, line: line)
            receivedFrames.append(frame)
        }

        return receivedFrames
    }
}

extension EmbeddedChannel {
    /// This function attempts to obtain a HTTP/2 frame from a connection. It must already have been
    /// sent, as this function does not call `interactInMemory`. If no frame has been received, this
    /// will call `XCTFail` and then throw: this will ensure that the test will not proceed past
    /// this point if no frame was received.
    func assertReceivedFrame(file: StaticString = #file, line: UInt = #line) throws -> HTTP2Frame {
        guard let frame: HTTP2Frame = self.readInbound() else {
            XCTFail("Did not receive frame", file: file, line: line)
            throw NoFrameReceived()
        }

        return frame
    }

    /// Returns the `HTTP2ConnectionManager` for a given channel.
    var connectionManager: HTTP2ConnectionManager {
        return try! (self.pipeline.context(handlerType: HTTP2Parser.self).wait().handler as! HTTP2Parser).connectionManager
    }
}

extension HTTP2Frame {
    /// Asserts that the given frame is a SETTINGS frame.
    ///
    /// Currently this does not supoport SETTINGS frames with actual settings in them,
    /// so it asserts the frame is empty. Extend this to support settings later.
    func assertSettingsFrame(ack: Bool, file: StaticString = #file, line: UInt = #line) {
        guard case .settings(let values) = self.payload else {
            XCTFail("Expected SETTINGS frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(self.streamID, .rootStream, "Got unexpected stream ID for SETTINGS: \(self.streamID)",
                       file: file, line: line)
        XCTAssertEqual(self.ack, ack, "Got unexpected value for ack: expected \(ack), got \(self.ack)",
                       file: file, line: line)
        XCTAssertEqual(values.count, 0, "Got settings values \(values), expected none.", file: file, line: line)
    }

    /// Asserts that this frame matches a give other frame.
    func assertFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        switch frame.payload {
        case .headers:
            self.assertHeadersFrameMatches(this: frame, file: file, line: line)
        case .data:
            self.assertDataFrameMatches(this: frame, file: file, line: line)
        default:
            XCTFail("No frame matching method for \(frame.payload)", file: file, line: line)
        }
    }

    /// Asserts that a given frame is a HEADERS frame matching this one.
    func assertHeadersFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .headers(let payload) = frame.payload else {
            preconditionFailure("Headers frames can never match non-headers frames")
        }
        self.assertHeadersFrame(endStream: frame.endStream,
                                endHeaders: frame.endHeaders,
                                streamID: frame.streamID.networkStreamID!,
                                payload: payload,
                                file: file,
                                line: line)
    }

    /// Asserts the given frame is a HEADERS frame.
    func assertHeadersFrame(endStream: Bool, endHeaders: Bool,
                            streamID: Int32, payload: HTTPHeaders,
                            file: StaticString = #file, line: UInt = #line) {
        guard case .headers(let actualPayload) = self.payload else {
            XCTFail("Expected HEADERS frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(self.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(self.endStream)", file: file, line: line)
        XCTAssertEqual(self.endHeaders, endHeaders,
                       "Unexpected endHeaders: expected \(endHeaders), got \(self.endHeaders)", file: file, line: line)
        XCTAssertEqual(self.streamID.networkStreamID!, streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID.networkStreamID!)", file: file, line: line)
        XCTAssertEqual(payload, actualPayload, "Non-equal payloads: expected \(payload), got \(actualPayload)", file: file, line: line)
    }

    /// Asserts that a given frame is a DATA frame matching this one.
    func assertDataFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .data(.byteBuffer(let payload)) = frame.payload else {
            preconditionFailure("Data frames can never match non-data frames")
        }
        self.assertDataFrame(endStream: frame.endStream,
                             streamID: frame.streamID.networkStreamID!,
                             payload: payload,
                             file: file,
                             line: line)
    }

    /// Assert the given frame is a DATA frame with the appropriate settings.
    func assertDataFrame(endStream: Bool, streamID: Int32, payload: ByteBuffer, file: StaticString = #file, line: UInt = #line) {
        guard case .data(.byteBuffer(let actualPayload)) = self.payload else {
            XCTFail("Expected DATA frame with ByteBuffer, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(self.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(self.endStream)", file: file, line: line)
        XCTAssertEqual(self.streamID.networkStreamID!, streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID.networkStreamID!)", file: file, line: line)
        XCTAssertEqual(actualPayload, payload,
                       "Unexpected body: expected \(payload), got \(actualPayload)", file: file, line: line)

    }
}
