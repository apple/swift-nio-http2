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

/// A protocol implemented by HTTP/2 connection state machine states with remote settings.
///
/// This protocol provides implementations that can apply changes to the remote settings.
protocol HasRemoteSettings {
    var role: HTTP2ConnectionStateMachine.ConnectionRole { get }

    var remoteSettings: HTTP2SettingsState { get set }

    var streamState: ConnectionStreamState { get set }

    var outboundFlowControlWindow: HTTP2FlowControlWindow { get set }
}

extension HasRemoteSettings {
    mutating func receiveSettingsChange(_ settings: HTTP2Settings, frameDecoder: inout HTTP2FrameDecoder) -> (StateMachineResult, PostSettingsOperation) {
        // We do a little switcheroo here to avoid problems with overlapping accesses to
        // self. It's a little more complex than normal because HTTP2SettingsState has
        // two CoWable objects, and we don't want to CoW either of them, so we shove a dummy
        // value in `self` to avoid that.
        var temporarySettings = HTTP2SettingsState.dummyValue()
        swap(&temporarySettings, &self.remoteSettings)
        defer {
            swap(&temporarySettings, &self.remoteSettings)
        }

        do {
            try temporarySettings.receiveSettings(settings) { (setting, originalValue, newValue) in
                switch setting {
                case .maxConcurrentStreams:
                    if self.role == .client {
                        self.streamState.maxClientInitiatedStreams = newValue
                    } else {
                        self.streamState.maxServerInitiatedStreams = newValue
                    }
                case .headerTableSize:
                    frameDecoder.headerDecoder.maxDynamicTableLength = Int(newValue)
                case .initialWindowSize:
                    // We default the value of SETTINGS_INITIAL_WINDOW_SIZE, so originalValue mustn't be nil.
                    // The max value of SETTINGS_INITIAL_WINDOW_SIZE is Int32.max, so we can safely fit it into that here.
                    let delta = Int32(newValue) - Int32(originalValue!)

                    try self.streamState.forAllStreams {
                        try $0.remoteInitialWindowSizeChanged(by: delta)
                    }
                case .maxFrameSize:
                    // TODO(cory): Implement!
                    break
                default:
                    // No operation required
                    return
                }
            }
            return (.succeed, .sendAck)
        } catch let err where err is NIOHTTP2Errors.InvalidFlowControlWindowSize {
            return (.connectionError(underlyingError: err, type: .flowControlError), .nothing)
        } catch {
            preconditionFailure("Unexpected error thrown: \(error)")
        }
    }
}
