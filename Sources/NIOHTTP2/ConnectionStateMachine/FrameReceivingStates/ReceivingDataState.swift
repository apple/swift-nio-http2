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

/// A protocol that provides implementation for receiving DATA frames, for those states that
/// can validly receive data.
///
/// This protocol should only be conformed to by states for the HTTP/2 connection state machine.
protocol ReceivingDataState {
    var streamState: ConnectionStreamState { get set }

    var inboundFlowControlWindow: HTTP2FlowControlWindow { get set }
}

extension ReceivingDataState {
    /// Called to receive a DATA frame.
    mutating func receiveData(streamID: HTTP2StreamID, flowControlledBytes: Int, isEndStreamSet endStream: Bool) -> StateMachineResult {
        do {
            try self.inboundFlowControlWindow.consume(flowControlledBytes: flowControlledBytes)
        } catch let error where error is NIOHTTP2Errors.FlowControlViolation {
            return .connectionError(underlyingError: error, type: .flowControlError)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }

        return self.streamState.modifyStreamState(streamID: streamID, ignoreRecentlyReset: true) {
            $0.receiveData(flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
        }
    }
}
