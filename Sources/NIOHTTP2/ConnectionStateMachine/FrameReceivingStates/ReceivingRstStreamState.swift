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

/// A protocol that provides implementation for receiving RST_STREAM frames, for those states that
/// can validly receive such frames.
///
/// This protocol should only be conformed to by states for the HTTP/2 connection state machine.
protocol ReceivingRstStreamState {
    var streamState: ConnectionStreamState { get set }
}

extension ReceivingRstStreamState {
    /// Called to receive a RST_STREAM frame.
    mutating func receiveRstStream(streamID: HTTP2StreamID) -> (StateMachineResult, ConnectionStreamState.StreamStateChange) {
        return self.streamState.modifyStreamState(streamID: streamID, ignoreRecentlyReset: true) {
            $0.receiveRstStream()
        }
    }
}
