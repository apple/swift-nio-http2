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

extension NIOHTTP2ServerConnectionManagementHandler {
    /// Tracks the state of TCP connections at the server.
    ///
    /// The state machine manages the state for the graceful shutdown procedure.
    struct StateMachine {
        /// Current state.
        private var state: State

        /// Opaque data sent to the client in a PING frame after emitting the first GOAWAY frame
        /// as part of graceful shutdown.
        private let goAwayPingData: HTTP2PingData

        /// Create a new state machine.
        ///
        /// - Parameters:
        ///   - goAwayPingData: Opaque data sent to the client in a PING frame when the server
        ///       initiates graceful shutdown.
        init(goAwayPingData: HTTP2PingData = HTTP2PingData(withInteger: .random(in: .min ... .max))) {
            self.state = .active(State.Active())
            self.goAwayPingData = goAwayPingData
        }

        /// Record that the stream with the given ID has been opened.
        mutating func streamOpened(_ id: HTTP2StreamID) {
            switch self.state {
            case .active(var state):
                self.state = ._modifying
                state.lastStreamID = id
                let (inserted, _) = state.openStreams.insert(id)
                assert(inserted, "Can't open stream \(Int(id)), it's already open")
                self.state = .active(state)

            case .closing(var state):
                self.state = ._modifying
                state.lastStreamID = id
                let (inserted, _) = state.openStreams.insert(id)
                assert(inserted, "Can't open stream \(Int(id)), it's already open")
                self.state = .closing(state)

            case .closed:
                ()

            case ._modifying:
                preconditionFailure()
            }
        }

        enum OnStreamClosed: Equatable {
            /// Start the idle timer, after which the connection should be closed gracefully.
            case startIdleTimer
            /// Close the connection.
            case close
            /// Do nothing.
            case none
        }

        /// Record that the stream with the given ID has been closed.
        mutating func streamClosed(_ id: HTTP2StreamID) -> OnStreamClosed {
            let onStreamClosed: OnStreamClosed

            switch self.state {
            case .active(var state):
                self.state = ._modifying
                let removedID = state.openStreams.remove(id)
                assert(removedID != nil, "Can't close stream \(Int(id)), it wasn't open")
                onStreamClosed = state.openStreams.isEmpty ? .startIdleTimer : .none
                self.state = .active(state)

            case .closing(var state):
                self.state = ._modifying
                let removedID = state.openStreams.remove(id)
                assert(removedID != nil, "Can't close stream \(Int(id)), it wasn't open")
                // If the second GOAWAY hasn't been sent it isn't safe to close if there are no open
                // streams: the client may have opened a stream which the server doesn't know about yet.
                let canClose = state.sentSecondGoAway && state.openStreams.isEmpty
                onStreamClosed = canClose ? .close : .none
                self.state = .closing(state)

            case .closed:
                onStreamClosed = .none

            case ._modifying:
                preconditionFailure()
            }

            return onStreamClosed
        }

        enum OnPingAck: Equatable {
            /// Send a GOAWAY frame with no error and the given last stream ID, optionally closing the
            /// connection immediately afterwards.
            case sendGoAway(lastStreamID: HTTP2StreamID, close: Bool)
            /// Ignore the ack.
            case none
        }

        /// Received a PING frame with the 'ack' flag set.
        mutating func receivedPingAck(data: HTTP2PingData) -> OnPingAck {
            let onPingAck: OnPingAck

            switch self.state {
            case .closing(var state):
                self.state = ._modifying

                // If only one GOAWAY has been sent and the data matches the data from the GOAWAY ping then
                // the server should send another GOAWAY ratcheting down the last stream ID. If no streams
                // are open then the server can close the connection immediately after, otherwise it must
                // wait until all streams are closed.
                if !state.sentSecondGoAway, data == self.goAwayPingData {
                    state.sentSecondGoAway = true

                    if state.openStreams.isEmpty {
                        self.state = .closed
                        onPingAck = .sendGoAway(lastStreamID: state.lastStreamID, close: true)
                    } else {
                        self.state = .closing(state)
                        onPingAck = .sendGoAway(lastStreamID: state.lastStreamID, close: false)
                    }
                } else {
                    onPingAck = .none
                }

                self.state = .closing(state)

            case .active, .closed:
                onPingAck = .none

            case ._modifying:
                preconditionFailure()
            }

            return onPingAck
        }

        enum OnStartGracefulShutdown: Equatable {
            /// Initiate graceful shutdown by sending a GOAWAY frame with the last stream ID set as the max
            /// stream ID and no error. Follow it immediately with a PING frame with the given data.
            case sendGoAwayAndPing(HTTP2PingData)
            /// Ignore the request to start graceful shutdown.
            case none
        }

        /// Request that the connection begins graceful shutdown.
        mutating func startGracefulShutdown() -> OnStartGracefulShutdown {
            let onStartGracefulShutdown: OnStartGracefulShutdown

            switch self.state {
            case .active(let state):
                self.state = .closing(State.Closing(from: state))
                onStartGracefulShutdown = .sendGoAwayAndPing(self.goAwayPingData)

            case .closing, .closed:
                onStartGracefulShutdown = .none

            case ._modifying:
                preconditionFailure()
            }

            return onStartGracefulShutdown
        }

        /// Marks the state as closed.
        mutating func markClosed() {
            self.state = .closed
        }
    }
}

extension NIOHTTP2ServerConnectionManagementHandler.StateMachine {
    fileprivate enum State {
        /// The connection is active.
        struct Active {
            /// The number of open streams.
            var openStreams: Set<HTTP2StreamID>
            /// The ID of the most recently opened stream (zero indicates no streams have been opened yet).
            var lastStreamID: HTTP2StreamID

            init() {
                self.openStreams = []
                self.lastStreamID = .rootStream
            }
        }

        /// The connection is closing gracefully, an initial GOAWAY frame has been sent (with the
        /// last stream ID set to max).
        struct Closing {
            /// The number of open streams.
            var openStreams: Set<HTTP2StreamID>
            /// The ID of the most recently opened stream (zero indicates no streams have been opened yet).
            var lastStreamID: HTTP2StreamID
            /// Whether the second GOAWAY frame has been sent with a lower stream ID.
            var sentSecondGoAway: Bool

            init(from state: Active) {
                self.openStreams = state.openStreams
                self.lastStreamID = state.lastStreamID
                self.sentSecondGoAway = false
            }
        }

        case active(Active)
        case closing(Closing)
        case closed
        case _modifying
    }
}
