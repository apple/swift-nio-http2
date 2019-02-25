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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin.C
#elseif os(Linux) || os(FreeBSD) || os(Android)
import Glibc
#else
#endif

import XCTest
import NIO
import NIOHTTP1
import NIOHTTP2
import NIOHPACK

struct NoFrameReceived: Error { }

// MARK:- Test helpers we use throughout these tests to encapsulate verbose
// and noisy code.
extension XCTestCase {
    /// Have two `EmbeddedChannel` objects send and receive data from each other until
    /// they make no forward progress.
    func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel, file: StaticString = #file, line: UInt = #line) {
        var operated: Bool

        func readBytesFromChannel(_ channel: EmbeddedChannel) -> ByteBuffer? {
            guard let data = channel.readOutbound(as: IOData.self) else {
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
                XCTAssertNoThrow(try second.writeInbound(data), file: file, line: line)
            }
            if let data = readBytesFromChannel(second) {
                operated = true
                XCTAssertNoThrow(try first.writeInbound(data), file: file, line: line)
            }
        } while operated
    }

    /// Deliver all the bytes currently flushed on `sourceChannel` to `targetChannel`.
    func deliverAllBytes(from sourceChannel: EmbeddedChannel, to targetChannel: EmbeddedChannel, file: StaticString = #file, line: UInt = #line) {
        // Collect the serialized data.
        var frameBuffer = sourceChannel.allocator.buffer(capacity: 1024)
        while case .some(.byteBuffer(var buf)) = sourceChannel.readOutbound(as: IOData.self) {
            frameBuffer.writeBuffer(&buf)
        }

        XCTAssertNoThrow(try targetChannel.writeInbound(frameBuffer), file: file, line: line)
    }

    /// Given two `EmbeddedChannel` objects, verify that each one performs the handshake: specifically,
    /// that each receives a SETTINGS frame from its peer and a SETTINGS ACK for its own settings frame.
    ///
    /// If the handshake has not occurred, this will definitely call `XCTFail`. It may also throw if the
    /// channel is now in an indeterminate state.
    func assertDoHandshake(client: EmbeddedChannel, server: EmbeddedChannel,
                           clientSettings: [HTTP2Setting] = nioDefaultSettings, serverSettings: [HTTP2Setting] = nioDefaultSettings,
                           file: StaticString = #file, line: UInt = #line) throws {
        // This connects are not semantically right, but are required in order to activate the
        // channels.
        //! FIXME: Replace with registerAlreadyConfigured0 once EmbeddedChannel propagates this
        //         call to its channelcore.
        let socket = try SocketAddress(unixDomainSocketPath: "/fake")
        _ = try client.connect(to: socket).wait()
        _ = try server.connect(to: socket).wait()

        // First the channels need to interact.
        self.interactInMemory(client, server, file: file, line: line)

        // Now keep an eye on things. Each channel should first have been sent a SETTINGS frame.
        let clientReceivedSettings = try client.assertReceivedFrame(file: file, line: line)
        let serverReceivedSettings = try server.assertReceivedFrame(file: file, line: line)

        // Each channel should also have a settings ACK.
        let clientReceivedSettingsAck = try client.assertReceivedFrame(file: file, line: line)
        let serverReceivedSettingsAck = try server.assertReceivedFrame(file: file, line: line)

        // Check that these SETTINGS frames are ok.
        clientReceivedSettings.assertSettingsFrame(expectedSettings: serverSettings, ack: false, file: file, line: line)
        serverReceivedSettings.assertSettingsFrame(expectedSettings: clientSettings, ack: false, file: file, line: line)
        clientReceivedSettingsAck.assertSettingsFrame(expectedSettings: [], ack: true, file: file, line: line)
        serverReceivedSettingsAck.assertSettingsFrame(expectedSettings: [], ack: true, file: file, line: line)

        client.assertNoFramesReceived(file: file, line: line)
        server.assertNoFramesReceived(file: file, line: line)
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
        self.interactInMemory(sender, receiver, file: file, line: line)
        sender.assertNoFramesReceived(file: file, line: line)

        var receivedFrames = [HTTP2Frame]()

        for frame in frames {
            let receivedFrame = try receiver.assertReceivedFrame(file: file, line: line)
            receivedFrame.assertFrameMatches(this: frame, file: file, line: line)
            receivedFrames.append(receivedFrame)
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

    /// Asserts that the connection has not received a HTTP/2 frame at this time.
    func assertNoFramesReceived(file: StaticString = #file, line: UInt = #line) {
        let content: HTTP2Frame? = self.readInbound()
        XCTAssertNil(content, "Received unexpected content: \(content!)", file: file, line: line)
    }
}

extension HTTP2Frame {
    /// Asserts that the given frame is a SETTINGS frame.
    func assertSettingsFrame(expectedSettings: [HTTP2Setting], ack: Bool, file: StaticString = #file, line: UInt = #line) {
        guard case .settings(let payload) = self.payload else {
            XCTFail("Expected SETTINGS frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(self.streamID, .rootStream, "Got unexpected stream ID for SETTINGS: \(self.streamID)",
                       file: file, line: line)

        switch payload {
        case .ack:
            XCTAssertEqual(expectedSettings, [], "Got unexpected settings: expected \(expectedSettings), got []", file: file, line: line)
            XCTAssertTrue(ack, "Got unexpected value for ack: expected \(ack), got true", file: file, line: line)
        case .settings(let actualSettings):
            XCTAssertEqual(expectedSettings, actualSettings, "Got unexpected settings: expected \(expectedSettings), got \(actualSettings)", file: file, line: line)
            XCTAssertFalse(false, "Got unexpected value for ack: expected \(ack), got false", file: file, line: line)
        }
    }

    func assertSettingsFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .settings(let payload) = frame.payload else {
            preconditionFailure("Settings frames can never match non-settings frames")
        }

        switch payload {
        case .ack:
            self.assertSettingsFrame(expectedSettings: [], ack: true)
        case .settings(let expectedSettings):
            self.assertSettingsFrame(expectedSettings: expectedSettings, ack: false)
        }
    }

    /// Asserts that this frame matches a give other frame.
    func assertFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        switch frame.payload {
        case .headers:
            self.assertHeadersFrameMatches(this: frame, file: file, line: line)
        case .data:
            self.assertDataFrameMatches(this: frame, file: file, line: line)
        case .goAway:
            self.assertGoAwayFrameMatches(this: frame, file: file, line: line)
        case .ping:
            self.assertPingFrameMatches(this: frame, file: file, line: line)
        case .settings:
            self.assertSettingsFrameMatches(this: frame, file: file, line: line)
        case .rstStream:
            self.assertRstStreamFrameMatches(this: frame, file: file, line: line)
        case .priority:
            self.assertPriorityFrameMatches(this: frame, file: file, line: line)
        case .pushPromise:
            self.assertPushPromiseFrameMatches(this: frame, file: file, line: line)
        case .windowUpdate:
            self.assertWindowUpdateFrameMatches(this: frame, file: file, line: line)
        default:
            XCTFail("No frame matching method for \(frame.payload)", file: file, line: line)
        }
    }

    /// Asserts that a given frame is a HEADERS frame matching this one.
    func assertHeadersFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .headers(let payload) = frame.payload else {
            preconditionFailure("Headers frames can never match non-headers frames")
        }
        self.assertHeadersFrame(endStream: payload.endStream,
                                streamID: frame.streamID,
                                headers: payload.headers,
                                priority: payload.priorityData,
                                file: file,
                                line: line)
    }

    /// Asserts the given frame is a HEADERS frame.
    func assertHeadersFrame(endStream: Bool, streamID: HTTP2StreamID, headers: HPACKHeaders,
                            priority: HTTP2Frame.StreamPriorityData? = nil,
                            file: StaticString = #file, line: UInt = #line) {
        guard case .headers(let actualPayload) = self.payload else {
            XCTFail("Expected HEADERS frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(actualPayload.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(actualPayload.endStream)", file: file, line: line)
        XCTAssertEqual(self.streamID, streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID)", file: file, line: line)
        XCTAssertEqual(headers, actualPayload.headers, "Non-equal headers: expected \(headers), got \(actualPayload.headers)", file: file, line: line)
        XCTAssertEqual(priority, actualPayload.priorityData, "Non-equal priorities: expected \(String(describing: priority)), got \(String(describing: actualPayload.priorityData))", file: file, line: line)
    }

    /// Asserts that a given frame is a DATA frame matching this one.
    ///
    /// This function always converts the DATA frame to a bytebuffer, for use with round-trip testing.
    func assertDataFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .data(let payload) = frame.payload else {
            XCTFail("Expected DATA frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        let expectedPayload: ByteBuffer
        switch payload.data {
        case .byteBuffer(let bufferPayload):
            expectedPayload = bufferPayload
        case .fileRegion(let filePayload):
            // Sorry about creating an allocator from thin air here!
            expectedPayload = filePayload.asByteBuffer(allocator: ByteBufferAllocator())
        }

        self.assertDataFrame(endStream: payload.endStream,
                             streamID: frame.streamID,
                             payload: expectedPayload,
                             file: file,
                             line: line)
    }

    /// Assert the given frame is a DATA frame with the appropriate settings.
    func assertDataFrame(endStream: Bool, streamID: HTTP2StreamID, payload: ByteBuffer, file: StaticString = #file, line: UInt = #line) {
        guard case .data(let actualFrameBody) = self.payload else {
            XCTFail("Expected DATA frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        guard case .byteBuffer(let actualPayload) = actualFrameBody.data else {
            XCTFail("Expected ByteBuffer DATA frame, got \(actualFrameBody.data) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(actualFrameBody.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(actualFrameBody.endStream)", file: file, line: line)
        XCTAssertEqual(self.streamID, streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID)", file: file, line: line)
        XCTAssertEqual(actualPayload, payload,
                       "Unexpected body: expected \(payload), got \(actualPayload)", file: file, line: line)

    }

    func assertDataFrame(endStream: Bool, streamID: HTTP2StreamID, payload: FileRegion, file: StaticString = #file, line: UInt = #line) {
        guard case .data(let actualFrameBody) = self.payload else {
            XCTFail("Expected DATA frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        guard case .fileRegion(let actualPayload) = actualFrameBody.data else {
            XCTFail("Expected FileRegion DATA frame, got \(actualFrameBody.data) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(actualFrameBody.endStream, endStream,
                       "Unexpected endStream: expected \(endStream), got \(actualFrameBody.endStream)", file: file, line: line)
        XCTAssertEqual(self.streamID, streamID,
                       "Unexpected streamID: expected \(streamID), got \(self.streamID)", file: file, line: line)
        XCTAssertEqual(actualPayload, payload,
                       "Unexpected body: expected \(payload), got \(actualPayload)", file: file, line: line)

    }

    func assertGoAwayFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .goAway(let lastStreamID, let errorCode, let opaqueData) = frame.payload else {
            preconditionFailure("Goaway frames can never match non-Goaway frames.")
        }
        self.assertGoAwayFrame(lastStreamID: lastStreamID,
                               errorCode: UInt32(http2ErrorCode: errorCode),
                               opaqueData: opaqueData.flatMap { $0.getBytes(at: $0.readerIndex, length: $0.readableBytes) },
                               file: file,
                               line: line)
    }

    func assertGoAwayFrame(lastStreamID: HTTP2StreamID, errorCode: UInt32, opaqueData: [UInt8]?, file: StaticString = #file, line: UInt = #line) {
        guard case .goAway(let actualLastStreamID, let actualErrorCode, let actualOpaqueData) = self.payload else {
            XCTFail("Expected GOAWAY frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        let integerErrorCode = UInt32(http2ErrorCode: actualErrorCode)
        let byteArrayOpaqueData = actualOpaqueData.flatMap { $0.getBytes(at: $0.readerIndex, length: $0.readableBytes) }

        XCTAssertEqual(self.streamID, .rootStream, "Goaway frame must be on the root stream!", file: file, line: line)
        XCTAssertEqual(lastStreamID, actualLastStreamID,
                       "Unexpected last stream ID: expected \(lastStreamID), got \(actualLastStreamID)", file: file, line: line)
        XCTAssertEqual(integerErrorCode, errorCode,
                       "Unexpected error code: expected \(errorCode), got \(integerErrorCode)", file: file, line: line)
        XCTAssertEqual(byteArrayOpaqueData, opaqueData,
                       "Unexpected opaque data: expected \(String(describing: opaqueData)), got \(String(describing: byteArrayOpaqueData))", file: file, line: line)
    }

    func assertPingFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .ping(let opaqueData, let ack) = frame.payload else {
            preconditionFailure("Ping frames can never match non-Ping frames.")
        }
        self.assertPingFrame(ack: ack, opaqueData: opaqueData, file: file, line: line)
    }

    func assertPingFrame(ack: Bool, opaqueData: HTTP2PingData, file: StaticString = #file, line: UInt = #line) {
        guard case .ping(let actualPingData, let actualAck) = self.payload else {
            XCTFail("Expected PING frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(self.streamID, .rootStream, "Ping frame must be on the root stream!", file: file, line: line)
        XCTAssertEqual(actualAck, ack, "Non-matching ACK: expected \(ack), got \(actualAck)", file: file, line: line)
        XCTAssertEqual(actualPingData, opaqueData, "Non-matching ping data: expected \(opaqueData), got \(actualPingData)",
                       file: file, line: line)
    }

    func assertWindowUpdateFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .windowUpdate(let increment) = frame.payload else {
            XCTFail("WINDOW_UPDATE frames can never match non-WINDOW_UPDATE frames", file: file, line: line)
            return
        }
        self.assertWindowUpdateFrame(streamID: frame.streamID, windowIncrement: increment)
    }

    func assertWindowUpdateFrame(streamID: HTTP2StreamID, windowIncrement: Int, file: StaticString = #file, line: UInt = #line) {
        guard case .windowUpdate(let actualWindowIncrement) = self.payload else {
            XCTFail("Expected WINDOW_UPDATE frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(self.streamID, streamID, "Unexpected stream ID!", file: file, line: line)
        XCTAssertEqual(windowIncrement, actualWindowIncrement, "Unexpected window increment!", file: file, line: line)
    }

    func assertRstStreamFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .rstStream(let errorCode) = frame.payload else {
            preconditionFailure("RstStream frames can never match non-RstStream frames.")
        }
        self.assertRstStreamFrame(streamID: frame.streamID, errorCode: errorCode, file: file, line: line)
    }

    func assertRstStreamFrame(streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, file: StaticString = #file, line: UInt = #line) {
        guard case .rstStream(let actualErrorCode) = self.payload else {
            XCTFail("Expected RST_STREAM frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(self.streamID, streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: file, line: line)
        XCTAssertEqual(actualErrorCode, errorCode, "Non-matching error-code: expected \(errorCode), got \(actualErrorCode)", file: file, line: line)
    }

    func assertPriorityFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .priority(let expectedPriorityData) = frame.payload else {
            preconditionFailure("Priority frames can never match non-Priority frames.")
        }
        self.assertPriorityFrame(streamPriorityData: expectedPriorityData, file: file, line: line)
    }

    func assertPriorityFrame(streamPriorityData: HTTP2Frame.StreamPriorityData, file: StaticString = #file, line: UInt = #line) {
        guard case .priority(let actualPriorityData) = self.payload else {
            XCTFail("Expected PRIORITY frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(streamPriorityData, actualPriorityData, file: file, line: line)
    }

    func assertPushPromiseFrameMatches(this frame: HTTP2Frame, file: StaticString = #file, line: UInt = #line) {
        guard case .pushPromise(let payload) = frame.payload else {
            preconditionFailure("PushPromise frames can never match non-PushPromise frames.")
        }
        self.assertPushPromiseFrame(streamID: frame.streamID, pushedStreamID: payload.pushedStreamID, headers: payload.headers, file: file, line: line)
    }

    func assertPushPromiseFrame(streamID: HTTP2StreamID, pushedStreamID: HTTP2StreamID, headers: HPACKHeaders, file: StaticString = #file, line: UInt = #line) {
        guard case .pushPromise(let actualPayload) = self.payload else {
            XCTFail("Expected PUSH_PROMISE frame, got \(self.payload) instead", file: file, line: line)
            return
        }

        XCTAssertEqual(streamID, self.streamID, "Non matching stream IDs: expected \(streamID), got \(self.streamID)!", file: file, line: line)
        XCTAssertEqual(pushedStreamID, actualPayload.pushedStreamID, "Non matching pushed stream IDs: expected \(pushedStreamID), got \(actualPayload.pushedStreamID)", file: file, line: line)
        XCTAssertEqual(headers, actualPayload.headers, "Non matching pushed headers: expected \(headers), got \(actualPayload.headers)", file: file, line: line)
    }
}

extension Array where Element == HTTP2Frame {
    func assertFramesMatch<Candidate: Collection>(_ target: Candidate, file: StaticString = #file, line: UInt = #line) where Candidate.Element == HTTP2Frame {
        guard self.count == target.count else {
            XCTFail("Different numbers of frames: expected \(target.count), got \(self.count)", file: file, line: line)
            return
        }

        for (expected, actual) in zip(target, self) {
            expected.assertFrameMatches(this: actual, file: file, line: line)
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
    let template = "/tmp/niotestXXXXXXX"
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
        fileBuffer.writeWithUnsafeMutableBytes { ptr in
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

extension NIO.NIOFileHandle {
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

func assertNoThrowWithValue<T>(_ body: @autoclosure () throws -> T, defaultValue: T? = nil, message: String? = nil, file: StaticString = #file, line: UInt = #line) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: file, line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

