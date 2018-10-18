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

/// A protocol that provides implementation for sending GOAWAY frames, for those states that
/// can validly initiate quiescing.
///
/// This protocol should only be conformed to by states for the HTTP/2 connection state machine.
protocol SendingGoawayState {
    var peerRole: HTTP2ConnectionStateMachine.ConnectionRole { get }

    var streamState: ConnectionStreamState { get set }
}

extension SendingGoawayState {
    mutating func sendGoAwayFrame(lastStreamID: HTTP2StreamID) -> (result: StateMachineResult, droppedStreams: [HTTP2StreamID]) {
        guard lastStreamID.mayBeInitiatedBy(self.peerRole) || lastStreamID == .rootStream else {
            // The user has sent a GOAWAY with an invalid stream ID.
            return (.connectionError(underlyingError: NIOHTTP2Errors.InvalidStreamIDForPeer(), type: .protocolError), [])
        }

        let droppedStreams = self.streamState.dropAllStreamsWithIDHigherThan(lastStreamID, droppedLocally: true, initiatedBy: self.peerRole)
        return (.succeed, droppedStreams)
    }
}

extension SendingGoawayState where Self: LocallyQuiescingState {
    mutating func sendGoAwayFrame(lastStreamID: HTTP2StreamID) -> (result: StateMachineResult, droppedStreams: [HTTP2StreamID]) {
        guard lastStreamID.mayBeInitiatedBy(self.peerRole) || lastStreamID == .rootStream else {
            // The user has sent a GOAWAY with an invalid stream ID.
            return (.connectionError(underlyingError: NIOHTTP2Errors.InvalidStreamIDForPeer(), type: .protocolError), [])
        }

        if lastStreamID > self.lastRemoteStreamID {
            // The user has attempted to raise the lastStreamID.
            return (.connectionError(underlyingError: NIOHTTP2Errors.RaisedGoawayLastStreamID(), type: .protocolError), [])
        }

        // Ok, this is a valid request, so we can now process it like .active.
        let droppedStreams = self.streamState.dropAllStreamsWithIDHigherThan(lastStreamID, droppedLocally: true, initiatedBy: self.peerRole)
        self.lastRemoteStreamID = lastStreamID
        return (.succeed, droppedStreams)
    }
}
