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
import NIOHTTP1

/// A protocol that provides implementation for receiving HEADERS frames, for those states that
/// can validly accept headers.
///
/// This protocol should only be conformed to by states for the HTTP/2 connection state machine.
protocol ReceivingHeadersState {
    var role: HTTP2ConnectionStateMachine.ConnectionRole { get }

    var streamState: ConnectionStreamState { get set }

    var localInitialWindowSize: UInt32 { get }

    var remoteInitialWindowSize: UInt32 { get }
}

extension ReceivingHeadersState {
    /// Called when we receive a HEADERS frame in this state.
    mutating func receiveHeaders(streamID: HTTP2StreamID, headers: HTTPHeaders, isEndStreamSet endStream: Bool) -> StateMachineResult {
        if self.role == .server && streamID.mayBeInitiatedBy(.client) {
            // Clients may initiate streams with HEADERS frames, so we allow this stream to not exist.
            let defaultValue = HTTP2StreamStateMachine(streamID: streamID,
                                                       localRole: .server,
                                                       localInitialWindowSize: self.localInitialWindowSize,
                                                       remoteInitialWindowSize: self.remoteInitialWindowSize)

            do {
                return try self.streamState.modifyStreamStateCreateIfNeeded(streamID: streamID, initialValue: defaultValue) {
                    $0.receiveHeaders(headers: headers, isEndStreamSet: endStream)
                }
            } catch {
                return .connectionError(underlyingError: error, type: .protocolError)
            }
        } else {
            // HEADERS cannot create streams for servers, so this must be for a stream we already know about.
            return self.streamState.modifyStreamState(streamID: streamID, ignoreRecentlyReset: true) {
                $0.receiveHeaders(headers: headers, isEndStreamSet: endStream)
            }
        }
    }
}


extension ReceivingHeadersState where Self: LocallyQuiescingState {
    /// Called when we receive a HEADERS frame in this state.
    ///
    /// If we've quiesced this connection, the remote peer is no longer allowed to create new streams.
    /// We ignore any frame that appears to be creating a new stream, and then prevent this from creating
    /// new streams.
    mutating func receiveHeaders(streamID: HTTP2StreamID, headers: HTTPHeaders, isEndStreamSet endStream: Bool) -> StateMachineResult {
        if streamID.mayBeInitiatedBy(.client) && streamID > self.lastRemoteStreamID {
            return .ignoreFrame
        }

        // At this stage we've quiesced, so the remote peer is not allowed to create new streams.
        return self.streamState.modifyStreamState(streamID: streamID, ignoreRecentlyReset: true) {
            $0.receiveHeaders(headers: headers, isEndStreamSet: endStream)
        }
    }
}
