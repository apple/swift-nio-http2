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

/// A protocol that provides implementation for receiving GOAWAY frames, for those states that
/// can validly be quiesced.
///
/// This protocol should only be conformed to by states for the HTTP/2 connection state machine.
protocol ReceivingGoawayState {
    var role: HTTP2ConnectionStateMachine.ConnectionRole { get }

    var streamState: ConnectionStreamState { get set }
}

extension ReceivingGoawayState {
    mutating func receiveGoAwayFrame(lastStreamID: HTTP2StreamID) -> (result: StateMachineResult, droppedStreams: [HTTP2StreamID]) {
        guard lastStreamID.mayBeInitiatedBy(self.role) || lastStreamID == .rootStream else {
            // The remote peer has sent a GOAWAY with an invalid stream ID.
            return (.connectionError(underlyingError: NIOHTTP2Errors.InvalidStreamIDForPeer(), type: .protocolError), [])
        }

        let droppedStreams = self.streamState.dropAllStreamsWithIDHigherThan(lastStreamID, droppedLocally: false, initiatedBy: self.role)
        return (.succeed, droppedStreams)
    }
}

extension ReceivingGoawayState where Self: RemotelyQuiescingState {
    mutating func receiveGoAwayFrame(lastStreamID: HTTP2StreamID) -> (result: StateMachineResult, droppedStreams: [HTTP2StreamID]) {
        guard lastStreamID.mayBeInitiatedBy(self.role) || lastStreamID == .rootStream else {
            // The remote peer has sent a GOAWAY with an invalid stream ID.
            return (.connectionError(underlyingError: NIOHTTP2Errors.InvalidStreamIDForPeer(), type: .protocolError), [])
        }

        if lastStreamID > self.lastLocalStreamID {
            // The remote peer has attempted to raise the lastStreamID.
            return (.connectionError(underlyingError: NIOHTTP2Errors.RaisedGoawayLastStreamID(), type: .protocolError), [])
        }

        let droppedStreams = self.streamState.dropAllStreamsWithIDHigherThan(lastStreamID, droppedLocally: false, initiatedBy: self.role)
        self.lastLocalStreamID = lastStreamID
        return (.succeed, droppedStreams)
    }
}

