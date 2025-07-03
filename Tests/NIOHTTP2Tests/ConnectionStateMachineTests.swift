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
import NIOHPACK
import XCTest

@testable import NIOHTTP2

func assertSucceeds(_ body: @autoclosure () -> StateMachineResult, file: StaticString = #filePath, line: UInt = #line) {
    switch body() {
    case .succeed:
        return
    case let result:
        XCTFail("Result \(result)", file: (file), line: line)
    }
}

@discardableResult
func assertConnectionError(
    type: HTTP2ErrorCode,
    isMisbehavingPeer: Bool = false,
    _ body: @autoclosure () -> StateMachineResult,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Error? {
    switch body() {
    case .connectionError(
        underlyingError: let error,
        type: type,
        isMisbehavingPeer: isMisbehavingPeer
    ):
        return error
    case let result:
        XCTFail(
            "Expected connection error of type \(type) and an isMisbehavingPeer value of \(isMisbehavingPeer), got \(result)",
            file: (file),
            line: line
        )
        return nil
    }
}

@discardableResult
func assertStreamError(
    type: HTTP2ErrorCode,
    _ body: @autoclosure () -> StateMachineResult,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Error? {
    switch body() {
    case .streamError(streamID: _, underlyingError: let error, type: type):
        return error
    case let result:
        XCTFail("Expected stream error type \(type), got \(result)", file: (file), line: line)
        return nil
    }
}

@discardableResult
func assertBadStreamStateTransition(
    type: NIOHTTP2StreamState,
    _ body: @autoclosure () -> StateMachineResultWithEffect,
    file: StaticString = #filePath,
    line: UInt = #line
) -> NIOHTTP2Errors.BadStreamStateTransition? {
    let error: NIOHTTP2Errors.BadStreamStateTransition

    switch body().result {
    case .streamError(_, let underlyingError as NIOHTTP2Errors.BadStreamStateTransition, _):
        error = underlyingError
    case .connectionError(let underlyingError as NIOHTTP2Errors.BadStreamStateTransition, _, _):
        error = underlyingError
    default:
        XCTFail("Unexpected result \(body().result)", file: (file), line: line)
        return nil
    }

    XCTAssertEqual(error.fromState, type, file: (file), line: line)

    return error
}

func assertIgnored(_ body: @autoclosure () -> StateMachineResult, file: StaticString = #filePath, line: UInt = #line) {
    switch body() {
    case .ignoreFrame:
        return
    case let result:
        XCTFail("Expected to ignore frame, got \(result)", file: (file), line: line)
    }
}

func assertSucceeds(
    _ body: @autoclosure () -> (StateMachineResultWithEffect, PostFrameOperation),
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertSucceeds(body().0, file: (file), line: line)
}

func assertConnectionError(
    type: HTTP2ErrorCode,
    isMisBehavingPeer: Bool = false,
    _ body: @autoclosure () -> (StateMachineResultWithEffect, PostFrameOperation),
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertConnectionError(
        type: type,
        isMisbehavingPeer: isMisBehavingPeer,
        body().0,
        file: (file),
        line: line
    )
}

func assertSucceeds(
    _ body: @autoclosure () -> StateMachineResultWithEffect,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertSucceeds(body().result, file: (file), line: line)
}

@discardableResult
func assertConnectionError(
    type: HTTP2ErrorCode,
    isMisbehavingPeer: Bool = false,
    _ body: @autoclosure () -> StateMachineResultWithEffect,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Error? {
    // Errors must always lead to noChange.
    let result = body()
    return assertConnectionError(
        type: type,
        isMisbehavingPeer: isMisbehavingPeer,
        result.result,
        file: (file),
        line: line
    )
}

@discardableResult
func assertStreamError(
    type: HTTP2ErrorCode,
    _ body: @autoclosure () -> StateMachineResultWithEffect,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Error? {
    // Errors must always lead to noChange.
    let result = body()
    return assertStreamError(type: type, result.result, file: (file), line: line)
}

func assertIgnored(
    _ body: @autoclosure () -> StateMachineResultWithEffect,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    // Ignored frames must always lead to noChange.
    let result = body()
    assertIgnored(result.result, file: (file), line: line)
}

func assertGoawaySucceeds(
    _ body: @autoclosure () -> StateMachineResultWithEffect,
    droppingStreams: [HTTP2StreamID]?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let result = body()

    if case .some(.bulkStreamClosure(let closedStreamsEvent)) = result.effect {
        XCTAssertEqual(
            closedStreamsEvent.closedStreams.sorted(),
            droppingStreams?.sorted(),
            "GOAWAY closed unexpected streams: expected \(String(describing: droppingStreams)), got \(closedStreamsEvent.closedStreams)",
            file: (file),
            line: line
        )
    } else {
        XCTAssertNil(
            droppingStreams,
            "GOAWAY did not close streams, but expected \(String(describing: droppingStreams))",
            file: (file),
            line: line
        )
    }

    assertSucceeds(result.result, file: (file), line: line)
}

class ConnectionStateMachineTests: XCTestCase {
    var server: HTTP2ConnectionStateMachine!
    var client: HTTP2ConnectionStateMachine!

    var serverEncoder: HTTP2FrameEncoder!
    var serverDecoder: HTTP2FrameDecoder!

    var clientEncoder: HTTP2FrameEncoder!
    var clientDecoder: HTTP2FrameDecoder!

    let maximumSequentialContinuationFrames: Int = 5

    static let requestHeaders = {
        HPACKHeaders([
            (":method", "GET"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("user-agent", "test"),
        ])
    }()

    static let responseHeaders = {
        HPACKHeaders([(":status", "200"), ("server", "NIO")])
    }()

    static let trailers = {
        HPACKHeaders([("x-trailers", "yes")])
    }()

    override func setUp() {
        self.server = .init(role: .server)
        self.client = .init(role: .client)

        self.serverEncoder = HTTP2FrameEncoder(allocator: ByteBufferAllocator())
        self.serverDecoder = HTTP2FrameDecoder(
            allocator: ByteBufferAllocator(),
            expectClientMagic: true,
            maximumSequentialContinuationFrames: self.maximumSequentialContinuationFrames
        )
        self.clientEncoder = HTTP2FrameEncoder(allocator: ByteBufferAllocator())
        self.clientDecoder = HTTP2FrameDecoder(
            allocator: ByteBufferAllocator(),
            expectClientMagic: false,
            maximumSequentialContinuationFrames: self.maximumSequentialContinuationFrames
        )
    }

    private func exchangePreamble(client: HTTP2Settings = HTTP2Settings(), server: HTTP2Settings = HTTP2Settings()) {
        assertSucceeds(self.client.sendSettings(client))
        assertSucceeds(
            self.server.receiveSettings(
                .settings(client),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        assertSucceeds(self.server.sendSettings(server))
        assertSucceeds(
            self.client.receiveSettings(
                .settings(server),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )
    }

    private func setupServerGoaway(
        streamsToOpen: [HTTP2StreamID],
        lastStreamID: HTTP2StreamID,
        expectedToClose: [HTTP2StreamID]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.exchangePreamble()

        // Client opens streams.
        for streamID in streamsToOpen {
            assertSucceeds(
                self.client.sendHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders,
                    isEndStreamSet: false
                )
            )
            assertSucceeds(
                self.server.receiveHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders,
                    isEndStreamSet: false
                )
            )
        }

        // Server sends a reset.
        assertGoawaySucceeds(
            self.server.sendGoaway(lastStreamID: lastStreamID),
            droppingStreams: expectedToClose,
            file: (file),
            line: line
        )
        assertGoawaySucceeds(
            self.client.receiveGoaway(lastStreamID: lastStreamID),
            droppingStreams: expectedToClose,
            file: (file),
            line: line
        )
    }

    private func setupClientGoaway(
        clientStreamID: HTTP2StreamID,
        streamsToOpen: [HTTP2StreamID],
        lastStreamID: HTTP2StreamID,
        expectedToClose: [HTTP2StreamID]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.exchangePreamble()

        // Client opens its stream, server sends response.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: clientStreamID,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: clientStreamID,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: clientStreamID,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: clientStreamID,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // Server opens streams.
        for streamID in streamsToOpen {
            assertSucceeds(
                self.server.sendPushPromise(
                    originalStreamID: clientStreamID,
                    childStreamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders
                )
            )
            assertSucceeds(
                self.client.receivePushPromise(
                    originalStreamID: clientStreamID,
                    childStreamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders
                )
            )
        }

        // Client sends a reset.
        assertGoawaySucceeds(self.client.sendGoaway(lastStreamID: lastStreamID), droppingStreams: expectedToClose)
        assertGoawaySucceeds(self.server.receiveGoaway(lastStreamID: lastStreamID), droppingStreams: expectedToClose)
    }

    func testSimpleRequestResponseFlow() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        XCTAssertTrue(self.client.fullyQuiesced)
        XCTAssertTrue(self.server.fullyQuiesced)
    }

    func testSimpleRequestResponseErrorFlow() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        // Create the stream but leave the state in idle by not passing in the required headers
        let _ = self.server.receiveHeaders(streamID: streamOne, headers: .init(), isEndStreamSet: false)
        var savedServerState = self.server

        // Change the state to halfOpenRemoteLocalIdle
        let testHeaders: HPACKHeaders = [":method": "test", ":path": "test", ":scheme": "test"]
        let _ = self.server.receiveHeaders(streamID: streamOne, headers: testHeaders, isEndStreamSet: false)
        savedServerState = self.server

        assertBadStreamStateTransition(
            type: .halfOpenRemoteLocalIdle,
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: false)
        )
        self.server = savedServerState

        // Move state to fullyOpen
        let testSendHeaders: HPACKHeaders = [":status": "y"]
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: testSendHeaders, isEndStreamSet: false))
        savedServerState = self.server

        // Move state to halfClosedLocalPeerActive
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
        savedServerState = self.server

        assertBadStreamStateTransition(
            type: .halfClosedLocalPeerActive,
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
        self.server = savedServerState

        let testPushPromiseHeaders: HPACKHeaders = ["test": "value"]
        assertBadStreamStateTransition(
            type: .halfClosedLocalPeerActive,
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: testPushPromiseHeaders
            )
        )
        self.server = savedServerState
        let lastBadStreamStateTransition = assertBadStreamStateTransition(
            type: .halfClosedLocalPeerActive,
            self.server.sendHeaders(streamID: streamOne, headers: testPushPromiseHeaders, isEndStreamSet: false)
        )
        self.server = savedServerState

        // Test that BadStreamStateTransition conforms to CustomStringConvertible
        XCTAssertTrue(
            lastBadStreamStateTransition!.description.starts(
                with: "BadStreamStateTransition(fromState: halfClosedLocalPeerActive"
            )
        )
    }

    func testOpeningConnectionWhileServerPreambleMissing() {
        let streamOne = HTTP2StreamID(1)

        // Here the client sends its SETTINGS frame, and then immediately sends its HEADERS.
        assertSucceeds(self.client.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Server receives
        assertSucceeds(
            self.server.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Server sends its preamble, then ACKs, then sends its response.
        assertSucceeds(self.server.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        // Client receives.
        assertSucceeds(
            self.client.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        // Client ACKs
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )

        // Cleanup
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        XCTAssertTrue(self.client.fullyQuiesced)
        XCTAssertTrue(self.server.fullyQuiesced)
    }

    func testServerSendsItsPreambleFirst() {
        let streamOne = HTTP2StreamID(1)

        // Here the server sends its SETTINGS frame and the client receives it before its even sent its own.
        assertSucceeds(self.server.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.client.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        // Now the client sends back with an ACK and then sends HEADERS
        assertSucceeds(self.client.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Now the server receives, sends its ACK back, as well as its response.
        assertSucceeds(
            self.server.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        // Client receives.
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        // Cleanup
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        XCTAssertTrue(self.client.fullyQuiesced)
        XCTAssertTrue(self.server.fullyQuiesced)
    }

    func testMoreComplexStreamLifecycle() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendData(
                streamID: streamOne,
                contentLength: 300,
                flowControlledBytes: 300,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 300,
                flowControlledBytes: 300,
                isEndStreamSet: false
            )
        )

        // Now both sides send another DATA frame and then trailers. Oooooh, trailers.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.sendData(
                streamID: streamOne,
                contentLength: 300,
                flowControlledBytes: 300,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 300,
                flowControlledBytes: 300,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )

        // Cleanup
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        XCTAssertTrue(self.client.fullyQuiesced)
        XCTAssertTrue(self.server.fullyQuiesced)
    }

    func testServerCannotInitiateStreamsWithHeaders() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertConnectionError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
    }

    func testSimpleServerPush() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamThree = HTTP2StreamID(3)
        let streamFour = HTTP2StreamID(4)
        let streamSix = HTTP2StreamID(6)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Server can push right away
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Server sends its headers
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // Server pushes, suceeeds, and completes the pushed response.
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Server attempts to push with invalid stream ID, fails. Client rejects it too.
        assertConnectionError(
            type: .protocolError,
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        var tempClient = self.client!
        assertConnectionError(
            type: .protocolError,
            tempClient.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Server attempts to push on stream two, fails. Client rejects it too.
        assertStreamError(
            type: .protocolError,
            self.server.sendPushPromise(
                originalStreamID: streamTwo,
                childStreamID: streamSix,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        tempClient = self.client!
        assertStreamError(
            type: .protocolError,
            tempClient.receivePushPromise(
                originalStreamID: streamTwo,
                childStreamID: streamSix,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Server completes all streams.
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )

        // Cleanup
        assertSucceeds(self.client.sendGoaway(lastStreamID: streamTwo))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: streamTwo))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        XCTAssertTrue(self.client.fullyQuiesced)
        XCTAssertTrue(self.server.fullyQuiesced)
    }

    func testSimpleStreamResetFlow() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        assertSucceeds(self.server.sendRstStream(streamID: streamOne, reason: .noError))
        assertSucceeds(self.client.receiveRstStream(streamID: streamOne, reason: .noError))

        // Client attempts to send on this stream fail. Servers ignore the frame.
        assertConnectionError(
            type: .streamClosed,
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: true)
        )
        assertIgnored(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )

        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        XCTAssertTrue(self.client.fullyQuiesced)
        XCTAssertTrue(self.server.fullyQuiesced)
    }

    func testHeadersOnClosedStreamAfterServerGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive, streamSeven],
            lastStreamID: streamThree,
            expectedToClose: [streamFive, streamSeven]
        )

        // Server attempts to send on a closed stream fails, and clients reject that attempt as well.
        // Client attempts to send on a closed stream fails, but the server ignores such frames.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertIgnored(
            temporaryServer.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
    }

    func testDataOnClosedStreamAfterServerGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive, streamSeven],
            lastStreamID: streamThree,
            expectedToClose: [streamFive, streamSeven]
        )

        // Server attempts to send on a closed stream fails, and clients reject that attempt as well.
        // Client attempts to send on a closed stream fails, but the server ignores such frames.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.sendData(
                streamID: streamFive,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.receiveData(
                streamID: streamFive,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.sendData(
                streamID: streamFive,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
        assertIgnored(
            temporaryServer.receiveData(
                streamID: streamFive,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
    }

    func testWindowUpdateOnClosedStreamAfterServerGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive, streamSeven],
            lastStreamID: streamThree,
            expectedToClose: [streamFive, streamSeven]
        )

        // Server attempts to send on a closed stream fails, and clients ignore that attempt.
        // Client attempts to send on a closed stream fails, but the server ignores such frames.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.sendWindowUpdate(streamID: streamFive, windowIncrement: 15)
        )
        assertIgnored(temporaryClient.receiveWindowUpdate(streamID: streamFive, windowIncrement: 15))

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.sendWindowUpdate(streamID: streamFive, windowIncrement: 15)
        )
        assertIgnored(temporaryServer.receiveWindowUpdate(streamID: streamFive, windowIncrement: 15))
    }

    func testRstStreamOnClosedStreamAfterServerGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive, streamSeven],
            lastStreamID: streamThree,
            expectedToClose: [streamFive, streamSeven]
        )

        // Server send on a closed stream, and clients reject that attempt.
        // Client send on a closed stream, but the server ignores such frames.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertSucceeds(temporaryServer.sendRstStream(streamID: streamFive, reason: .noError))
        // We ignore RST_STREAM in the closed state because the RFC does not explicitly forbid that.
        assertIgnored(temporaryClient.receiveRstStream(streamID: streamFive, reason: .noError))

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertSucceeds(temporaryClient.sendRstStream(streamID: streamFive, reason: .noError))
        assertIgnored(temporaryServer.receiveRstStream(streamID: streamFive, reason: .noError))
    }

    func testPushesAfterServerGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)
        let streamTwo = HTTP2StreamID(2)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive, streamSeven],
            lastStreamID: streamThree,
            expectedToClose: [streamFive, streamSeven]
        )

        // Server cannot push on the recently closed stream, client rejects it.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.sendPushPromise(
                originalStreamID: streamFive,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.receivePushPromise(
                originalStreamID: streamFive,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Server can successfully push on still-open stream.
        temporaryServer = self.server!
        temporaryClient = self.client!
        assertSucceeds(
            temporaryServer.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            temporaryClient.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            temporaryServer.sendPushPromise(
                originalStreamID: streamThree,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            temporaryClient.receivePushPromise(
                originalStreamID: streamThree,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
    }

    func testClientMayNotInitiateNewStreamAfterServerGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive],
            lastStreamID: streamThree,
            expectedToClose: [streamFive]
        )

        // Client has received GOAWAY, cannot initiate new stream. Server ignores this, as it may have been in flight.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .protocolError,
            temporaryClient.sendHeaders(
                streamID: streamSeven,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertIgnored(
            temporaryServer.receiveHeaders(
                streamID: streamSeven,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
    }

    func testClientInitiatesNewStreamBeforeReceivingAlreadySentGoaway() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        var temporaryServer = self.server!
        var temporaryClient = self.client!

        assertSucceeds(temporaryServer.sendGoaway(lastStreamID: .maxID))
        assertSucceeds(
            temporaryClient.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(temporaryClient.receiveGoaway(lastStreamID: .maxID))

        // The server should throw a stream error (and as a result, respond with a RST_STREAM frame) when it receives the headers.
        assertStreamError(
            type: .refusedStream,
            temporaryServer.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(temporaryServer.sendRstStream(streamID: streamOne, reason: .refusedStream))
        assertSucceeds(temporaryClient.receiveRstStream(streamID: streamOne, reason: .refusedStream))
    }

    func testClientInitiatesNewStreamBeforeReceivingAlreadySentGoawayWhenServerLocallyQuiesced() {
        // Tests the behaviour of the server when it has open streams, sends a GOAWAY frame (so is
        // in locally quiescing state), and then receives HEADERS for a stream whose ID is less than
        // the last stream ID sent in the GOAWAY frame.
        //
        // The expected behaviour is that the server should refuse the stream (by sending RST_STREAM
        // frame) and emit a stream error.
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)

        self.exchangePreamble()

        // Open stream one.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        // Server begins quiescing. It enters the locally quiesced state.
        assertSucceeds(self.server.sendGoaway(lastStreamID: .maxID))

        // Client opens stream three (important: it hasn't received the GOAWAY frame).
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        // Server receives headers for stream three. It should throw a stream error and as a
        // result, respond with a RST_STREAM frame.
        assertStreamError(
            type: .refusedStream,
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(self.server.sendRstStream(streamID: streamOne, reason: .refusedStream))
        assertSucceeds(self.client.receiveRstStream(streamID: streamOne, reason: .refusedStream))
    }

    func testHeadersOnClosedStreamAfterClientGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamFour = HTTP2StreamID(4)
        let streamSix = HTTP2StreamID(6)

        self.setupClientGoaway(
            clientStreamID: streamOne,
            streamsToOpen: [streamTwo, streamFour, streamSix],
            lastStreamID: streamTwo,
            expectedToClose: [streamFour, streamSix]
        )

        // Server attempts to send on a closed stream fails, but clients ignore that attempt.
        // Client attempts to send on a closed stream fails, and the server rejects such frames.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.sendHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertIgnored(
            temporaryClient.receiveHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.sendHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.receiveHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
    }

    func testDataOnClosedStreamAfterClientGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamFour = HTTP2StreamID(4)
        let streamSix = HTTP2StreamID(6)

        self.setupClientGoaway(
            clientStreamID: streamOne,
            streamsToOpen: [streamTwo, streamFour, streamSix],
            lastStreamID: streamTwo,
            expectedToClose: [streamFour, streamSix]
        )

        // Server attempts to send on a closed stream fails, but clients ignore that attempt.
        // Client attempts to send on a closed stream fails, and the server rejects such frames.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.sendData(
                streamID: streamFour,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
        assertIgnored(
            temporaryClient.receiveData(
                streamID: streamFour,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.sendData(
                streamID: streamFour,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.receiveData(
                streamID: streamFour,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
    }

    func testWindowUpdateOnClosedStreamAfterClientGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamFour = HTTP2StreamID(4)
        let streamSix = HTTP2StreamID(6)

        self.setupClientGoaway(
            clientStreamID: streamOne,
            streamsToOpen: [streamTwo, streamFour, streamSix],
            lastStreamID: streamTwo,
            expectedToClose: [streamFour, streamSix]
        )

        // Server attempts to send on a closed stream fails, but clients ignore that attempt.
        // Client attempts to send on a closed stream fails, but the server ignores that attempt.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryServer.sendWindowUpdate(streamID: streamFour, windowIncrement: 15)
        )
        assertIgnored(temporaryClient.receiveWindowUpdate(streamID: streamFour, windowIncrement: 15))

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertConnectionError(
            type: .streamClosed,
            temporaryClient.sendWindowUpdate(streamID: streamFour, windowIncrement: 15)
        )
        assertIgnored(temporaryServer.receiveWindowUpdate(streamID: streamFour, windowIncrement: 15))
    }

    func testRstStreamOnClosedStreamAfterClientGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamFour = HTTP2StreamID(4)
        let streamSix = HTTP2StreamID(6)

        self.setupClientGoaway(
            clientStreamID: streamOne,
            streamsToOpen: [streamTwo, streamFour, streamSix],
            lastStreamID: streamTwo,
            expectedToClose: [streamFour, streamSix]
        )

        // Server send on a closed stream, and clients reject that attempt.
        // Client send on a closed stream, but the server ignores such frames.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertSucceeds(temporaryServer.sendRstStream(streamID: streamFour, reason: .noError))
        assertIgnored(temporaryClient.receiveRstStream(streamID: streamFour, reason: .noError))

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertSucceeds(temporaryClient.sendRstStream(streamID: streamFour, reason: .noError))
        // We ignore RST_STREAM in the closed state because the RFC does not explicitly forbid that.
        assertIgnored(temporaryServer.receiveRstStream(streamID: streamFour, reason: .noError))
    }

    func testServerMayNotInitiateNewStreamAfterClientGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamFour = HTTP2StreamID(4)
        let streamSix = HTTP2StreamID(6)
        let streamEight = HTTP2StreamID(8)

        self.setupClientGoaway(
            clientStreamID: streamOne,
            streamsToOpen: [streamTwo, streamFour, streamSix],
            lastStreamID: streamTwo,
            expectedToClose: [streamFour, streamSix]
        )

        // Server has received GOAWAY, cannot initiate new stream. Client ignores this, as it may have been in flight.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .protocolError,
            temporaryServer.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamEight,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertIgnored(
            temporaryClient.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamEight,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
    }

    func testSendingFramesBeforePrefaceIsIllegal() {
        let streamOne = HTTP2StreamID(1)

        // We only need one of the state machines here.
        assertConnectionError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertConnectionError(type: .protocolError, self.client.sendPing())
        assertConnectionError(type: .protocolError, self.client.sendPriority())
        assertConnectionError(
            type: .protocolError,
            self.client.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(type: .protocolError, self.client.sendRstStream(streamID: streamOne, reason: .noError))
        assertConnectionError(
            type: .protocolError,
            self.client.sendWindowUpdate(streamID: streamOne, windowIncrement: 15)
        )
        assertConnectionError(type: .protocolError, self.client.sendGoaway(lastStreamID: streamOne))
    }

    func testSendingFramesBeforePrefaceAfterReceivedPrefaceIsIllegal() {
        let streamOne = HTTP2StreamID(1)
        assertSucceeds(
            self.client.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        // We only need one of the state machines here.
        assertConnectionError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertConnectionError(type: .protocolError, self.client.sendPing())
        assertConnectionError(type: .protocolError, self.client.sendPriority())
        assertConnectionError(
            type: .protocolError,
            self.client.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(type: .protocolError, self.client.sendRstStream(streamID: streamOne, reason: .noError))
        assertConnectionError(
            type: .protocolError,
            self.client.sendWindowUpdate(streamID: streamOne, windowIncrement: 15)
        )
        assertConnectionError(type: .protocolError, self.client.sendGoaway(lastStreamID: streamOne))
    }

    func testSendingFramesBeforePrefaceAfterReceivedPrefaceAndGoawayIsIllegal() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        assertSucceeds(
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))

        // We only need one of the state machines here.
        assertConnectionError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.server.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertConnectionError(type: .protocolError, self.server.sendPing())
        assertConnectionError(type: .protocolError, self.server.sendPriority())
        assertConnectionError(
            type: .protocolError,
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(type: .protocolError, self.server.sendRstStream(streamID: streamOne, reason: .noError))
        assertConnectionError(
            type: .protocolError,
            self.server.sendWindowUpdate(streamID: streamOne, windowIncrement: 15)
        )
        assertConnectionError(type: .protocolError, self.server.sendGoaway(lastStreamID: streamOne))
    }

    func testReceivingFramesBeforePrefaceIsIllegal() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        // We only need one of the state machines here.
        assertConnectionError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertConnectionError(type: .protocolError, self.client.receivePing(ackFlagSet: false))
        assertConnectionError(type: .protocolError, self.client.receivePriority())
        assertConnectionError(
            type: .protocolError,
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(type: .protocolError, self.client.receiveRstStream(streamID: streamOne, reason: .noError))
        assertConnectionError(
            type: .protocolError,
            self.client.receiveWindowUpdate(streamID: streamOne, windowIncrement: 15)
        )
        assertConnectionError(type: .protocolError, self.client.receiveGoaway(lastStreamID: streamOne))
    }

    func testReceivingFramesBeforePrefaceAfterSentPrefaceIsIllegal() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // We only need one of the state machines here.
        assertConnectionError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertConnectionError(type: .protocolError, self.client.receivePing(ackFlagSet: false))
        assertConnectionError(type: .protocolError, self.client.receivePriority())
        assertConnectionError(
            type: .protocolError,
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(type: .protocolError, self.client.receiveRstStream(streamID: streamOne, reason: .noError))
        assertConnectionError(
            type: .protocolError,
            self.client.receiveWindowUpdate(streamID: streamOne, windowIncrement: 15)
        )
        assertConnectionError(type: .protocolError, self.client.receiveGoaway(lastStreamID: streamOne))
    }

    func testReceivingFramesBeforePrefaceAfterSentPrefaceAndGoawayIsIllegal() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))

        // We only need one of the state machines here.
        assertConnectionError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertConnectionError(type: .protocolError, self.server.receivePing(ackFlagSet: false))
        assertConnectionError(type: .protocolError, self.server.receivePriority())
        assertConnectionError(
            type: .protocolError,
            self.server.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(type: .protocolError, self.server.receiveRstStream(streamID: streamOne, reason: .noError))
        assertConnectionError(
            type: .protocolError,
            self.server.receiveWindowUpdate(streamID: streamOne, windowIncrement: 15)
        )
        assertConnectionError(type: .protocolError, self.server.receiveGoaway(lastStreamID: streamOne))
    }

    func testRatchetingGoaway() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive, streamSeven],
            lastStreamID: streamSeven,
            expectedToClose: nil
        )

        // Now the server ratchets down slowly.
        for (lastStreamID, dropping) in [
            (streamFive, streamSeven), (streamThree, streamFive), (streamOne, streamThree), (.rootStream, streamOne),
        ] {
            assertGoawaySucceeds(self.server.sendGoaway(lastStreamID: lastStreamID), droppingStreams: [dropping])
            assertGoawaySucceeds(self.client.receiveGoaway(lastStreamID: lastStreamID), droppingStreams: [dropping])
        }
    }

    func testRatchetingGoawayForBothPeers() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(
            streamsToOpen: [streamOne, streamThree, streamFive, streamSeven],
            lastStreamID: streamSeven,
            expectedToClose: nil
        )

        // Now the client quiesces the server.
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))

        // Now the server ratchets down slowly.
        for (lastStreamID, dropping) in [
            (streamFive, streamSeven), (streamThree, streamFive), (streamOne, streamThree), (.rootStream, streamOne),
        ] {
            assertGoawaySucceeds(self.server.sendGoaway(lastStreamID: lastStreamID), droppingStreams: [dropping])
            assertGoawaySucceeds(self.client.receiveGoaway(lastStreamID: lastStreamID), droppingStreams: [dropping])
        }
    }

    func testInvalidGoawayFrames() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamThree = HTTP2StreamID(3)

        self.exchangePreamble()

        // Client opens streams, server opens one back (just to be safe).
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // The following operations aren't valid transitions from active.
        assertConnectionError(type: .protocolError, self.server.sendGoaway(lastStreamID: streamTwo))
        assertConnectionError(type: .protocolError, self.client.receiveGoaway(lastStreamID: streamTwo))

        // Transfer to quiescing.
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        // The following operations are now invalid.
        assertConnectionError(type: .protocolError, self.server.sendGoaway(lastStreamID: streamTwo))
        assertConnectionError(type: .protocolError, self.client.receiveGoaway(lastStreamID: streamTwo))
        assertConnectionError(type: .protocolError, self.server.sendGoaway(lastStreamID: streamThree))
        assertConnectionError(type: .protocolError, self.client.receiveGoaway(lastStreamID: streamThree))
    }

    func testCanSendRequestsWithoutReceivingPreface() {
        let streamOne = HTTP2StreamID(1)

        // Client sends preface.
        assertSucceeds(self.client.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.server.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        // Client opens a stream
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        // We can now do all of the streamy things.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(self.client.sendWindowUpdate(streamID: streamOne, windowIncrement: 1024))
        assertSucceeds(self.server.receiveWindowUpdate(streamID: streamOne, windowIncrement: 1024))
        assertSucceeds(self.client.sendRstStream(streamID: streamOne, reason: .noError))
        assertSucceeds(self.server.receiveRstStream(streamID: streamOne, reason: .noError))

        // We can also do all the connectiony things.
        assertSucceeds(self.client.sendPing())
        assertSucceeds(self.server.receivePing(ackFlagSet: false))
        assertSucceeds(self.client.sendPriority())
        assertSucceeds(self.server.receivePriority())
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))

        // Server can bring the connection up by sending its own preface back.
        assertSucceeds(self.server.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.client.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )

        // Both sides quiesce, which will end the connection.
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        XCTAssertTrue(self.client.fullyQuiesced)
        XCTAssertTrue(self.server.fullyQuiesced)
    }

    func testCanQuiesceAndSendRequestsWithoutReceivingPreface() {
        let streamOne = HTTP2StreamID(1)

        // Client sends preface.
        assertSucceeds(self.client.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.server.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        // Client quiesces, then opens a stream.
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        // We can now do all of the streamy things.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(self.client.sendWindowUpdate(streamID: streamOne, windowIncrement: 1024))
        assertSucceeds(self.server.receiveWindowUpdate(streamID: streamOne, windowIncrement: 1024))
        assertSucceeds(self.client.sendRstStream(streamID: streamOne, reason: .noError))
        assertSucceeds(self.server.receiveRstStream(streamID: streamOne, reason: .noError))

        // We can also do all the connectiony things.
        assertSucceeds(self.client.sendPing())
        assertSucceeds(self.server.receivePing(ackFlagSet: false))
        assertSucceeds(self.client.sendPriority())
        assertSucceeds(self.server.receivePriority())
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
    }

    func testFullyQuiescedConnection() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamThree = HTTP2StreamID(3)
        let streamFour = HTTP2StreamID(4)

        self.exchangePreamble()

        // Client opens a stream, so does the server.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Both sides quiesce this.
        assertSucceeds(self.client.sendGoaway(lastStreamID: streamTwo))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: streamTwo))
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))

        // All the streamy operations work on stream one except push promise.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(self.client.sendWindowUpdate(streamID: streamOne, windowIncrement: 1024))
        assertSucceeds(self.server.sendWindowUpdate(streamID: streamOne, windowIncrement: 1024))
        assertSucceeds(self.server.receiveWindowUpdate(streamID: streamOne, windowIncrement: 1024))
        assertSucceeds(self.client.receiveWindowUpdate(streamID: streamOne, windowIncrement: 1024))

        assertSucceeds(self.client.sendRstStream(streamID: streamTwo, reason: .noError))
        assertSucceeds(self.server.sendRstStream(streamID: streamTwo, reason: .noError))
        assertIgnored(self.server.receiveRstStream(streamID: streamTwo, reason: .noError))
        assertIgnored(self.client.receiveRstStream(streamID: streamTwo, reason: .noError))

        // All the connection operations still work.
        assertSucceeds(self.client.sendPing())
        assertSucceeds(self.server.sendPing())
        assertSucceeds(self.server.receivePing(ackFlagSet: false))
        assertSucceeds(self.client.receivePing(ackFlagSet: false))
        assertSucceeds(self.client.sendPriority())
        assertSucceeds(self.server.sendPriority())
        assertSucceeds(self.server.receivePriority())
        assertSucceeds(self.client.receivePriority())

        // But the server cannot push a new stream.
        var temporaryServer = self.server!
        var temporaryClient = self.client!

        assertConnectionError(
            type: .protocolError,
            temporaryServer.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertIgnored(
            temporaryClient.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // And the client cannot initiate a new stream with headers.
        temporaryServer = self.server!
        temporaryClient = self.client!
        let error = assertConnectionError(
            type: .protocolError,
            temporaryClient.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        XCTAssertEqual(error as? NIOHTTP2Errors.CreatedStreamAfterGoaway, NIOHTTP2Errors.createdStreamAfterGoaway())
        assertIgnored(
            temporaryServer.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        XCTAssertFalse(self.server.fullyQuiesced)
        XCTAssertFalse(self.client.fullyQuiesced)

        // Resetting the remaining active stream closes the connection.
        assertSucceeds(self.server.sendRstStream(streamID: streamOne, reason: .noError))
        assertSucceeds(self.client.receiveRstStream(streamID: streamOne, reason: .noError))

        XCTAssertTrue(self.server.fullyQuiesced)
        XCTAssertTrue(self.client.fullyQuiesced)
    }

    func testHeadersOnOpenStreamLocallyQuiescing() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        // Client sends headers
        assertSucceeds(
            client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        // Server responds with headers
        assertSucceeds(
            server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // Client sends a GOAWAY with lastStreamID = 0
        assertGoawaySucceeds(client.sendGoaway(lastStreamID: 0), droppingStreams: nil)
        assertGoawaySucceeds(server.receiveGoaway(lastStreamID: 0), droppingStreams: nil)

        // Server sends a header frame with end stream = true
        let headerFrame = HPACKHeaders([("content-length", "0")])
        assertSucceeds(server.sendHeaders(streamID: streamOne, headers: headerFrame, isEndStreamSet: true))
        assertSucceeds(client.receiveHeaders(streamID: streamOne, headers: headerFrame, isEndStreamSet: true))
    }

    func testImplicitConnectionCompletion() {
        // Connections can become totally idle by way of the server quiescing the client, and then having no outstanding streams.
        // This test validates that we spot it and consider the connection closed at this stage.
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        // Client opens a stream.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server sends goaway.
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))
        XCTAssertFalse(self.client.fullyQuiesced)
        XCTAssertFalse(self.server.fullyQuiesced)

        // Ok, there are two ways this stream can be closed: via headers, or via rst_stream. Either of these should cause the connection to be closed.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertSucceeds(
            temporaryServer.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            temporaryClient.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        XCTAssertTrue(temporaryServer.fullyQuiesced)
        XCTAssertTrue(temporaryClient.fullyQuiesced)

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertSucceeds(temporaryServer.sendRstStream(streamID: streamOne, reason: .noError))
        assertSucceeds(temporaryClient.receiveRstStream(streamID: streamOne, reason: .noError))
        XCTAssertTrue(temporaryServer.fullyQuiesced)
        XCTAssertTrue(temporaryClient.fullyQuiesced)
    }

    func testClosedStreamsForbidAllActivity() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        // Close the connection by quiescing from server.
        assertSucceeds(self.server.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: .rootStream))

        // Stream specific things don't work.
        assertConnectionError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .refusedStream,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.sendWindowUpdate(streamID: streamOne, windowIncrement: 1024)
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receiveWindowUpdate(streamID: streamOne, windowIncrement: 1024)
        )
        assertConnectionError(type: .protocolError, self.server.receiveRstStream(streamID: streamOne, reason: .noError))
        assertConnectionError(
            type: .protocolError,
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Connectiony things don't work either.
        assertConnectionError(type: .protocolError, self.client.sendPriority())
        assertConnectionError(type: .protocolError, self.server.receivePriority())
        assertConnectionError(type: .protocolError, self.client.sendSettings([]))
        assertConnectionError(
            type: .protocolError,
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        // Duplicate goaway is cool though.
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))

        // Sending RST_STREAM is cool too.
        assertSucceeds(self.client.sendRstStream(streamID: streamOne, reason: .noError))

        // PINGing is cool too.
        assertSucceeds(self.client.sendPing())
        assertSucceeds(self.server.receivePing(ackFlagSet: false))
        assertSucceeds(self.client.receivePing(ackFlagSet: true))
    }

    func testPushesAfterSendingPrefaceAreInvalid() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        // Server sends its preface.
        assertSucceeds(self.server.sendSettings(HTTP2Settings()))
        assertSucceeds(
            self.client.receiveSettings(
                .settings(HTTP2Settings()),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        // Pushing in this state fails.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .protocolError,
            temporaryServer.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            temporaryClient.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
    }

    func testClientsMayNotPush() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        // Client sends its preface.
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        // The client may not push here.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .protocolError,
            temporaryClient.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            temporaryServer.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // What if the client now quiesced?
        temporaryServer = self.server!
        temporaryClient = self.client!
        assertSucceeds(temporaryClient.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(temporaryServer.receiveGoaway(lastStreamID: .rootStream))
        assertConnectionError(
            type: .protocolError,
            temporaryClient.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            temporaryServer.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // What if the client became active?
        assertSucceeds(self.server.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )
        assertSucceeds(
            self.client.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )

        temporaryServer = self.server!
        temporaryClient = self.client!
        assertConnectionError(
            type: .protocolError,
            temporaryClient.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            temporaryServer.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
    }

    func testMaySendSettingsInAllStates() {
        let streamOne = HTTP2StreamID(1)

        // During setup, we can send settings.
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        // If we quiesce during setup we can still send settings.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertSucceeds(temporaryClient.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(temporaryServer.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(temporaryClient.sendSettings([]))
        assertSucceeds(
            temporaryServer.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(temporaryServer.sendSettings([]))
        assertSucceeds(
            temporaryClient.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        // We can also activate.
        assertSucceeds(self.server.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )
        assertSucceeds(
            self.client.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )

        // When active we can send settings.
        temporaryServer = self.server!
        temporaryClient = self.client!
        assertSucceeds(temporaryClient.sendSettings([]))
        assertSucceeds(
            temporaryServer.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(temporaryServer.sendSettings([]))
        assertSucceeds(
            temporaryClient.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        // When quiesced by one peer we can send settings.
        assertSucceeds(self.client.sendGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: .rootStream))
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(self.server.sendSettings([]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        // Bring up a stream just to keep the system from shutting down.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Now quiesce the other way. We can still send settings.
        assertSucceeds(self.server.sendGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.receiveGoaway(lastStreamID: streamOne))
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(self.server.sendSettings([]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
    }

    func testValidatingFlowControlOnFullyActiveConnections() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // The default value of the flow control window is 65535. So let's see if we can hit it. First, let's send 65535 bytes from client to server.
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 65535,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 65535,
                isEndStreamSet: false
            )
        )

        // Now the server opens the *stream window only*.
        assertSucceeds(self.server.sendWindowUpdate(streamID: streamOne, windowIncrement: 1000))
        assertSucceeds(self.client.receiveWindowUpdate(streamID: streamOne, windowIncrement: 1000))

        // The client cannot send more than one byte on this stream.
        var temporaryServer = self.server!
        var temporaryClient = self.client!
        assertConnectionError(
            type: .flowControlError,
            temporaryClient.sendData(
                streamID: streamOne,
                contentLength: 1,
                flowControlledBytes: 1,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .flowControlError,
            temporaryServer.receiveData(
                streamID: streamOne,
                contentLength: 1,
                flowControlledBytes: 1,
                isEndStreamSet: false
            )
        )

        // Now the server opens the connection flow control window.
        assertSucceeds(self.server.sendWindowUpdate(streamID: .rootStream, windowIncrement: 65535))
        assertSucceeds(self.client.receiveWindowUpdate(streamID: .rootStream, windowIncrement: 65535))

        // The client may now send 1000 bytes.
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 1000,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 1000,
                isEndStreamSet: false
            )
        )

        // But any attempt to send more fails, again.
        temporaryServer = self.server!
        temporaryClient = self.client!
        assertStreamError(
            type: .flowControlError,
            temporaryClient.sendData(
                streamID: streamOne,
                contentLength: 1,
                flowControlledBytes: 1,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .flowControlError,
            temporaryServer.receiveData(
                streamID: streamOne,
                contentLength: 1,
                flowControlledBytes: 1,
                isEndStreamSet: false
            )
        )

        // The server can increase the flow control window by sending a SETTINGS frame with the appropriate new setting.
        // This adds 1000 to the window size.
        assertSucceeds(self.server.sendSettings([HTTP2Setting(parameter: .initialWindowSize, value: 66535)]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([HTTP2Setting(parameter: .initialWindowSize, value: 66535)]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        // In this state, the client may send new data, but if the server doesn't receive the ACK first it holds the client to the new value.
        temporaryServer = self.server!
        temporaryClient = self.client!
        assertSucceeds(
            temporaryClient.sendData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 1000,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .flowControlError,
            temporaryServer.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 1000,
                isEndStreamSet: false
            )
        )

        // Once the server receives the ACK, it's fine.
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 1000,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 1000,
                isEndStreamSet: false
            )
        )

        // Open the flow control window of the stream.
        assertSucceeds(self.server.sendWindowUpdate(streamID: streamOne, windowIncrement: 65535))
        assertSucceeds(self.client.receiveWindowUpdate(streamID: streamOne, windowIncrement: 65535))

        // At this stage the stream has a window size of 65535, but the connection should not have gained the extra 2000 bytes from the change in
        // SETTINGS_INITIAL_WINDOW_SIZE, so it should have a size of 63535. Verify this by exceeding it.
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 63535,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 63535,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .flowControlError,
            self.client.sendData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: false)
        )
        assertConnectionError(
            type: .flowControlError,
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 1,
                flowControlledBytes: 1,
                isEndStreamSet: false
            )
        )
    }

    func testTrailersWithoutData() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
    }

    func testServerResponseEndsBeforeRequestFinishes() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: true
            )
        )

        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: true
            )
        )
    }

    func testPushedResponsesMayHaveBodies() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendData(
                streamID: streamTwo,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamTwo,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: true
            )
        )
    }

    func testDataFramesWithoutEndStream() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        // We can send some DATA frames while only the client has opened.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: false
            )
        )

        // We can send some more while the server has opened.
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: false
            )
        )

        // And we can send some after the server is done.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: false
            )
        )
    }

    func testSendingCompleteRequestBeforeResponse() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        // We can send a complete request before the remote peer sends us anything.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 1024,
                flowControlledBytes: 1024,
                isEndStreamSet: true
            )
        )

        // The remote peer can then respond.
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
    }

    func testWindowUpdateValidity() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        // WindowUpdate frames are valid in a wide range of states. This test validates them in all of them, including proving that errors are correctly reported.
        func assertCanWindowUpdate(
            client: HTTP2ConnectionStateMachine,
            server: HTTP2ConnectionStateMachine,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            var client = client
            var server = server

            assertSucceeds(client.sendWindowUpdate(streamID: streamOne, windowIncrement: 10), file: (file), line: line)
            assertSucceeds(
                server.receiveWindowUpdate(streamID: streamOne, windowIncrement: 10),
                file: (file),
                line: line
            )
            assertStreamError(
                type: .flowControlError,
                client.sendWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max)),
                file: (file),
                line: line
            )
            assertStreamError(
                type: .flowControlError,
                server.receiveWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max)),
                file: (file),
                line: line
            )

            assertSucceeds(server.sendWindowUpdate(streamID: streamOne, windowIncrement: 10), file: (file), line: line)
            assertSucceeds(
                client.receiveWindowUpdate(streamID: streamOne, windowIncrement: 10),
                file: (file),
                line: line
            )
            assertStreamError(
                type: .flowControlError,
                server.sendWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max)),
                file: (file),
                line: line
            )
            assertStreamError(
                type: .flowControlError,
                client.receiveWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max)),
                file: (file),
                line: line
            )
        }

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertCanWindowUpdate(client: self.client, server: self.server)

        var tempClient = self.client!
        var tempServer = self.server!

        // If we close the client side of the stream, it's ok for the client to send. The server may not send, but the client will tolerate it.
        assertSucceeds(
            tempClient.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: true)
        )
        assertSucceeds(
            tempServer.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )

        assertSucceeds(tempClient.sendWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertSucceeds(tempServer.receiveWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertStreamError(
            type: .flowControlError,
            tempClient.sendWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max))
        )
        assertStreamError(
            type: .flowControlError,
            tempServer.receiveWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max))
        )
        assertStreamError(type: .protocolError, tempServer.sendWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertSucceeds(tempClient.receiveWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertStreamError(
            type: .protocolError,
            tempServer.sendWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max))
        )
        // Weird, but we don't have the data to enforce this.
        assertSucceeds(tempClient.receiveWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max)))

        // If the server is active, it's fine.
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertCanWindowUpdate(client: self.client, server: self.server)

        // If we close now it's ok for the client to send. The server may not send, but the client will tolerate it.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: true)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )
        tempClient = self.client!
        tempServer = self.server!
        assertSucceeds(tempClient.sendWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertSucceeds(tempServer.receiveWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertStreamError(
            type: .flowControlError,
            tempClient.sendWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max))
        )
        assertStreamError(
            type: .flowControlError,
            tempServer.receiveWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max))
        )
        assertStreamError(type: .protocolError, server.sendWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertSucceeds(client.receiveWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertStreamError(
            type: .protocolError,
            server.sendWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max))
        )
        // Weird, but we don't have the data to enforce this.
        assertSucceeds(client.receiveWindowUpdate(streamID: streamOne, windowIncrement: UInt32(Int32.max)))

        // What if the server pushes? This one is actually a bit tricky: the client is allowed to, but the server is not.
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        tempClient = self.client!
        tempServer = self.server!
        assertSucceeds(tempClient.sendWindowUpdate(streamID: streamTwo, windowIncrement: 15))
        assertSucceeds(tempServer.receiveWindowUpdate(streamID: streamTwo, windowIncrement: 15))
        assertStreamError(
            type: .flowControlError,
            tempClient.sendWindowUpdate(streamID: streamTwo, windowIncrement: UInt32(Int32.max))
        )
        assertStreamError(
            type: .flowControlError,
            tempServer.receiveWindowUpdate(streamID: streamTwo, windowIncrement: UInt32(Int32.max))
        )
        assertStreamError(type: .protocolError, tempServer.sendWindowUpdate(streamID: streamTwo, windowIncrement: 15))
        assertStreamError(
            type: .protocolError,
            tempClient.receiveWindowUpdate(streamID: streamTwo, windowIncrement: 15)
        )
    }

    func testWindowUpdateOnClosedStream() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        // Client sends a request.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        // Server sends a response.
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // Client sends end stream, server receives end stream.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
        assertSucceeds(
            self.server.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )

        // Client is now half closed (local), server is half closed (remote)

        // Server sends end stream and is now closed.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )

        // Client is half closed and sends window update, the server MUST ignore this.
        assertSucceeds(self.client.sendWindowUpdate(streamID: streamOne, windowIncrement: 10))
        assertIgnored(self.server.receiveWindowUpdate(streamID: streamOne, windowIncrement: 10))

        // Client receives end stream and closes.
        assertSucceeds(
            self.client.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
    }

    func testWindowIncrementsOfSizeZeroArentOk() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        var tempClient = self.client!
        var tempServer = self.server!
        assertStreamError(type: .protocolError, tempClient.sendWindowUpdate(streamID: streamOne, windowIncrement: 0))
        assertStreamError(type: .protocolError, tempServer.receiveWindowUpdate(streamID: streamOne, windowIncrement: 0))

        tempClient = self.client!
        tempServer = self.server!
        assertConnectionError(
            type: .protocolError,
            tempClient.sendWindowUpdate(streamID: .rootStream, windowIncrement: 0)
        )
        assertConnectionError(
            type: .protocolError,
            tempServer.receiveWindowUpdate(streamID: .rootStream, windowIncrement: 0)
        )
    }

    func testCannotSendDataFrames() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        // There are many states where we cannot send DATA frames.
        var tempClient = self.client!
        var tempServer = self.server!

        // We can't do it before we've opened a stream.
        assertConnectionError(
            type: .protocolError,
            tempClient.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertConnectionError(
            type: .protocolError,
            tempServer.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // We can't send it after we have sent end stream, or before we've sent our headers.
        tempClient = self.client!
        tempServer = self.server!
        assertStreamError(
            type: .streamClosed,
            tempClient.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertStreamError(
            type: .streamClosed,
            tempServer.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .streamClosed,
            tempServer.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertStreamError(
            type: .streamClosed,
            tempClient.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // The client still can't do it, regardless of what the server just did.
        tempClient = self.client!
        tempServer = self.server!
        assertStreamError(
            type: .streamClosed,
            tempClient.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertStreamError(
            type: .streamClosed,
            tempServer.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // The client can't send on pushed streams either.
        tempClient = self.client!
        tempServer = self.server!
        assertStreamError(
            type: .streamClosed,
            tempClient.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertStreamError(
            type: .streamClosed,
            tempServer.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendData(streamID: streamTwo, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamTwo,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: true
            )
        )

        // Neither peer can send on closed streams.
        tempClient = self.client!
        tempServer = self.server!
        assertConnectionError(
            type: .streamClosed,
            tempClient.sendData(streamID: streamTwo, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertConnectionError(
            type: .streamClosed,
            tempServer.receiveData(
                streamID: streamTwo,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .streamClosed,
            tempServer.sendData(streamID: streamTwo, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertConnectionError(
            type: .streamClosed,
            tempClient.receiveData(
                streamID: streamTwo,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
    }

    func testChangingInitialWindowSizeLotsOfStreams() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamThree = HTTP2StreamID(3)
        let streamFour = HTTP2StreamID(4)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.exchangePreamble()

        // We're going to set up several streams in different states, and then mess with the flow control window in all of them at the same time.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamSeven,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamSeven,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamSeven,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamSeven,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamFive,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamFive,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamFive,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamFive,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFour,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // We're going to update the initial window size, adding 1000 to it. This should update for every stream. We do this both ways.
        assertSucceeds(self.client.sendSettings([HTTP2Setting(parameter: .initialWindowSize, value: 66535)]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([HTTP2Setting(parameter: .initialWindowSize, value: 66535)]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )

        assertSucceeds(self.server.sendSettings([HTTP2Setting(parameter: .initialWindowSize, value: 66535)]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([HTTP2Setting(parameter: .initialWindowSize, value: 66535)]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )

        // We're also adding 10000 to the connection window to get it out of the way.
        assertSucceeds(self.client.sendWindowUpdate(streamID: .rootStream, windowIncrement: 10000))
        assertSucceeds(self.server.receiveWindowUpdate(streamID: .rootStream, windowIncrement: 10000))
        assertSucceeds(self.server.sendWindowUpdate(streamID: .rootStream, windowIncrement: 10000))
        assertSucceeds(self.client.receiveWindowUpdate(streamID: .rootStream, windowIncrement: 10000))

        // For streams one, three, and two the server is going to send headers. The goal is to have all streams be active for the server to send a data frame.
        for streamID in [streamOne, streamThree, streamTwo] {
            assertSucceeds(
                self.server.sendHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.responseHeaders,
                    isEndStreamSet: false
                )
            )
            assertSucceeds(
                self.client.receiveHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.responseHeaders,
                    isEndStreamSet: false
                )
            )
        }

        // Now the server is going to send data frames for 66535 bytes, consuming the stream window. It'll then prove it by sending one more byte and failing.
        for streamID in [streamOne, streamTwo, streamThree, streamFour, streamFive, streamSeven] {
            var tempClient = self.client!
            var tempServer = self.server!
            assertSucceeds(
                tempServer.sendData(
                    streamID: streamID,
                    contentLength: 15,
                    flowControlledBytes: 66535,
                    isEndStreamSet: false
                )
            )
            assertSucceeds(
                tempClient.receiveData(
                    streamID: streamID,
                    contentLength: 15,
                    flowControlledBytes: 66535,
                    isEndStreamSet: false
                )
            )
            assertStreamError(
                type: .flowControlError,
                tempServer.sendData(streamID: streamID, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: false)
            )
            assertStreamError(
                type: .flowControlError,
                tempClient.receiveData(
                    streamID: streamID,
                    contentLength: 1,
                    flowControlledBytes: 1,
                    isEndStreamSet: false
                )
            )
        }

        // The client can only send on streams three and five, but it will.
        for streamID in [streamThree, streamFive] {
            var tempClient = self.client!
            var tempServer = self.server!
            assertSucceeds(
                tempClient.sendData(
                    streamID: streamID,
                    contentLength: 15,
                    flowControlledBytes: 66535,
                    isEndStreamSet: false
                )
            )
            assertSucceeds(
                tempServer.receiveData(
                    streamID: streamID,
                    contentLength: 15,
                    flowControlledBytes: 66535,
                    isEndStreamSet: false
                )
            )
            assertStreamError(
                type: .flowControlError,
                tempClient.sendData(streamID: streamID, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: false)
            )
            assertStreamError(
                type: .flowControlError,
                tempServer.receiveData(
                    streamID: streamID,
                    contentLength: 1,
                    flowControlledBytes: 1,
                    isEndStreamSet: false
                )
            )
        }
    }

    func testTooManyHeadersArentOk() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Client cannot send more headers on stream one
        var tempClient = self.client!
        var tempServer = self.server!
        assertStreamError(
            type: .protocolError,
            tempClient.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            tempServer.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )

        // Client could never send headers on stream two
        tempClient = self.client!
        tempServer = self.server!
        assertStreamError(
            type: .protocolError,
            tempClient.sendHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            tempServer.receiveHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )
    }

    func testInvalidChangesToConnectionFlowControlWindow() {
        self.exchangePreamble()

        // The client cannot send window updates that take us past Int32.max. The default size is 65535. Let's try to take us one past this.
        let update = UInt32(Int32.max) - 65535 + 1
        assertConnectionError(
            type: .flowControlError,
            self.client.sendWindowUpdate(streamID: .rootStream, windowIncrement: update)
        )
        assertConnectionError(
            type: .flowControlError,
            self.server.receiveWindowUpdate(streamID: .rootStream, windowIncrement: update)
        )

        // It's also forbidden to send window updates of size 0.
        assertConnectionError(
            type: .protocolError,
            self.client.sendWindowUpdate(streamID: .rootStream, windowIncrement: 0)
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receiveWindowUpdate(streamID: .rootStream, windowIncrement: 0)
        )
    }

    func testSettingsACKWithoutOutstandingSettingsIsAnError() {
        self.exchangePreamble()

        // We don't keep track of un-acked settings on the receive side and don't provide a "sendSettingsAck" function.
        assertConnectionError(
            type: .protocolError,
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )
    }

    func testClientsMustCreateStreamsWithOddStreamIDs() {
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        assertConnectionError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
    }

    func testClientsServersMayNotCreateStreamsBackwards() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)
        let streamThree = HTTP2StreamID(3)
        let streamFour = HTTP2StreamID(4)

        self.exchangePreamble()

        // Client opens stream 3, server opens stream four.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamThree,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamThree,
                childStreamID: streamFour,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Client may not open stream one now!
        var tempClient = self.client!
        var tempServer = self.server!
        assertConnectionError(
            type: .protocolError,
            tempClient.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .protocolError,
            tempServer.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Server may not open stream two now.
        tempClient = self.client!
        tempServer = self.server!
        assertConnectionError(
            type: .protocolError,
            tempServer.sendPushPromise(
                originalStreamID: streamThree,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            tempClient.receivePushPromise(
                originalStreamID: streamThree,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
    }

    func testUnknownSettingsAreIgnored() {
        self.exchangePreamble()

        assertSucceeds(self.client.sendSettings([HTTP2Setting(parameter: .init(extensionSetting: 88), value: 65536)]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([HTTP2Setting(parameter: .init(extensionSetting: 88), value: 65536)]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
    }

    func testMaxConcurrentStreamsEnforcement() {
        // Client is going to set SETTINGS_MAX_CONCURRENT_STREAMS to 5, server will set it to 50.
        assertSucceeds(self.client.sendSettings([HTTP2Setting(parameter: .maxConcurrentStreams, value: 5)]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([HTTP2Setting(parameter: .maxConcurrentStreams, value: 5)]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        assertSucceeds(self.server.sendSettings([HTTP2Setting(parameter: .maxConcurrentStreams, value: 50)]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([HTTP2Setting(parameter: .maxConcurrentStreams, value: 50)]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )

        // Firstly, the client will create 50 streams. This should work just fine.
        let clientStreamIDs = stride(from: 1, to: 100, by: 2).map { HTTP2StreamID($0) }
        let serverStreamIDs = stride(from: 2, to: 11, by: 2).map { HTTP2StreamID($0) }

        for streamID in clientStreamIDs {
            assertSucceeds(
                self.client.sendHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders,
                    isEndStreamSet: true
                )
            )
            assertSucceeds(
                self.server.receiveHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders,
                    isEndStreamSet: true
                )
            )
            assertSucceeds(
                self.server.sendHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.responseHeaders,
                    isEndStreamSet: false
                )
            )
            assertSucceeds(
                self.client.receiveHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.responseHeaders,
                    isEndStreamSet: false
                )
            )
        }

        // The server will now create its 5.
        for streamID in serverStreamIDs {
            assertSucceeds(
                self.server.sendPushPromise(
                    originalStreamID: clientStreamIDs.first!,
                    childStreamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders
                )
            )
            assertSucceeds(
                self.client.receivePushPromise(
                    originalStreamID: clientStreamIDs.first!,
                    childStreamID: streamID,
                    headers: ConnectionStateMachineTests.requestHeaders
                )
            )
        }

        // Neither the client nor the server can create new streams
        let stream101 = HTTP2StreamID(101)
        let stream12 = HTTP2StreamID(12)

        var tempClient = self.client!
        var tempServer = self.server!
        assertConnectionError(
            type: .protocolError,
            tempClient.sendHeaders(
                streamID: stream101,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .protocolError,
            tempServer.receiveHeaders(
                streamID: stream101,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        tempClient = self.client!
        tempServer = self.server!
        assertConnectionError(
            type: .protocolError,
            tempServer.sendPushPromise(
                originalStreamID: clientStreamIDs.first!,
                childStreamID: stream12,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            tempClient.receivePushPromise(
                originalStreamID: clientStreamIDs.first!,
                childStreamID: stream12,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // We can drop the value of SETTINGS_MAX_CONCURRENT_STREAMS without error.
        assertSucceeds(self.server.sendSettings([HTTP2Setting(parameter: .maxConcurrentStreams, value: 2)]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([HTTP2Setting(parameter: .maxConcurrentStreams, value: 2)]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )

        // The server can now cleanly close all but two of the existing streams.
        for streamID in clientStreamIDs.dropLast(2) {
            assertSucceeds(
                self.server.sendHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.trailers,
                    isEndStreamSet: true
                )
            )
            assertSucceeds(
                self.client.receiveHeaders(
                    streamID: streamID,
                    headers: ConnectionStateMachineTests.trailers,
                    isEndStreamSet: true
                )
            )
        }

        // The client still cannot initiate new streams here.
        tempClient = self.client!
        tempServer = self.server!
        assertConnectionError(
            type: .protocolError,
            tempClient.sendHeaders(
                streamID: stream101,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertConnectionError(
            type: .protocolError,
            tempServer.receiveHeaders(
                streamID: stream101,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server can now drop one more stream.
        assertSucceeds(
            self.server.sendHeaders(
                streamID: clientStreamIDs.last!,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: clientStreamIDs.last!,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: true
            )
        )

        // Now the client can open a new one!
        assertSucceeds(
            self.client.sendHeaders(
                streamID: stream101,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: stream101,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
    }

    func testDisablingPushPreventsPush() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        // Client is going to set SETTINGS_ENABLE_PUSH to false.
        assertSucceeds(self.client.sendSettings([HTTP2Setting(parameter: .enablePush, value: 0)]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([HTTP2Setting(parameter: .enablePush, value: 0)]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )

        assertSucceeds(self.server.sendSettings([]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )

        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )

        // Client initiates a stream.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // Server may not push.
        var tempClient = self.client!
        var tempServer = self.server!
        assertConnectionError(
            type: .protocolError,
            tempServer.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            tempClient.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Client can re-enable push.
        assertSucceeds(self.client.sendSettings([HTTP2Setting(parameter: .enablePush, value: 1)]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([HTTP2Setting(parameter: .enablePush, value: 1)]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )

        // Push is now allowed.
        assertSucceeds(
            self.server.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Out-of-bounds push values are forbidden.
        assertConnectionError(
            type: .protocolError,
            self.client.sendSettings([HTTP2Setting(parameter: .enablePush, value: 2)])
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receiveSettings(
                .settings([HTTP2Setting(parameter: .enablePush, value: 2)]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
    }

    func testClientsCannotPush() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        // Default settings.
        assertSucceeds(self.client.sendSettings([]))
        assertSucceeds(
            self.server.receiveSettings(
                .settings([]),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(self.server.sendSettings([]))
        assertSucceeds(
            self.client.receiveSettings(
                .settings([]),
                frameEncoder: &self.clientEncoder,
                frameDecoder: &self.clientDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
        assertSucceeds(
            self.server.receiveSettings(.ack, frameEncoder: &self.serverEncoder, frameDecoder: &self.serverDecoder)
        )

        // Client attempts to push, using a _server_ stream ID, with stream one not open. This should fail on both server and client.
        assertConnectionError(
            type: .protocolError,
            self.client.sendPushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders
            )
        )

        // Client then sends a HEADERS frame on the stream it just pushed. This should also fail.
        assertConnectionError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertConnectionError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamTwo,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
    }

    func testRatchetingGoawayEvenWhenFullyQueisced() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(streamsToOpen: [streamSeven], lastStreamID: .maxID, expectedToClose: nil)

        // Now the server ratchets down slowly.
        for (lastStreamID, dropping) in [
            (streamSeven, nil), (streamFive, streamSeven), (streamThree, nil), (streamOne, nil), (.rootStream, nil),
        ] {
            assertGoawaySucceeds(
                self.server.sendGoaway(lastStreamID: lastStreamID),
                droppingStreams: dropping.map { [$0] }
            )
            assertGoawaySucceeds(
                self.client.receiveGoaway(lastStreamID: lastStreamID),
                droppingStreams: dropping.map { [$0] }
            )

            // Duplicate goaways succeed, but change nothing.
            assertGoawaySucceeds(self.server.sendGoaway(lastStreamID: lastStreamID), droppingStreams: nil)
            assertGoawaySucceeds(self.client.receiveGoaway(lastStreamID: lastStreamID), droppingStreams: nil)
        }
    }

    func testRatchetingGoawayForBothPeersEvenWhenFullyQuiesced() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)
        let streamSeven = HTTP2StreamID(7)

        self.setupServerGoaway(streamsToOpen: [streamSeven], lastStreamID: .maxID, expectedToClose: nil)

        // Now the client quiesces the server.
        assertSucceeds(self.client.sendGoaway(lastStreamID: HTTP2StreamID(Int32.max - 1)))
        assertSucceeds(self.server.receiveGoaway(lastStreamID: HTTP2StreamID(Int32.max - 1)))

        // Now the server ratchets down slowly.
        for (lastStreamID, dropping) in [
            (streamSeven, nil), (streamFive, streamSeven), (streamThree, nil), (streamOne, nil), (.rootStream, nil),
        ] {
            assertGoawaySucceeds(
                self.server.sendGoaway(lastStreamID: lastStreamID),
                droppingStreams: dropping.map { [$0] }
            )
            assertGoawaySucceeds(
                self.client.receiveGoaway(lastStreamID: lastStreamID),
                droppingStreams: dropping.map { [$0] }
            )

            // Duplicate goaways succeed, but change nothing.
            assertGoawaySucceeds(self.server.sendGoaway(lastStreamID: lastStreamID), droppingStreams: nil)
            assertGoawaySucceeds(self.client.receiveGoaway(lastStreamID: lastStreamID), droppingStreams: nil)
        }

        // Now the client does a short ratchet too.
        assertGoawaySucceeds(self.client.sendGoaway(lastStreamID: .rootStream), droppingStreams: nil)
        assertGoawaySucceeds(self.server.receiveGoaway(lastStreamID: .rootStream), droppingStreams: nil)

        // And again, the duplicate goaway is fine.
        assertGoawaySucceeds(self.client.sendGoaway(lastStreamID: .rootStream), droppingStreams: nil)
        assertGoawaySucceeds(self.server.receiveGoaway(lastStreamID: .rootStream), droppingStreams: nil)
    }

    func testClientTrailersMustHaveEndStreamSet() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        // Client initiates a stream.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: false
            )
        )

        // If the client attempts to send trailers without end stream, this fails with a stream error.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )
    }

    func testServerTrailersMustHaveEndStreamSet() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        // Client initiates a stream.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Server sends back headers.
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )

        // If the server attempts to send trailers without end stream, this fails with a stream error.
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.trailers,
                isEndStreamSet: false
            )
        )
    }

    func testRejectHeadersWithUppercaseHeaderFieldName() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        self.exchangePreamble()

        let invalidExtraHeaders = [("UppercaseFieldName", "value")]

        // First, test that client initial headers may not contain uppercase headers.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have uppercase headers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testAllowHeadersWithUppercaseHeaderFieldNameWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let invalidExtraHeaders = [("UppercaseFieldName", "value")]

        // First, test that client initial headers may not contain uppercase headers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have uppercase headers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testRejectPseudoHeadersAfterRegularHeaders() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        self.exchangePreamble()

        let invalidExtraHeaders = [(":pseudo", "value")]

        // First, test that client initial headers may not contain pseudo-headers after regular ones.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have pseudo-headers after regular ones.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testAllowPseudoHeadersAfterRegularHeaders() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let invalidExtraHeaders = [(":pseudo", "value")]

        // First, test that client initial headers may not contain pseudo-headers after regular ones.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have pseudo-headers after regular ones.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testRejectRequestHeadersWithMissingMethodField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":scheme", "https"), (":path", "/"), ("content-length", "0"),
        ])

        // Request headers must contain :method.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithMissingMethodFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":scheme", "https"), (":path", "/"), ("content-length", "0"),
        ])

        // Request headers must contain :method.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithMissingPathField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":scheme", "https"), (":method", "GET"), ("content-length", "0"),
        ])

        // Request headers must contain :path.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithMissingPathFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":scheme", "https"), (":method", "GET"), ("content-length", "0"),
        ])

        // Request headers must contain :path.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithEmptyPathField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":scheme", "https"), (":method", "GET"), (":path", ""),
            ("content-length", "0"),
        ])

        // Request headers must contain non-empty :path.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithEmptyPathFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":scheme", "https"), (":method", "GET"), (":path", ""),
            ("content-length", "0"),
        ])

        // Request headers must contain non-empty :path.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithMissingSchemeField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":method", "GET"), (":path", "/"), ("content-length", "0"),
        ])

        // Request headers must contain :scheme.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithMissingSchemeFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":authority", "localhost"), (":method", "GET"), (":path", "/"), ("content-length", "0"),
        ])

        // Request headers must contain :scheme.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithDuplicateMethodField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":method", "GET"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "0"),
        ])

        // Request headers must contain only one :method.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithDuplicateMethodFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":method", "GET"), (":method", "GET"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "0"),
        ])

        // Request headers must contain only one :method.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithDuplicatePathField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":path", "/"), (":path", "/"), (":authority", "localhost"), (":scheme", "https"), (":method", "GET"),
            ("content-length", "0"),
        ])

        // Request headers must contain only one :path.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithDuplicatePathFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":path", "/"), (":path", "/"), (":authority", "localhost"), (":scheme", "https"), (":method", "GET"),
            ("content-length", "0"),
        ])

        // Request headers must contain only one :path.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithDuplicateSchemeField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":scheme", "https"), (":scheme", "https"), (":authority", "localhost"), (":method", "GET"), (":path", "/"),
            ("content-length", "0"),
        ])

        // Request headers must contain only one :scheme.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithDuplicateSchemeFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":scheme", "https"), (":scheme", "https"), (":authority", "localhost"), (":method", "GET"), (":path", "/"),
            ("content-length", "0"),
        ])

        // Request headers must contain only one :scheme.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectResponseHeadersWithMissingStatusField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([("content-length", "0")])

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Response headers must contain :status.
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowResponseHeadersWithMissingStatusFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([("content-length", "0")])

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Response headers must contain :status.
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectResponseHeadersWithDuplicateStatusField() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":status", "200"), (":status", "200"), ("content-length", "0")])

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Response headers must contain only one :status.
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowResponseHeadersWithDuplicateStatusFieldWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":status", "200"), (":status", "200"), ("content-length", "0")])

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Response headers must contain only one :status.
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectTrailersHeadersWithAnyPseudoHeader() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let trailers = HPACKHeaders([(":method", "GET")])

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Trailers must not contain pseudo-headers.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: trailers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: trailers, isEndStreamSet: true)
        )
    }

    func testRejectRequestHeadersWithSchemeFieldOnCONNECT() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":authority", "localhost:443"), (":method", "CONNECT"), (":scheme", "https")])

        // Request headers for a CONNECT request must not contain :scheme.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithSchemeFieldOnCONNECTValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":authority", "localhost:443"), (":method", "CONNECT"), (":scheme", "https")])

        // Request headers for a CONNECT request must not contain :scheme.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithPathFieldOnCONNECT() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":authority", "localhost:443"), (":method", "CONNECT"), (":path", "/")])

        // Request headers for a CONNECT request must not contain :scheme.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithPathFieldOnCONNECTValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":authority", "localhost:443"), (":method", "CONNECT"), (":path", "/")])

        // Request headers for a CONNECT request must not contain :scheme.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testAllowSimpleConnectRequest() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":authority", "localhost:443"), (":method", "CONNECT")])
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectRequestHeadersWithoutAuthorityFieldOnCONNECT() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":method", "CONNECT")])

        // Request headers for a CONNECT request must contain :authority.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testAllowRequestHeadersWithoutAuthorityFieldOnCONNECTValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let headers = HPACKHeaders([(":method", "CONNECT")])

        // Request headers for a CONNECT request must not contain :scheme.
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testProtocolPseudoheaderWithoutEnableConnectProtocolSetting() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let headers = HPACKHeaders([
            (":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"), (":path", "/chat"),
        ])

        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testProtocolPseudoheaderWithEnableConnectProtocolSetting() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble(server: [HTTP2Setting(parameter: .enableConnectProtocol, value: 1)])

        let headers = HPACKHeaders([
            (":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"), (":path", "/chat"),
        ])

        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true))
    }

    func testRejectProtocolPseudoHeaderWithoutConnectMethod() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble(server: [HTTP2Setting(parameter: .enableConnectProtocol, value: 1)])

        let headers = HPACKHeaders([
            (":method", "GET"), (":protocol", "websocket"), (":scheme", "https"), (":path", "/chat"),
        ])
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: headers, isEndStreamSet: true)
        )
    }

    func testRejectHeadersWithConnectionHeader() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        self.exchangePreamble()

        let invalidExtraHeaders = [("connection", "close")]

        // First, test that client initial headers may not contain the connection header.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have the connection header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testAllowHeadersWithConnectionHeaderWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let invalidExtraHeaders = [("connection", "close")]

        // First, test that client initial headers may not contain the connection header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have the connection header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testRejectHeadersWithTransferEncodingHeader() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        self.exchangePreamble()

        let invalidExtraHeaders = [("transfer-encoding", "chunked")]

        // First, test that client initial headers may not contain the transfer-encoding header.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have the transfer-encoding header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testAllowHeadersWithTransferEncodingHeaderWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let invalidExtraHeaders = [("transfer-encoding", "chunked")]

        // First, test that client initial headers may not contain the transfer-encoding header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have the transfer-encoding header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testRejectHeadersWithProxyConnectionHeader() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        self.exchangePreamble()

        let invalidExtraHeaders = [("proxy-connection", "close")]

        // First, test that client initial headers may not contain the proxy=connection header.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have the proxy-connection header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testAllowHeadersWithProxyConnectionHeaderWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let invalidExtraHeaders = [("proxy-connection", "close")]

        // First, test that client initial headers may not contain the proxy-connection header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response cannot have the proxy-connection header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testRejectHeadersWithTEHeaderNotTrailers() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        self.exchangePreamble()

        let invalidExtraHeaders = [("te", "deflate")]

        // First, test that client initial headers may not contain the TE header.
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response *may* have the TE header. This is allowed as TE is only defined on requests.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers. Again, this is allowed.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testAllowHeadersWithTEHeaderNotTrailersWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)
        let streamThree = HTTP2StreamID(3)
        let streamFive = HTTP2StreamID(5)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, headerBlockValidation: .disabled)
        self.client = .init(role: .client, headerBlockValidation: .disabled)

        self.exchangePreamble()

        let invalidExtraHeaders = [("te", "deflate")]

        // First, test that client initial headers may not contain the TE header.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, set up a valid stream for the client and confirm that the server response *may* have the TE header. This is allowed as TE is only defined on requests.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamThree,
                headers: ConnectionStateMachineTests.responseHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )

        // Next, test this with trailers. Again, this is allowed.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.responseHeaders,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.client.receiveHeaders(
                streamID: streamFive,
                headers: ConnectionStateMachineTests.trailers.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testAllowHeadersWithTEHeaderSetToTrailers() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let invalidExtraHeaders = [("te", "trailers")]

        // Client headers may contain TE: trailers.
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders.withExtraHeaders(invalidExtraHeaders),
                isEndStreamSet: true
            )
        )
    }

    func testSettingActualMaxFrameSize() {
        self.exchangePreamble()

        // It must be possible to set SETTINGS_MAX_FRAME_SIZE to (2**24)-1.
        let trickySettings: HTTP2Settings = [HTTP2Setting(parameter: .maxFrameSize, value: (1 << 24) - 1)]
        assertSucceeds(self.client.sendSettings(trickySettings))
        assertSucceeds(
            self.server.receiveSettings(
                .settings(trickySettings),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
    }

    func testSettingActualInitialWindowSize() {
        self.exchangePreamble()

        // It must be possible to set SETTINGS_INITIAL_WINDOW_SIZE to (2**31)-1.
        let trickySettings: HTTP2Settings = [HTTP2Setting(parameter: .initialWindowSize, value: (1 << 31) - 1)]
        assertSucceeds(self.client.sendSettings(trickySettings))
        assertSucceeds(
            self.server.receiveSettings(
                .settings(trickySettings),
                frameEncoder: &self.serverEncoder,
                frameDecoder: &self.serverDecoder
            )
        )
        assertSucceeds(
            self.client.receiveSettings(.ack, frameEncoder: &self.clientEncoder, frameDecoder: &self.clientDecoder)
        )
    }

    func testPolicingExceedingContentLengthForRequests() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "POST"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "25"),
        ])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))

        // Send in 25 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        var tempClient = self.client!
        var tempServer = self.server!

        // Sending any more data fails.
        assertStreamError(
            type: .protocolError,
            tempClient.sendData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            tempServer.receiveData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )

        // But if we send a zero length frame that works fine.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            self.server.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testPolicingExceedingContentLengthForResponses() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 25 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        var tempClient = self.client!
        var tempServer = self.server!

        // Sending any more data fails.
        assertStreamError(
            type: .protocolError,
            tempServer.sendData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            tempClient.receiveData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )

        // But if we send a zero length frame that works fine.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testPolicingMissingContentLengthForRequests() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "POST"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "25"),
        ])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))

        // Send in 20 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        // Closing the stream fails.
        assertStreamError(
            type: .protocolError,
            self.client.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testPolicingMissingContentLengthForResponses() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 20 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        // Closing the stream fails.
        assertStreamError(
            type: .protocolError,
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testPolicingInvalidContentLengthForRequestsWithEndStream() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "POST"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "25"),
        ])

        // Set up the connection
        assertStreamError(
            type: .protocolError,
            self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true)
        )
    }

    func testPolicingInvalidContentLengthForResponsesWithEndStream() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: true)
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: true)
        )
    }

    func testValidContentLengthForRequestsWithEndStream() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "POST"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "0"),
        ])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))
    }

    func testValidContentLengthForResponsesWithEndStream() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: true))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: true))
    }

    func testNoPolicingExceedingContentLengthForRequestsWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, contentLengthValidation: .disabled)
        self.client = .init(role: .client, contentLengthValidation: .disabled)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "POST"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "25"),
        ])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))

        // Send in 25 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        var tempClient = self.client!
        var tempServer = self.server!

        // Sending any more data succeeds.
        assertSucceeds(
            tempClient.sendData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            tempServer.receiveData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )

        // But if we send a zero length frame that works fine.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            self.server.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testNoPolicingExceedingContentLengthForResponsesWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, contentLengthValidation: .disabled)
        self.client = .init(role: .client, contentLengthValidation: .disabled)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 25 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 15, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 15,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        var tempClient = self.client!
        var tempServer = self.server!

        // Sending any more data succeeds.
        assertSucceeds(
            tempServer.sendData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            tempClient.receiveData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )

        // But if we send a zero length frame that works fine.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testNoPolicingMissingContentLengthForRequestsWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, contentLengthValidation: .disabled)
        self.client = .init(role: .client, contentLengthValidation: .disabled)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "POST"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "25"),
        ])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: false))

        // Send in 20 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.server.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        // Closing the stream succeeds.
        assertSucceeds(
            self.client.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            self.server.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testNoPolicingMissingContentLengthForResponsesWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, contentLengthValidation: .disabled)
        self.client = .init(role: .client, contentLengthValidation: .disabled)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 20 bytes over two frames, messing with the flow controlled length to just be a bit tricky.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 10, flowControlledBytes: 15, isEndStreamSet: false)
        )
        assertSucceeds(
            self.client.receiveData(
                streamID: streamOne,
                contentLength: 10,
                flowControlledBytes: 15,
                isEndStreamSet: false
            )
        )

        // Closing the stream succeeds.
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testNoPolicingInvalidContentLengthForRequestsWithEndStreamWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, contentLengthValidation: .disabled)
        self.client = .init(role: .client, contentLengthValidation: .disabled)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "POST"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("content-length", "25"),
        ])

        // Set up the succeeds
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))
    }

    func testNoPolicingInvalidContentLengthForResponsesWithEndStreamWhenValidationDisabled() {
        let streamOne = HTTP2StreamID(1)

        // Override the setup with validation disabled.
        self.server = .init(role: .server, contentLengthValidation: .disabled)
        self.client = .init(role: .client, contentLengthValidation: .disabled)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server succeeds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: true))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: true))
    }

    func testReceivedAltServiceFramesAreIgnored() {
        self.exchangePreamble()
        assertIgnored(self.client.receiveAlternativeService(origin: "over-there", field: nil))
        assertIgnored(self.server.receiveAlternativeService(origin: "over-there", field: nil))
    }

    func testReceivedOriginFramesAreIgnored() {
        self.exchangePreamble()
        assertIgnored(self.client.receiveOrigin(origins: ["one", "two"]))
        assertIgnored(self.server.receiveOrigin(origins: ["one", "two"]))
    }

    func testContentLengthForStatus304() {
        let streamOne = HTTP2StreamID(1)

        self.server = .init(role: .server)
        self.client = .init(role: .client)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "304"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 0 bytes over two sets
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
    }

    func testContentLengthForStatus304Failure() {
        let streamOne = HTTP2StreamID(1)

        self.server = .init(role: .server)
        self.client = .init(role: .client)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "304"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 1 byte over one frame
        assertStreamError(
            type: HTTP2ErrorCode.protocolError,
            self.server.sendData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertStreamError(
            type: HTTP2ErrorCode.protocolError,
            self.client.receiveData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testContentLengthForMethodHead() {
        let streamOne = HTTP2StreamID(1)

        self.server = .init(role: .server)
        self.client = .init(role: .client)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "HEAD"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("user-agent", "test"),
        ])
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 0 bytes over one frame
        assertSucceeds(
            self.server.sendData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
        assertSucceeds(
            self.client.receiveData(streamID: streamOne, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
    }

    func testContentLengthForHeadFailure() {
        let streamOne = HTTP2StreamID(1)

        self.server = .init(role: .server)
        self.client = .init(role: .client)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "HEAD"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("user-agent", "test"),
        ])
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))
        assertSucceeds(self.server.receiveHeaders(streamID: streamOne, headers: requestHeaders, isEndStreamSet: true))

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false))

        // Send in 1 byte over 1 frame
        assertStreamError(
            type: HTTP2ErrorCode.protocolError,
            self.server.sendData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertStreamError(
            type: HTTP2ErrorCode.protocolError,
            self.client.receiveData(streamID: streamOne, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testPushHeadRequestFailure() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "HEAD"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("user-agent", "test"),
        ])
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Server can push right away
        assertSucceeds(
            self.server.sendPushPromise(originalStreamID: streamOne, childStreamID: streamTwo, headers: requestHeaders)
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: requestHeaders
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamTwo, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamTwo, headers: responseHeaders, isEndStreamSet: false))

        // Send in 1 byte over one frame
        assertStreamError(
            type: HTTP2ErrorCode.protocolError,
            self.server.sendData(streamID: streamTwo, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
        assertStreamError(
            type: HTTP2ErrorCode.protocolError,
            self.client.receiveData(streamID: streamTwo, contentLength: 1, flowControlledBytes: 1, isEndStreamSet: true)
        )
    }

    func testPushHeadRequest() {
        let streamOne = HTTP2StreamID(1)
        let streamTwo = HTTP2StreamID(2)

        self.exchangePreamble()

        let requestHeaders = HPACKHeaders([
            (":method", "HEAD"), (":authority", "localhost"), (":scheme", "https"), (":path", "/"),
            ("user-agent", "test"),
        ])
        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "25")])

        assertSucceeds(
            self.client.sendHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )
        assertSucceeds(
            self.server.receiveHeaders(
                streamID: streamOne,
                headers: ConnectionStateMachineTests.requestHeaders,
                isEndStreamSet: true
            )
        )

        // Server can push right away
        assertSucceeds(
            self.server.sendPushPromise(originalStreamID: streamOne, childStreamID: streamTwo, headers: requestHeaders)
        )
        assertSucceeds(
            self.client.receivePushPromise(
                originalStreamID: streamOne,
                childStreamID: streamTwo,
                headers: requestHeaders
            )
        )

        // The server responds
        assertSucceeds(self.server.sendHeaders(streamID: streamTwo, headers: responseHeaders, isEndStreamSet: false))
        assertSucceeds(self.client.receiveHeaders(streamID: streamTwo, headers: responseHeaders, isEndStreamSet: false))

        // Send in 0 bytes over one frame
        assertSucceeds(
            self.client.receiveData(streamID: streamTwo, contentLength: 0, flowControlledBytes: 0, isEndStreamSet: true)
        )
    }

    func testNegativeContentLengthHeader() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "-25")])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: Self.requestHeaders, isEndStreamSet: true))
        assertSucceeds(
            self.server.receiveHeaders(streamID: streamOne, headers: Self.requestHeaders, isEndStreamSet: true)
        )

        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false)
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false)
        )
    }

    func testInvalidContentLengthHeader() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "0xFF")])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: Self.requestHeaders, isEndStreamSet: true))
        assertSucceeds(
            self.server.receiveHeaders(streamID: streamOne, headers: Self.requestHeaders, isEndStreamSet: true)
        )

        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false)
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false)
        )
    }

    func testContentLengthHeadersMismatch() {
        let streamOne = HTTP2StreamID(1)

        self.exchangePreamble()

        let responseHeaders = HPACKHeaders([(":status", "200"), ("content-length", "1384"), ("content-length", "4831")])

        // Set up the connection
        assertSucceeds(self.client.sendHeaders(streamID: streamOne, headers: Self.requestHeaders, isEndStreamSet: true))
        assertSucceeds(
            self.server.receiveHeaders(streamID: streamOne, headers: Self.requestHeaders, isEndStreamSet: true)
        )

        assertStreamError(
            type: .protocolError,
            self.server.sendHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false)
        )
        assertStreamError(
            type: .protocolError,
            self.client.receiveHeaders(streamID: streamOne, headers: responseHeaders, isEndStreamSet: false)
        )
    }

    func testMaxRecentlyResetStreamFrames() {
        // Internally a circular buffer is used to track recently reset streams which has its capacity
        // reserved on init. This is rounded up to the next power of 2. However, in order to
        // not grow beyond that size its effective capacity is less than the allocated capacity.
        //
        // Setting maxResetStreams to 64 means the effective capacity is 63.
        let effectiveMaxResetStreams = 63
        // Create one more stream than that to check that going beyond the limit causes an error.
        let streamsToCreate = 64

        self.client = HTTP2ConnectionStateMachine(role: .client, maxResetStreams: effectiveMaxResetStreams)
        self.exchangePreamble()

        let streamIDs = (0..<streamsToCreate).map { HTTP2StreamID($0 * 2 + 1) }
        print(streamIDs.count)

        // Open the streams; both peers know about them.
        for streamID in streamIDs {
            assertSucceeds(
                self.client.sendHeaders(streamID: streamID, headers: Self.requestHeaders, isEndStreamSet: false)
            )
            assertSucceeds(
                self.server.receiveHeaders(streamID: streamID, headers: Self.requestHeaders, isEndStreamSet: false)
            )
        }

        // Have the client reset all streams.
        for streamID in streamIDs {
            assertSucceeds(self.client.sendRstStream(streamID: streamID, reason: .cancel))
        }

        // Have the server send response headers. The server allows it (it hasn't yet received RST_STREAM). The client ignores all
        // but the last (which is one more than the limit).
        for streamID in streamIDs {
            assertSucceeds(
                self.server.sendHeaders(streamID: streamID, headers: Self.responseHeaders, isEndStreamSet: false)
            )
            let result = self.client.receiveHeaders(
                streamID: streamID,
                headers: Self.responseHeaders,
                isEndStreamSet: false
            )

            // The first stream results in a connection error, it was the first to be reset so the
            // first to be forgotten about when the client sent the RST_STREAM frames.
            if streamID == streamIDs.first {
                assertConnectionError(type: .streamClosed, result)
            } else {
                assertIgnored(result)
            }
        }

    }
}

extension HPACKHeaders {
    /// Take the header block and add some more.
    internal func withExtraHeaders(_ headers: [(String, String)]) -> HPACKHeaders {
        var newHeaders = self
        for header in headers {
            newHeaders.add(name: header.0, value: header.1)
        }
        return newHeaders
    }
}
