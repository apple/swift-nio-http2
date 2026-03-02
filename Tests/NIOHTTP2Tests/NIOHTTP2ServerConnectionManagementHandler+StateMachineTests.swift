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
import Testing

@testable import NIOHTTP2

struct NIOHTTP2ServerConnectionManagementHandlerStateMachineTests {
    private func makeStateMachine(
        goAwayPingData: HTTP2PingData = HTTP2PingData(withInteger: 42)
    ) -> NIOHTTP2ServerConnectionManagementHandler.StateMachine {
        .init(goAwayPingData: goAwayPingData)
    }

    @Test("Closing last stream starts idle timer")
    func testCloseAllStreamsWhenActive() {
        var state = self.makeStateMachine()
        state.streamOpened(1)
        #expect(state.streamClosed(1) == .startIdleTimer)
    }

    @Test("Closing stream with others open returns no action")
    func testCloseSomeStreamsWhenActive() {
        var state = self.makeStateMachine()
        state.streamOpened(1)
        state.streamOpened(2)
        #expect(state.streamClosed(2) == .none)
    }

    @Test("Stream operations after close are no-ops")
    func testOpenAndCloseStreamWhenClosed() {
        var state = self.makeStateMachine()
        state.markClosed()
        state.streamOpened(1)
        #expect(state.streamClosed(1) == .none)
    }

    @Test("Graceful shutdown when no open streams")
    func testGracefulShutdownWhenNoOpenStreams() {
        let pingData = HTTP2PingData(withInteger: 42)
        var state = self.makeStateMachine(goAwayPingData: pingData)
        #expect(state.startGracefulShutdown() == .sendGoAwayAndPing(pingData))
    }

    @Test("Repeated graceful shutdown is idempotent")
    func testGracefulShutdownWhenClosing() {
        let pingData = HTTP2PingData(withInteger: 42)
        var state = self.makeStateMachine(goAwayPingData: pingData)
        #expect(state.startGracefulShutdown() == .sendGoAwayAndPing(pingData))
        #expect(state.startGracefulShutdown() == .none)
    }

    @Test("Graceful shutdown after close is a no-op")
    func testGracefulShutdownWhenClosed() {
        let pingData = HTTP2PingData(withInteger: 42)
        var state = self.makeStateMachine(goAwayPingData: pingData)
        state.markClosed()
        #expect(state.startGracefulShutdown() == .none)
    }

    @Test("Stream opened just before sending first ping")
    func testReceiveAckForGoAwayPingWhenStreamsOpenedBeforeShutdownOnly() {
        let pingData = HTTP2PingData(withInteger: 42)
        var state = self.makeStateMachine(goAwayPingData: pingData)
        state.streamOpened(1)
        #expect(state.startGracefulShutdown() == .sendGoAwayAndPing(pingData))
        #expect(state.receivedPingAck(data: pingData) == .sendGoAway(lastStreamID: 1, close: false))
    }

    @Test("Stream opened after sending first ping but before receiving ack")
    func testReceiveAckForGoAwayPingWhenStreamsOpenedBeforeAck() {
        let pingData = HTTP2PingData(withInteger: 42)
        var state = self.makeStateMachine(goAwayPingData: pingData)
        #expect(state.startGracefulShutdown() == .sendGoAwayAndPing(pingData))
        state.streamOpened(1)
        #expect(state.receivedPingAck(data: pingData) == .sendGoAway(lastStreamID: 1, close: false))
    }

    @Test("Receiving ping ack with no streams sends final GOAWAY and closes")
    func testReceiveAckForGoAwayPingWhenNoOpenStreams() {
        let pingData = HTTP2PingData(withInteger: 42)
        var state = self.makeStateMachine(goAwayPingData: pingData)
        #expect(state.startGracefulShutdown() == .sendGoAwayAndPing(pingData))
        #expect(state.receivedPingAck(data: pingData) == .sendGoAway(lastStreamID: .rootStream, close: true))
    }

    @Test("Non-matching ping ack is ignored")
    func testReceiveAckNotForGoAwayPing() {
        let pingData = HTTP2PingData(withInteger: 42)
        var state = self.makeStateMachine(goAwayPingData: pingData)
        #expect(state.startGracefulShutdown() == .sendGoAwayAndPing(pingData))

        let otherPingData = HTTP2PingData(withInteger: 0)
        #expect(state.receivedPingAck(data: otherPingData) == .none)
    }

    @Test("Ping ack when not shutting down is ignored")
    func testReceivePingAckWhenActive() {
        var state = self.makeStateMachine()
        #expect(state.receivedPingAck(data: HTTP2PingData()) == .none)
    }

    @Test("Ping ack after close is ignored")
    func testReceivePingAckWhenClosed() {
        var state = self.makeStateMachine()
        state.markClosed()
        #expect(state.receivedPingAck(data: HTTP2PingData()) == .none)
    }

    @Test("Full graceful shutdown waits for all streams to close")
    func testGracefulShutdownFlow() {
        var state = self.makeStateMachine()
        // Open a few streams.
        state.streamOpened(1)
        state.streamOpened(2)

        switch state.startGracefulShutdown() {
        case .sendGoAwayAndPing(let pingData):
            // Open another stream and then receive the ping ack.
            state.streamOpened(3)
            #expect(state.receivedPingAck(data: pingData) == .sendGoAway(lastStreamID: 3, close: false))
        case .none:
            Issue.record("Expected '.sendGoAwayAndPing'")
        }

        // Both GOAWAY frames have been sent. Start closing streams.
        #expect(state.streamClosed(1) == .none)
        #expect(state.streamClosed(2) == .none)
        #expect(state.streamClosed(3) == .close)
    }

    @Test("Only close after receiving ping ack even when no streams are open")
    func testGracefulShutdownWhenNoOpenStreamsBeforeSecondGoAway() {
        var state = self.makeStateMachine()
        // Open a stream.
        state.streamOpened(1)

        switch state.startGracefulShutdown() {
        case .sendGoAwayAndPing(let pingData):
            // Close the stream. This shouldn't lead to a close.
            #expect(state.streamClosed(1) == .none)
            // Only on receiving the ack do we send a GOAWAY and close.
            #expect(state.receivedPingAck(data: pingData) == .sendGoAway(lastStreamID: 1, close: true))
        case .none:
            Issue.record("Expected '.sendGoAwayAndPing'")
        }
    }
}
