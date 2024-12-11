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

import NIOHPACK

/// A protocol implemented by HTTP/2 connection state machine states with remote settings.
///
/// This protocol provides implementations that can apply changes to the remote settings.
protocol HasRemoteSettings {
    var role: HTTP2ConnectionStateMachine.ConnectionRole { get }

    var remoteSettings: HTTP2SettingsState { get set }

    var streamState: ConnectionStreamState { get set }

    var outboundFlowControlWindow: HTTP2FlowControlWindow { get set }
}

extension HasRemoteExtendedConnectSettings where Self: HasRemoteSettings {
    var remoteSupportsExtendedConnect: Bool {
        self.remoteSettings.enableConnectProtocol == 1
    }
}

extension HasRemoteSettings {
    mutating func receiveSettingsChange(
        _ settings: HTTP2Settings,
        frameEncoder: inout HTTP2FrameEncoder
    ) -> (StateMachineResultWithEffect, PostFrameOperation) {
        // We do a little switcheroo here to avoid problems with overlapping accesses to
        // self. It's a little more complex than normal because HTTP2SettingsState has
        // two CoWable objects, and we don't want to CoW either of them, so we shove a dummy
        // value in `self` to avoid that.
        var temporarySettings = HTTP2SettingsState.dummyValue()
        swap(&temporarySettings, &self.remoteSettings)
        defer {
            swap(&temporarySettings, &self.remoteSettings)
        }

        var effect = NIOHTTP2ConnectionStateChange.RemoteSettingsChanged()

        do {
            try temporarySettings.receiveSettings(settings) { (setting, originalValue, newValue) in
                switch setting {
                case .maxConcurrentStreams:
                    if self.role == .client {
                        self.streamState.maxClientInitiatedStreams = newValue
                    } else {
                        self.streamState.maxServerInitiatedStreams = newValue
                    }
                    effect.newMaxConcurrentStreams = newValue
                case .headerTableSize:
                    try frameEncoder.headerEncoder.setDynamicTableSize(Int(newValue))
                case .initialWindowSize:
                    // We default the value of SETTINGS_INITIAL_WINDOW_SIZE, so originalValue mustn't be nil.
                    // The max value of SETTINGS_INITIAL_WINDOW_SIZE is Int32.max, so we can safely fit it into that here.
                    let delta = Int32(newValue) - Int32(originalValue!)

                    try self.streamState.forAllStreams {
                        try $0.remoteInitialWindowSizeChanged(by: delta)
                    }

                    // We do a += here because the value may change multiple times in one settings block. This way, we correctly
                    // respect that possibility.
                    effect.streamWindowSizeChange += Int(delta)
                case .maxFrameSize:
                    effect.newMaxFrameSize = newValue
                case .enableConnectProtocol:
                    // Must not transition from 1 -> 0
                    if originalValue == 1 && newValue == 0 {
                        throw NIOHTTP2Errors.invalidSetting(
                            setting: HTTP2Setting(parameter: setting, value: Int(newValue))
                        )
                    }
                    effect.enableConnectProtocol = newValue == 1
                default:
                    // No operation required
                    return
                }
            }
            return (.init(result: .succeed, effect: .remoteSettingsChanged(effect)), .sendAck)
        } catch let err where err is NIOHTTP2Errors.InvalidFlowControlWindowSize {
            return (
                .init(result: .connectionError(underlyingError: err, type: .flowControlError), effect: nil), .nothing
            )
        } catch let err where err is NIOHTTP2Errors.InvalidSetting {
            return (.init(result: .connectionError(underlyingError: err, type: .protocolError), effect: nil), .nothing)
        } catch {
            preconditionFailure("Unexpected error thrown: \(error)")
        }
    }
}
