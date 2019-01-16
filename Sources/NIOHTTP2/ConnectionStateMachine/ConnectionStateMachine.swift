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
import NIO
import NIOHPACK

/// A state machine that governs the connection-level state of a HTTP/2 connection.
///
/// ### Overview
///
/// A HTTP/2 protocol implementation is fundamentally built on a pair of interlocking state machines:
/// one for the connection as a whole, and then one for each stream on the connection. All frames sent
/// and received on a HTTP/2 connection cause state transitions in either or both of these state
/// machines, and the set of valid state transitions in these state machines forms the complete set of
/// valid frame sequences in HTTP/2.
///
/// Not all frames need to pass through both state machines. As a general heuristic, if a frame carries a
/// stream ID field, it must pass through both the connection state machine and the stream state machine for
/// the associated stream. If it does not, then it must only pass through the connection state machine. This
/// is not a *complete* description of the way the connection behaves (see the note about PRIORITY frames
/// below), but it's a good enough operating heuristic to get through the rest of the code.
///
/// The stream state machine is handled by `HTTP2StreamStateMachine`.
///
/// ### Function
///
/// The responsibilities of this state machine are as follows:
///
/// 1) Manage the connection setup process, ensuring that the approriate client/server preamble is sent and
///     received.
/// 2) Manage the inbound and outbound connection flow control windows.
/// 3) Keep track of the bi-directional values of HTTP/2 settings.
/// 4) Manage connection cleanup, shutdown, and quiescing.
///
/// ### Implementation
///
/// All state associated with a HTTP/2 connection lives inside a single Swift enum. This enum constrains when
/// state is available, ensuring that it is not possible to query data that is not meaningful in the given state.
/// Operations on this state machine occur by calling specific functions on the structure, which will spin the
/// enum as needed and perform whatever state transitions are required.
///
/// #### PRIORITY frames
///
/// A brief digression is required on HTTP/2 PRIORITY frames. These frames appear to be sent "on" a specific
/// stream, as they carry a stream ID like all other stream-specific frames. However, unlike all other stream
/// specific frames they can be sent for streams in *any* state (including idle and fullyQuiesced, meaning they can
/// be sent for streams that have never existed or that passed away long ago), and have no effect on the stream
/// state (causing no state transitions). They only ever affect the priority tree, which neither this object nor
/// any of the streams actually maintains.
///
/// For this reason, PRIORITY frames do not actually participate in the stream state machine: only the
/// connection one. This is unlike all other frames that carry stream IDs. Essentially, they are connection-scoped
/// frames that just incidentally have a stream ID on them, rather than stream-scoped frames like all the others.
struct HTTP2ConnectionStateMachine {
    /// The state required for a connection that is currently idle.
    private struct IdleConnectionState: ConnectionStateWithRole {
        let role: ConnectionRole
    }

    /// The state required for a connection that has sent a connection preface.
    private struct PrefaceSentState: ConnectionStateWithRole, MaySendFrames, HasLocalSettings {
        let role: ConnectionRole
        var localSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow

        var localInitialWindowSize: UInt32 {
            return HTTP2SettingsState.defaultInitialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return self.localSettings.initialWindowSize
        }

        init(fromIdle idleState: IdleConnectionState, localSettings settings: HTTP2SettingsState) {
            self.role = idleState.role
            self.localSettings = settings
            self.streamState = ConnectionStreamState()

            self.inboundFlowControlWindow = HTTP2FlowControlWindow(initialValue: settings.initialWindowSize)
            self.outboundFlowControlWindow = HTTP2FlowControlWindow(initialValue: HTTP2SettingsState.defaultInitialWindowSize)
        }
    }

    /// The state required for a connection that has received a connection preface.
    private struct PrefaceReceivedState: ConnectionStateWithRole, MayReceiveFrames, HasRemoteSettings {
        let role: ConnectionRole
        var remoteSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow

        var localInitialWindowSize: UInt32 {
            return self.remoteSettings.initialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return HTTP2SettingsState.defaultInitialWindowSize
        }

        init(fromIdle idleState: IdleConnectionState, remoteSettings settings: HTTP2SettingsState) {
            self.role = idleState.role
            self.remoteSettings = settings
            self.streamState = ConnectionStreamState()

            self.inboundFlowControlWindow = HTTP2FlowControlWindow(initialValue: HTTP2SettingsState.defaultInitialWindowSize)
            self.outboundFlowControlWindow = HTTP2FlowControlWindow(initialValue: settings.initialWindowSize)
        }
    }

    /// The state required for a connection that is active.
    private struct ActiveConnectionState: ConnectionStateWithRole, MaySendFrames, MayReceiveFrames, HasLocalSettings, HasRemoteSettings {
        let role: ConnectionRole
        var localSettings: HTTP2SettingsState
        var remoteSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow

        var localInitialWindowSize: UInt32 {
            return self.remoteSettings.initialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return self.localSettings.initialWindowSize
        }

        init(fromPrefaceReceived state: PrefaceReceivedState, localSettings settings: HTTP2SettingsState) {
            self.role = state.role
            self.remoteSettings = state.remoteSettings
            self.streamState = state.streamState
            self.localSettings = settings

            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
        }

        init(fromPrefaceSent state: PrefaceSentState, remoteSettings settings: HTTP2SettingsState) {
            self.role = state.role
            self.localSettings = state.localSettings
            self.streamState = state.streamState
            self.remoteSettings = settings

            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
        }
    }

    /// The state required for a connection that is quiescing, but where the local peer has not yet sent its
    /// preface.
    private struct QuiescingPrefaceReceivedState: ConnectionStateWithRole, RemotelyQuiescingState, MayReceiveFrames, HasRemoteSettings {
        let role: ConnectionRole
        var remoteSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow

        var lastLocalStreamID: HTTP2StreamID

        var localInitialWindowSize: UInt32 {
            return self.remoteSettings.initialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return HTTP2SettingsState.defaultInitialWindowSize
        }

        var quiescedByServer: Bool {
            return self.role == .client
        }

        init(fromPrefaceReceived state: PrefaceReceivedState, lastStreamID: HTTP2StreamID) {
            self.role = state.role
            self.remoteSettings = state.remoteSettings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow

            self.lastLocalStreamID = lastStreamID
        }
    }

    /// The state required for a connection that is quiescing, but where the remote peer has not yet sent its
    /// preface.
    private struct QuiescingPrefaceSentState: ConnectionStateWithRole, LocallyQuiescingState, MaySendFrames, HasLocalSettings {
        let role: ConnectionRole
        var localSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow

        var lastRemoteStreamID: HTTP2StreamID

        var localInitialWindowSize: UInt32 {
            return HTTP2SettingsState.defaultInitialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return self.localSettings.initialWindowSize
        }

        var quiescedByServer: Bool {
            return self.role == .server
        }

        init(fromPrefaceSent state: PrefaceSentState, lastStreamID: HTTP2StreamID) {
            self.role = state.role
            self.localSettings = state.localSettings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow

            self.lastRemoteStreamID = lastStreamID
        }
    }

    /// The state required for a connection that is quiescing due to the remote peer quiescing the connection.
    private struct RemotelyQuiescedState: ConnectionStateWithRole, RemotelyQuiescingState, MayReceiveFrames, MaySendFrames, HasLocalSettings, HasRemoteSettings {
        let role: ConnectionRole
        var localSettings: HTTP2SettingsState
        var remoteSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow

        var lastLocalStreamID: HTTP2StreamID

        var localInitialWindowSize: UInt32 {
            return self.remoteSettings.initialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return self.localSettings.initialWindowSize
        }

        var quiescedByServer: Bool {
            return self.role == .client
        }

        init(fromActive state: ActiveConnectionState, lastLocalStreamID streamID: HTTP2StreamID) {
            self.role = state.role
            self.localSettings = state.localSettings
            self.remoteSettings = state.remoteSettings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.lastLocalStreamID = streamID
        }

        init(fromQuiescingPrefaceReceived state: QuiescingPrefaceReceivedState, localSettings settings: HTTP2SettingsState) {
            self.role = state.role
            self.remoteSettings = state.remoteSettings
            self.localSettings = settings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.lastLocalStreamID = state.lastLocalStreamID
        }
    }

    /// The state required for a connection that is quiescing due to the local user quiescing the connection.
    private struct LocallyQuiescedState: ConnectionStateWithRole, LocallyQuiescingState, MaySendFrames, MayReceiveFrames, HasLocalSettings, HasRemoteSettings {
        let role: ConnectionRole
        var localSettings: HTTP2SettingsState
        var remoteSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow

        var lastRemoteStreamID: HTTP2StreamID

        var localInitialWindowSize: UInt32 {
            return self.remoteSettings.initialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return self.localSettings.initialWindowSize
        }

        var quiescedByServer: Bool {
            return self.role == .server
        }

        init(fromActive state: ActiveConnectionState, lastRemoteStreamID streamID: HTTP2StreamID) {
            self.role = state.role
            self.localSettings = state.localSettings
            self.remoteSettings = state.remoteSettings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.lastRemoteStreamID = streamID
        }

        init(fromQuiescingPrefaceSent state: QuiescingPrefaceSentState, remoteSettings settings: HTTP2SettingsState) {
            self.role = state.role
            self.localSettings = state.localSettings
            self.remoteSettings = settings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.lastRemoteStreamID = state.lastRemoteStreamID
        }
    }

    /// The state required for a connection that is quiescing due to both peers sending GOAWAY.
    private struct BothQuiescingState: ConnectionStateWithRole, LocallyQuiescingState, RemotelyQuiescingState, MaySendFrames, MayReceiveFrames, HasLocalSettings, HasRemoteSettings {
        let role: ConnectionRole
        var localSettings: HTTP2SettingsState
        var remoteSettings: HTTP2SettingsState
        var streamState: ConnectionStreamState
        var inboundFlowControlWindow: HTTP2FlowControlWindow
        var outboundFlowControlWindow: HTTP2FlowControlWindow
        var lastLocalStreamID: HTTP2StreamID
        var lastRemoteStreamID: HTTP2StreamID

        var localInitialWindowSize: UInt32 {
            return self.remoteSettings.initialWindowSize
        }

        var remoteInitialWindowSize: UInt32 {
            return self.localSettings.initialWindowSize
        }

        var quiescedByServer: Bool {
            return true
        }

        init(fromRemotelyQuiesced state: RemotelyQuiescedState, lastRemoteStreamID streamID: HTTP2StreamID) {
            self.role = state.role
            self.localSettings = state.localSettings
            self.remoteSettings = state.remoteSettings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.lastLocalStreamID = state.lastLocalStreamID

            self.lastRemoteStreamID = streamID
        }

        init(fromLocallyQuiesced state: LocallyQuiescedState, lastLocalStreamID streamID: HTTP2StreamID) {
            self.role = state.role
            self.localSettings = state.localSettings
            self.remoteSettings = state.remoteSettings
            self.streamState = state.streamState
            self.inboundFlowControlWindow = state.inboundFlowControlWindow
            self.outboundFlowControlWindow = state.outboundFlowControlWindow
            self.lastRemoteStreamID = state.lastRemoteStreamID

            self.lastLocalStreamID = streamID
        }
    }

    private enum State {
        /// The connection has not begun yet. This state is usually used while the underlying transport connection
        /// is being established. No data can be sent or received at this time.
        case idle(IdleConnectionState)

        /// Our preface has been sent, and we are awaiting the preface from the remote peer. In general we're more
        /// likely to enter this state as a client than a server, but users may choose to reduce latency by
        /// aggressively emitting the server preface before the client preface has been received. In either case,
        /// in this state we are waiting for the remote peer to send its preface.
        case prefaceSent(PrefaceSentState)

        /// We have received a preface from the remote peer, and we are waiting to send our own preface. In general
        /// we're more likely to enter this state as a server than as a client, but remote peers may be attempting
        /// to reduce latency by aggressively emitting the server preface before they have received our preface.
        /// In either case, in this state we are waiting for the local user to emit the preface.
        case prefaceReceived(PrefaceReceivedState)

        /// Both peers have exchanged their preface and the connection is fully active. In this state new streams
        /// may be created, potentially by either peer, and the connection is fully useable.
        case active(ActiveConnectionState)

        /// The remote peer has sent a GOAWAY frame that quiesces the connection, preventing the creation of new
        /// streams. However, there are still active streams that have been allowed to complete, so the connection
        /// is not entirely inactive.
        case remotelyQuiesced(RemotelyQuiescedState)

        /// The local user has sent a GOAWAY frame that quiesces the connection, preventing the creation of new
        /// streams. However, there are still active streams that have been allowed to complete, so the connection
        /// is not entirely inactive.
        case locallyQuiesced(LocallyQuiescedState)

        /// Both peers have emitted a GOAWAY frame that quiesces the connection, preventing the creation of new
        /// streams. However, there are still active streams that have been allowed to complete, so the connection
        /// is not entirely inactive.
        case bothQuiescing(BothQuiescingState)

        /// We have sent our preface, and sent a GOAWAY, but we haven't received the remote preface yet.
        /// This is a weird state, unlikely to be encountered in most programs, but it's technically possible.
        case quiescingPrefaceSent(QuiescingPrefaceSentState)

        /// We have received a preface, and received a GOAWAY, but we haven't sent our preface yet.
        /// This is a weird state, unlikely to be encountered in most programs, but it's technically possible.
        case quiescingPrefaceReceived(QuiescingPrefaceReceivedState)

        /// The connection has completed, either cleanly or with an error. In this state, no further activity may
        /// occur on the connection.
        case fullyQuiesced
    }

    /// The possible roles an endpoint may play in a connection.
    enum ConnectionRole {
        case server
        case client
    }

    private var state: State

    init(role: ConnectionRole) {
        self.state = .idle(.init(role: role))
    }

    /// Whether this connection is closed.
    var fullyQuiesced: Bool {
        switch self.state {
        case .fullyQuiesced:
            return true
        default:
            return false
        }
    }
}

// MARK:- State modifying methods
//
// These methods form the implementation of the public API of the HTTP2ConnectionStateMachine. Each of these methods
// performs a state transition, and can be used to validate that a specific action is acceptable on a connection in this state.
extension HTTP2ConnectionStateMachine {
    /// Called when a SETTINGS frame has been received from the remote peer
    mutating func receiveSettings(_ settings: HTTP2Settings, flags: HTTP2Frame.FrameFlags) -> StateMachineResult {
        if flags.contains(.ack) {
            return self.receiveSettingsAck()
        } else {
            return self.receiveSettingsChange(settings)
        }
    }

    /// Called when the user has sent a settings update.
    ///
    /// Note that this function assumes that this is not a settings ACK, as settings ACK frames are not
    /// allowed to be sent by the user. They are always emitted by the implementation.
    mutating func sendSettings(_ settings: HTTP2Settings) -> StateMachineResult {
        let validationResult = self.validateSettings(settings)

        guard case .succeed = validationResult else {
            return validationResult
        }

        switch self.state {
        case .idle(let state):
            var settingsState = HTTP2SettingsState(localState: true)
            settingsState.emitSettings(settings)
            self.state = .prefaceSent(.init(fromIdle: state, localSettings: settingsState))

        case .prefaceReceived(let state):
            var settingsState = HTTP2SettingsState(localState: true)
            settingsState.emitSettings(settings)
            self.state = .active(.init(fromPrefaceReceived: state, localSettings: settingsState))

        case .prefaceSent(var state):
            state.localSettings.emitSettings(settings)
            self.state = .prefaceSent(state)

        case .active(var state):
            state.localSettings.emitSettings(settings)
            self.state = .active(state)

        case .quiescingPrefaceSent(var state):
            state.localSettings.emitSettings(settings)
            self.state = .quiescingPrefaceSent(state)

        case .quiescingPrefaceReceived(let state):
            var settingsState = HTTP2SettingsState(localState: true)
            settingsState.emitSettings(settings)
            self.state = .remotelyQuiesced(.init(fromQuiescingPrefaceReceived: state, localSettings: settingsState))

        case .remotelyQuiesced(var state):
            state.localSettings.emitSettings(settings)
            self.state = .remotelyQuiesced(state)

        case .locallyQuiesced(var state):
            state.localSettings.emitSettings(settings)
            self.state = .locallyQuiesced(state)

        case .bothQuiescing(var state):
            state.localSettings.emitSettings(settings)
            self.state = .bothQuiescing(state)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }

        return .succeed
    }

    /// Called when a HEADERS frame has been received from the remote peer.
    mutating func receiveHeaders(streamID: HTTP2StreamID, headers: HPACKHeaders, isEndStreamSet endStream: Bool) -> StateMachineResult {
        switch self.state {
        case .prefaceReceived(var state):
            let result = state.receiveHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .prefaceReceived(state)
            return result

        case .active(var state):
            let result = state.receiveHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.receiveHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .locallyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.receiveHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .remotelyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .bothQuiescing(var state):
            let result = state.receiveHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceReceived(var state):
            let result = state.receiveHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .quiescingPrefaceReceived(state)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            // If we're still waiting for the remote preface, they are not allowed to send us a HEADERS frame yet!
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    // Called when a HEADERS frame has been sent by the local user.
    mutating func sendHeaders(streamID: HTTP2StreamID, headers: HPACKHeaders, isEndStreamSet endStream: Bool) -> StateMachineResult {
        switch self.state {
        case .prefaceSent(var state):
            let result = state.sendHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .prefaceSent(state)
            return result

        case .active(var state):
            let result = state.sendHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.sendHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .locallyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.sendHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .remotelyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .bothQuiescing(var state):
            let result = state.sendHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceSent(var state):
            let result = state.sendHeaders(streamID: streamID, headers: headers, isEndStreamSet: endStream)
            self.state = .quiescingPrefaceSent(state)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            // If we're still waiting for the local preface, we are not allowed to send a HEADERS frame yet!
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when a DATA frame has been received.
    mutating func receiveData(streamID: HTTP2StreamID, flowControlledBytes: Int, isEndStreamSet endStream: Bool) -> StateMachineResult {
        switch self.state {
        case .prefaceReceived(var state):
            let result = state.receiveData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .prefaceReceived(state)
            return result

        case .active(var state):
            let result = state.receiveData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.receiveData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .locallyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.receiveData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .remotelyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .bothQuiescing(var state):
            let result = state.receiveData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceReceived(var state):
            let result = state.receiveData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .quiescingPrefaceReceived(state)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            // If we're still waiting for the remote preface, we are not allowed to receive a DATA frame yet!
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when a user is trying to send a DATA frame.
    mutating func sendData(streamID: HTTP2StreamID, flowControlledBytes: Int, isEndStreamSet endStream: Bool) -> StateMachineResult {
        switch self.state {
        case .prefaceSent(var state):
            let result = state.sendData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .prefaceSent(state)
            return result

        case .active(var state):
            let result = state.sendData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.sendData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .locallyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.sendData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .remotelyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .bothQuiescing(var state):
            let result = state.sendData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceSent(var state):
            let result = state.sendData(streamID: streamID, flowControlledBytes: flowControlledBytes, isEndStreamSet: endStream)
            self.state = .quiescingPrefaceSent(state)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            // If we're still waiting for the local preface, we are not allowed to send a DATA frame yet!
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    func receivePriority() -> StateMachineResult {
        // So long as we've received the preamble and haven't fullyQuiesced, a PRIORITY frame is basically always
        // an acceptable thing to receive. The only rule is that it mustn't form a cycle in the priority
        // tree, but we don't maintain enough state in this object to enforce that.
        switch self.state {
        case .prefaceReceived, .active, .locallyQuiesced, .remotelyQuiesced, .bothQuiescing, .quiescingPrefaceReceived:
            return .succeed

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    func sendPriority() -> StateMachineResult {
        // So long as we've sent the preamble and haven't fullyQuiesced, a PRIORITY frame is basically always
        // an acceptable thing to send. The only rule is that it mustn't form a cycle in the priority
        // tree, but we don't maintain enough state in this object to enforce that.
        switch self.state {
        case .prefaceSent, .active, .locallyQuiesced, .remotelyQuiesced, .bothQuiescing, .quiescingPrefaceSent:
            return .succeed

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when a RST_STREAM frame has been received.
    mutating func receiveRstStream(streamID: HTTP2StreamID) -> StateMachineResult {
        switch self.state {
        case .prefaceReceived(var state):
            let result = state.receiveRstStream(streamID: streamID)
            self.state = .prefaceReceived(state)
            return result

        case .active(var state):
            let result = state.receiveRstStream(streamID: streamID)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.receiveRstStream(streamID: streamID)
            self.state = .locallyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.receiveRstStream(streamID: streamID)
            self.state = .remotelyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .bothQuiescing(var state):
            let result = state.receiveRstStream(streamID: streamID)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceReceived(var state):
            let result = state.receiveRstStream(streamID: streamID)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            // We're waiting for the remote preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when sending a RST_STREAM frame.
    mutating func sendRstStream(streamID: HTTP2StreamID) -> StateMachineResult {
        switch self.state {
        case .prefaceSent(var state):
            let result = state.sendRstStream(streamID: streamID)
            self.state = .prefaceSent(state)
            return result

        case .active(var state):
            let result = state.sendRstStream(streamID: streamID)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.sendRstStream(streamID: streamID)
            self.state = .locallyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.sendRstStream(streamID: streamID)
            self.state = .remotelyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .bothQuiescing(var state):
            let result = state.sendRstStream(streamID: streamID)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceSent(var state):
            let result = state.sendRstStream(streamID: streamID)
            self.state = .quiescingPrefaceSent(state)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            // We're waiting for the local preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when a PUSH_PROMISE frame has been initiated on a given stream.
    ///
    /// If this method returns a stream error, the stream error should be assumed to apply to both the original
    /// and child stream.
    mutating func receivePushPromise(originalStreamID: HTTP2StreamID, childStreamID: HTTP2StreamID, headers: HPACKHeaders) -> StateMachineResult {
        // In states that support a push promise we have two steps. Firstly, we want to create the child stream; then we want to
        // pass the PUSH_PROMISE frame through the stream state machine for the parent stream.
        //
        // The reason we do things in this order is that if for any reason the PUSH_PROMISE frame is invalid on the parent stream,
        // we want to take out both the child stream and the parent stream. We can only do that if we have a child stream state to
        // modify. For this reason, we unconditionally allow the remote peer to consume the stream. The only case where this is *not*
        // true is when the child stream itself cannot be validly created, because the stream ID used by the remote peer is invalid.
        // In this case this is a connection error, anyway, so we don't worry too much about it.
        switch self.state {
        case .prefaceReceived(var state):
            let result = state.receivePushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .prefaceReceived(state)
            return result

        case .active(var state):
            let result = state.receivePushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.receivePushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .locallyQuiesced(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.receivePushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .remotelyQuiesced(state)
            return result

        case .bothQuiescing(var state):
            let result = state.receivePushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .bothQuiescing(state)
            return result

        case .quiescingPrefaceReceived(var state):
            let result = state.receivePushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .quiescingPrefaceReceived(state)
            return result

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            // We're waiting for the remote preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    mutating func sendPushPromise(originalStreamID: HTTP2StreamID, childStreamID: HTTP2StreamID, headers: HPACKHeaders) -> StateMachineResult {
        switch self.state {
        case .prefaceSent(var state):
            let result = state.sendPushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .prefaceSent(state)
            return result

        case .active(var state):
            let result = state.sendPushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.sendPushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .locallyQuiesced(state)
            return result

        case .remotelyQuiesced, .bothQuiescing:
            // We have been quiesced, and may not create new streams.
            return .connectionError(underlyingError: NIOHTTP2Errors.CreatedStreamAfterGoaway(), type: .protocolError)

        case .quiescingPrefaceSent(var state):
            let result = state.sendPushPromise(originalStreamID: originalStreamID, childStreamID: childStreamID, headers: headers)
            self.state = .quiescingPrefaceSent(state)
            return result

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            // We're waiting for the local preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when a PING frame has been received from the network.
    mutating func receivePing() -> StateMachineResult {
        // Pings are pretty straightforward: they're basically always allowed. This is a bit weird, but I can find no text in
        // RFC 7540 that says that receiving PINGs with ACK flags set when no PING ACKs are expected is forbidden. This is
        // very strange, but we allow it.
        switch self.state {
        case .prefaceReceived, .active, .locallyQuiesced, .remotelyQuiesced, .bothQuiescing, .quiescingPrefaceReceived:
            return .succeed

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            // We're waiting for the remote preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when a PING frame is about to be sent.
    mutating func sendPing() -> StateMachineResult {
        // Pings are pretty straightforward: they're basically always allowed. This is a bit weird, but I can find no text in
        // RFC 7540 that says that sending PINGs with ACK flags set when no PING ACKs are expected is forbidden. This is
        // very strange, but we allow it.
        switch self.state {
        case .prefaceSent, .active, .locallyQuiesced, .remotelyQuiesced, .bothQuiescing, .quiescingPrefaceSent:
            return .succeed

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            // We're waiting for the local preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }


    /// Called when we receive a GOAWAY frame.
    mutating func receiveGoaway(lastStreamID: HTTP2StreamID) -> (result: StateMachineResult, droppedStreams: [HTTP2StreamID]) {
        // GOAWAY frames are some of the most subtle frames in HTTP/2, they cause a number of state transitions all at once.
        // In particular, the value of lastStreamID heavily affects the state transitions we perform here.
        // In this case, all streams initiated by us that have stream IDs higher than lastStreamID will be closed, effective
        // immediately. If this leaves us with zero streams, the connection is fullyQuiesced. Otherwise, we are quiescing.
        switch self.state {
        case .prefaceReceived(var state):
            let result = state.receiveGoAwayFrame(lastStreamID: lastStreamID)
            let newState = QuiescingPrefaceReceivedState(fromPrefaceReceived: state, lastStreamID: lastStreamID)
            self.state = .quiescingPrefaceReceived(newState)
            self.closeIfNeeded(newState)
            return result

        case .active(var state):
            let result = state.receiveGoAwayFrame(lastStreamID: lastStreamID)
            let newState = RemotelyQuiescedState(fromActive: state, lastLocalStreamID: lastStreamID)
            self.state = .remotelyQuiesced(newState)
            self.closeIfNeeded(newState)
            return result

        case .locallyQuiesced(var state):
            let result = state.receiveGoAwayFrame(lastStreamID: lastStreamID)
            let newState = BothQuiescingState(fromLocallyQuiesced: state, lastLocalStreamID: lastStreamID)
            self.state = .bothQuiescing(newState)
            self.closeIfNeeded(newState)
            return result

        case .remotelyQuiesced(var state):
            let result = state.receiveGoAwayFrame(lastStreamID: lastStreamID)
            self.state = .remotelyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .bothQuiescing(var state):
            let result = state.receiveGoAwayFrame(lastStreamID: lastStreamID)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceReceived(var state):
            let result = state.receiveGoAwayFrame(lastStreamID: lastStreamID)
            self.state = .quiescingPrefaceReceived(state)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            // We're waiting for the preface.
            return (.connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError), [])

        case .fullyQuiesced:
            // We allow duplicate GOAWAY here. The connection is fullyQuiesced anyway, so we just ignore the frame.
            return (.ignoreFrame, [])
        }
    }

    /// Called when the user attempts to send a GOAWAY frame.
    mutating func sendGoaway(lastStreamID: HTTP2StreamID) -> (result: StateMachineResult, droppedStreams: [HTTP2StreamID]) {
        // GOAWAY frames are some of the most subtle frames in HTTP/2, they cause a number of state transitions all at once.
        // In particular, the value of lastStreamID heavily affects the state transitions we perform here.
        // In this case, all streams initiated by us that have stream IDs higher than lastStreamID will be closed, effective
        // immediately. If this leaves us with zero streams, the connection is fullyQuiesced. Otherwise, we are quiescing.
        switch self.state {
        case .prefaceSent(var state):
            let result = state.sendGoAwayFrame(lastStreamID: lastStreamID)
            let newState = QuiescingPrefaceSentState(fromPrefaceSent: state, lastStreamID: lastStreamID)
            self.state = .quiescingPrefaceSent(newState)
            self.closeIfNeeded(newState)
            return result

        case .active(var state):
            let result = state.sendGoAwayFrame(lastStreamID: lastStreamID)
            let newState = LocallyQuiescedState(fromActive: state, lastRemoteStreamID: lastStreamID)
            self.state = .locallyQuiesced(newState)
            self.closeIfNeeded(newState)
            return result

        case .locallyQuiesced(var state):
            let result = state.sendGoAwayFrame(lastStreamID: lastStreamID)
            self.state = .locallyQuiesced(state)
            self.closeIfNeeded(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.sendGoAwayFrame(lastStreamID: lastStreamID)
            let newState = BothQuiescingState(fromRemotelyQuiesced: state, lastRemoteStreamID: lastStreamID)
            self.state = .bothQuiescing(newState)
            self.closeIfNeeded(newState)
            return result

        case .bothQuiescing(var state):
            let result = state.sendGoAwayFrame(lastStreamID: lastStreamID)
            self.state = .bothQuiescing(state)
            self.closeIfNeeded(state)
            return result

        case .quiescingPrefaceSent(var state):
            let result = state.sendGoAwayFrame(lastStreamID: lastStreamID)
            self.state = .quiescingPrefaceSent(state)
            self.closeIfNeeded(state)
            return result

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            // We're waiting for the preface.
            return (.connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError), [])

        case .fullyQuiesced:
            // We allow duplicate GOAWAY here. The connection is fullyQuiesced anyway, so we just ignore the frame.
            return (.ignoreFrame, [])
        }
    }

    /// Called when a WINDOW_UPDATE frame has been received.
    mutating func receiveWindowUpdate(streamID: HTTP2StreamID, windowIncrement: UInt32) -> StateMachineResult {
        switch self.state {
        case .prefaceReceived(var state):
            let result = state.receiveWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .prefaceReceived(state)
            return result

        case .active(var state):
            let result = state.receiveWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .active(state)
            return result

        case .quiescingPrefaceReceived(var state):
            let result = state.receiveWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .quiescingPrefaceReceived(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.receiveWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .locallyQuiesced(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.receiveWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .remotelyQuiesced(state)
            return result

        case .bothQuiescing(var state):
            let result = state.receiveWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .bothQuiescing(state)
            return result

        case .idle, .prefaceSent, .quiescingPrefaceSent:
            // We're waiting for the preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Called when a WINDOW_UPDATE frame is sent.
    mutating func sendWindowUpdate(streamID: HTTP2StreamID, windowIncrement: UInt32) -> StateMachineResult {
        switch self.state {
        case .prefaceSent(var state):
            let result = state.sendWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .prefaceSent(state)
            return result

        case .active(var state):
            let result = state.sendWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .active(state)
            return result

        case .quiescingPrefaceSent(var state):
            let result = state.sendWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .quiescingPrefaceSent(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.sendWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .locallyQuiesced(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.sendWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .remotelyQuiesced(state)
            return result

        case .bothQuiescing(var state):
            let result = state.sendWindowUpdate(streamID: streamID, increment: windowIncrement)
            self.state = .bothQuiescing(state)
            return result

        case .idle, .prefaceReceived, .quiescingPrefaceReceived:
            // We're waiting for the preface.
            return .connectionError(underlyingError: NIOHTTP2Errors.MissingPreface(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }
}

// Mark:- Private helper methods
extension HTTP2ConnectionStateMachine {
    /// Called when we have received a SETTINGS frame from the remote peer. Applies the changes immediately.
    private mutating func receiveSettingsChange(_ settings: HTTP2Settings) -> StateMachineResult {
        let validationResult = self.validateSettings(settings)

        guard case .succeed = validationResult else {
            return validationResult
        }

        let result: StateMachineResult

        switch self.state {
        case .idle(let state):
            var newState = PrefaceReceivedState(fromIdle: state, remoteSettings: HTTP2SettingsState(localState: false))
            result = newState.receiveSettingsChange(settings)
            self.state = .prefaceReceived(newState)

        case .prefaceSent(let state):
            var newState = ActiveConnectionState(fromPrefaceSent: state, remoteSettings: HTTP2SettingsState(localState: false))
            result = newState.receiveSettingsChange(settings)
            self.state = .active(newState)

        case .prefaceReceived(var state):
            result = state.receiveSettingsChange(settings)
            self.state = .prefaceReceived(state)

        case .active(var state):
            result = state.receiveSettingsChange(settings)
            self.state = .active(state)

        case .remotelyQuiesced(var state):
            result = state.receiveSettingsChange(settings)
            self.state = .remotelyQuiesced(state)

        case .locallyQuiesced(var state):
            result = state.receiveSettingsChange(settings)
            self.state = .locallyQuiesced(state)

        case .bothQuiescing(var state):
            result = state.receiveSettingsChange(settings)
            self.state = .bothQuiescing(state)

        case .quiescingPrefaceSent(let state):
            var newState = LocallyQuiescedState(fromQuiescingPrefaceSent: state, remoteSettings: HTTP2SettingsState(localState: false))
            result = newState.receiveSettingsChange(settings)
            self.state = .locallyQuiesced(newState)

        case .quiescingPrefaceReceived(var state):
            result = state.receiveSettingsChange(settings)
            self.state = .quiescingPrefaceReceived(state)

        case .fullyQuiesced:
            result = .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }

        return result
    }

    private mutating func receiveSettingsAck() -> StateMachineResult {
        // We can only receive a SETTINGS ACK after we've sent our own preface *and* the remote peer has
        // sent its own. That means we have to be active or quiescing.
        switch self.state {
        case .active(var state):
            let result = state.receiveSettingsAck()
            self.state = .active(state)
            return result

        case .locallyQuiesced(var state):
            let result = state.receiveSettingsAck()
            self.state = .locallyQuiesced(state)
            return result

        case .remotelyQuiesced(var state):
            let result = state.receiveSettingsAck()
            self.state = .remotelyQuiesced(state)
            return result

        case .bothQuiescing(var state):
            let result = state.receiveSettingsAck()
            self.state = .bothQuiescing(state)
            return result

        case .idle, .prefaceSent, .prefaceReceived, .quiescingPrefaceReceived, .quiescingPrefaceSent:
            return .connectionError(underlyingError: NIOHTTP2Errors.ReceivedBadSettings(), type: .protocolError)

        case .fullyQuiesced:
            return .connectionError(underlyingError: NIOHTTP2Errors.IOOnClosedConnection(), type: .protocolError)
        }
    }

    /// Validates a single HTTP/2 settings block.
    ///
    /// - parameters:
    ///     - settings: The HTTP/2 settings block to validate.
    /// - returns: The result of the validation.
    private func validateSettings(_ settings: HTTP2Settings) -> StateMachineResult {
        for setting in settings {
            switch setting.parameter {
            case .enablePush:
                guard setting._value == 0 || setting._value == 1 else {
                    return .connectionError(underlyingError: NIOHTTP2Errors.InvalidSetting(setting: setting), type: .protocolError)
                }
            case .initialWindowSize:
                guard setting._value < HTTP2FlowControlWindow.maxSize else {
                    return .connectionError(underlyingError: NIOHTTP2Errors.InvalidSetting(setting: setting), type: .flowControlError)
                }
            case .maxFrameSize:
                guard setting._value >= (1 << 14) && setting._value < ((1 << 24) - 1) else {
                    return .connectionError(underlyingError: NIOHTTP2Errors.InvalidSetting(setting: setting), type: .protocolError)
                }
            default:
                // All other settings have unrestricted ranges.
                break
            }
        }

        return .succeed
    }

    // Sets the connection state to fullyQuiesced if necessary.
    //
    // We should only call this when a server has quiesced the connection. As long as only the client has quiesced the
    // connection more work can always be done.
    private mutating func closeIfNeeded<State: QuiescingState>(_ state: State) {
        if state.quiescedByServer && state.streamState.openStreams == 0 {
            self.state = .fullyQuiesced
        }
    }
}


extension HTTP2StreamID {
    /// Confirms that this kind of stream ID may be initiated by a peer in the specific role.
    ///
    /// RFC 7540 limits odd stream IDs to being initiated by clients, and even stream IDs to
    /// being initiated by servers. This method confirms this.
    func mayBeInitiatedBy(_ role: HTTP2ConnectionStateMachine.ConnectionRole) -> Bool {
        // TODO(cory): We force unwrap in here because we want to be working in a brave new world
        // where we never have these weird unspecified stream IDs. We'll come back and fix this
        // later.
        switch role {
        case .client:
            return self.networkStreamID! % 2 == 1
        case .server:
            // Noone may initiate the root stream.
            return self.networkStreamID! % 2 == 0 && self != .rootStream
        }
    }
}


/// A simple protocol that provides helpers that apply to all connection states that keep track of a role.
private protocol ConnectionStateWithRole {
    var role: HTTP2ConnectionStateMachine.ConnectionRole { get }
}

extension ConnectionStateWithRole {
    var peerRole: HTTP2ConnectionStateMachine.ConnectionRole {
        switch self.role {
        case .client:
            return .server
        case .server:
            return .client
        }
    }
}
