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

/// A HTTP/2 protocol implementation is fundamentally built on top of two interlocking finite
/// state machines. The full description of this is in ConnectionStateMachine.swift.
///
/// This file contains the implementation of the per-stream state machine. A HTTP/2 stream goes
/// through a number of states in its lifecycle, and the specific states it passes through depend
/// on how the stream is created and what it is for. RFC 7540 claims to have a state machine
/// diagram for a HTTP/2 stream, which I have reproduced below:
///
///                                +--------+
///                        send PP |        | recv PP
///                       ,--------|  idle  |--------.
///                      /         |        |         \
///                     v          +--------+          v
///              +----------+          |           +----------+
///              |          |          | send H /  |          |
///       ,------| reserved |          | recv H    | reserved |------.
///       |      | (local)  |          |           | (remote) |      |
///       |      +----------+          v           +----------+      |
///       |          |             +--------+             |          |
///       |          |     recv ES |        | send ES     |          |
///       |   send H |     ,-------|  open  |-------.     | recv H   |
///       |          |    /        |        |        \    |          |
///       |          v   v         +--------+         v   v          |
///       |      +----------+          |           +----------+      |
///       |      |   half   |          |           |   half   |      |
///       |      |  closed  |          | send R /  |  closed  |      |
///       |      | (remote) |          | recv R    | (local)  |      |
///       |      +----------+          |           +----------+      |
///       |           |                |                 |           |
///       |           | send ES /      |       recv ES / |           |
///       |           | send R /       v        send R / |           |
///       |           | recv R     +--------+   recv R   |           |
///       | send R /  `----------->|        |<-----------'  send R / |
///       | recv R                 | closed |               recv R   |
///       `----------------------->|        |<----------------------'
///                                +--------+
///
///          send:   endpoint sends this frame
///          recv:   endpoint receives this frame
///
///          H:  HEADERS frame (with implied CONTINUATIONs)
///          PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
///          ES: END_STREAM flag
///          R:  RST_STREAM frame
///
/// Unfortunately, this state machine diagram is not really entirely sufficient, as it
/// underspecifies many aspects of the system. One particular note is that it does not
/// encode the validity of some of these transitions: for example, send PP or recv PP
/// are only valid for certain kinds of peers.
///
/// Ultimately, however, this diagram provides the basis for our state machine
/// implementation in this file. The state machine aims to enforce the correctness of
/// the protocol.
///
/// Remote peers that violate the protocol requirements should be notified early.
/// HTTP/2 is unusual in that the vast majority of implementations are strict about
/// RFC violations, and we should be as well. Therefore, the state machine exists to
/// constrain the remote peer's actions: if they take an action that leads to an invalid
/// state transition, we will report this to the remote peer (and to our user).
///
/// Additionally, we want to enforce that our users do not violate the correctness of the
/// protocol. In this early implementation if the user violates protocol correctness, no
/// action is taken: the stream remains in its prior state, and no frame is emitted.
/// In future it may become configurable such that if the user violates the correctness of
/// the protocol, NIO will proactively close the stream to avoid consuming resources.
///
/// ### Implementation
///
/// The core of the state machine implementation is a `State` enum. This enum demarcates all
/// valid states of the stream, and enforces only valid transitions between those states.
/// Attempts to make invalid transitions between those states will be rejected by this enum.
///
/// Additionally, this enum stores all relevant data about the stream that is associated with
/// its stream state as associated data. This ensures that it is not possible to store a stream
/// state that requires associated data without providing it.
///
/// To prevent future maintainers from being tempted to circumvent the rules in this state machine,
/// the `State` enum is wrapped in a `struct` (this `struct`, in fact) that prevents programmers
/// from directly setting the state of a stream.
///
/// Operations on the state machine are performed by calling specific functions corresponding to
/// the operation that is about to occur.
struct HTTP2StreamStateMachine {
    private enum State {
        // TODO(cory): Can we remove the idle state? Streams shouldn't sit in idle for long periods
        // of time, they should immediately transition out, so can we avoid it entirely?
        /// In the idle state, the stream has not been opened by either peer.
        /// This is usually a temporary state, and we expect rapid transitions out of this state.
        /// In this state we keep track of whether we are in a client or server connection, as it
        /// limits the transitions we can make. In all other states, being either a client or server
        /// is either not relevant, or encoded in the state itself implicitly.
        case idle(localRole: StreamRole, localWindow: HTTP2FlowControlWindow, remoteWindow: HTTP2FlowControlWindow)

        /// In the reservedRemote state, the stream has been opened by the remote peer emitting a
        /// PUSH_PROMISE frame. We are expecting to receive a HEADERS frame for the pushed response. In this
        /// state we are definitionally a client.
        case reservedRemote(remoteWindow: HTTP2FlowControlWindow)

        /// In the reservedLocal state, the stream has been opened by the local user sending a PUSH_PROMISE
        /// frame. We now need to send a HEADERS frame for the pushed response. In this state we are definitionally
        /// a server.
        case reservedLocal(localWindow: HTTP2FlowControlWindow)

        /// This state does not exist on the diagram above. It encodes the notion that this stream has
        /// been opened by the local user sending a HEADERS frame, but we have not yet received the remote
        /// peer's final HEADERS frame in response. It is possible we have received non-final HEADERS frames
        /// from the remote peer in this state, however. If we are in this state, we must be a client: servers
        /// initiating streams put them into reservedLocal, and then sending HEADERS transfers them directly to
        /// halfClosedRemoteLocalActive.
        case halfOpenLocalPeerIdle(localWindow: HTTP2FlowControlWindow, remoteWindow: HTTP2FlowControlWindow)

        /// This state does not exist on the diagram above. It encodes the notion that this stream has
        /// been opened by the remote user sending a HEADERS frame, but we have not yet sent our HEADERS frame
        /// in response. If we are in this state, we must be a server: clients receiving streams that were opened
        /// by servers put them into reservedRemote, and then receiving the response HEADERS transitions them directly
        /// to halfClosedLocalPeerActive.
        case halfOpenRemoteLocalIdle(localWindow: HTTP2FlowControlWindow, remoteWindow: HTTP2FlowControlWindow)

        /// This state is when both peers have sent a HEADERS frame, but neither has sent a frame with END_STREAM
        /// set. Both peers may exchange data fully. In this state we keep track of whether we are a client or a
        /// server, as only servers may push new streams.
        case fullyOpen(localRole: StreamRole, localWindow: HTTP2FlowControlWindow, remoteWindow: HTTP2FlowControlWindow)

        /// In the halfClosedLocalPeerIdle state, the local user has sent END_STREAM, but the remote peer has not
        /// yet sent its HEADERS frame. This mostly happens on GET requests, when END_HEADERS and END_STREAM are
        /// present on the same frame, and so the stream transitions directly from idle to this state.
        /// This peer can no longer send data. We are expecting a headers frame from the remote peer.
        ///
        /// In this state we must be a client, as this state can only be entered by the local peer sending
        /// END_STREAM before we receive HEADERS. This cannot happen to a server, as we must have initiated
        /// this stream to have half closed it before we receive HEADERS, and if we had initiated the stream via
        /// PUSH_PROMISE (as a server must), the stream would be halfClosedRemote, not halfClosedLocal.
        case halfClosedLocalPeerIdle(remoteWindow: HTTP2FlowControlWindow)

        /// In the halfClosedLocalPeerActive state, the local user has sent END_STREAM, and the remote peer has
        /// sent its HEADERS frame. This happens when we send END_STREAM from the fullyOpen state, or when we
        /// receive a HEADERS in reservedRemote. This peer can no longer send data. The remote peer may continue
        /// to do so. We are not expecting a HEADERS frame from the remote peer.
        ///
        /// Both servers and clients can be in this state.
        ///
        /// We keep track of whether this stream was initiated by us or by the peer, which can be determined based
        /// on how we entered this state. If we came from fullyOpen and we're a client, then this peer was initiated
        /// by us: if we're a server, it was initiated by the peer. This is because server-initiated streams never
        /// enter fullyOpen, as the client is never actually open on those streams. If we came here from
        /// reservedRemote, this stream must be peer initiated, as this is the client side of a pushed stream.
        case halfClosedLocalPeerActive(localRole: StreamRole, initiatedBy: StreamRole, remoteWindow: HTTP2FlowControlWindow)

        /// In the halfClosedRemoteLocalIdle state, the remote peer has sent END_STREAM, but the local user has not
        /// yet sent its HEADERS frame. This mostly happens on GET requests, when END_HEADERS and END_STREAM are
        /// present on the same frame, and so the stream transitions directly from idle to this state.
        /// This peer is expected to send a HEADERS frame. The remote peer may no longer send data.
        ///
        /// In this state we must be a server, as this state can only be entered by the remote peer sending
        /// END_STREAM before we send HEADERS. This cannot happen to a client, as the remote peer must have initiated
        /// this stream to have half closed it before we send HEADERS, and that will cause a client to enter halfClosedLocal,
        /// not halfClosedRemote.
        case halfClosedRemoteLocalIdle(localWindow: HTTP2FlowControlWindow)

        /// In the halfClosedRemoteLocalActive state, the remote peer has sent END_STREAM, and the local user has
        /// sent its HEADERS frame. This happens when we receive END_STREAM in the fullyOpen state, or when we
        /// send a HEADERS frame in reservedLocal. This peer is not expected to send a HEADERS frame.
        /// The remote peer may no longer send data.
        ///
        /// Both servers and clients can be in this state.
        ///
        /// We keep track of whether this stream was initiated by us or by the peer, which can be determined based
        /// on how we entered this state. If we came from fullyOpen and we're a client, then this stream was initiated
        /// by us: if we're a server, it was initiated by the peer. This is because server-initiated streams never
        /// enter fullyOpen, as the client is never actually open on those streams. If we came here from
        /// reservedLocal, this stream must be initiated by us, as this is the server side of a pushed stream.
        case halfClosedRemoteLocalActive(localRole: StreamRole, initiatedBy: StreamRole, localWindow: HTTP2FlowControlWindow)

        /// Both peers have sent their END_STREAM flags, and the stream is closed. In this stage no further data
        /// may be exchanged.
        case closed
    }


    /// The possible roles an endpoint may play in a given stream.
    enum StreamRole {
        /// A server. Servers initiate streams by pushing them.
        case server

        /// A client. Clients initiate streams by sending requests.
        case client
    }

    /// Whether this stream has been closed.
    ///
    /// This property should be used only for asserting correct state.
    internal var closed: Bool {
        switch self.state {
        case .closed:
            return true
        default:
            return false
        }
    }

    /// The current state of this stream.
    private var state: State

    /// The ID of this stream.
    internal let streamID: HTTP2StreamID

    /// Creates a new, idle, HTTP/2 stream.
    init(streamID: HTTP2StreamID, localRole: StreamRole, localInitialWindowSize: UInt32, remoteInitialWindowSize: UInt32) {
        let localWindow = HTTP2FlowControlWindow(initialValue: localInitialWindowSize)
        let remoteWindow = HTTP2FlowControlWindow(initialValue: remoteInitialWindowSize)

        self.streamID = streamID
        self.state = .idle(localRole: localRole, localWindow: localWindow, remoteWindow: remoteWindow)
    }

    /// Creates a new HTTP/2 stream for a stream that was created by receiving a PUSH_PROMISE frame
    /// on another stream.
    init(receivedPushPromiseCreatingStreamID streamID: HTTP2StreamID, remoteInitialWindowSize: UInt32) {
        self.streamID = streamID
        self.state = .reservedRemote(remoteWindow: HTTP2FlowControlWindow(initialValue: remoteInitialWindowSize))
    }

    /// Creates a new HTTP/2 stream for a stream that was created by sending a PUSH_PROMISE frame on
    /// another stream.
    init(sentPushPromiseCreatingStreamID streamID: HTTP2StreamID, localInitialWindowSize: UInt32) {
        self.streamID = streamID
        self.state = .reservedLocal(localWindow: HTTP2FlowControlWindow(initialValue: localInitialWindowSize))
    }
}

// MARK:- State transition functions
//
// The events that may cause the state machine to change state.
//
// This enumeration contains entries for sending and receiving all per-stream frames except for PRIORITY.
// The per-connection frames (GOAWAY, PING, some WINDOW_UPDATE) are managed by the connection state machine
// instead of the stream one, and so are not covered here. This enumeration excludes PRIORITY frames, because
// while PRIORITY frames are technically per-stream they can be sent at any time on an active connection,
// regardless of the state of the affected stream. For this reason, they are not so much per-stream frames
// as per-connection frames that happen to have a stream ID.
extension HTTP2StreamStateMachine {
    /// Called when a HEADERS frame is being sent. Validates that the frame may be sent in this state, that
    /// it meets the requirements of RFC 7540 for containing a well-formed header block, and additionally
    /// checks whether the value of the end stream bit is acceptable. If all checks pass, transitions the
    /// state to the appropriate next entry.
    mutating func sendHeaders(headers: HPACKHeaders, isEndStreamSet endStream: Bool) -> StateMachineResult {
        // We can send headers in the following states:
        //
        // - idle, when we are a client, in which case we are sending our request headers
        // - halfOpenRemoteLocalIdle, in which case we are a server sending either informational or final headers
        // - halfOpenLocalPeerIdle, in which case we are a client sending trailers
        // - reservedLocal, in which case we are a server sending either informational or final headers
        // - fullyOpen, in which case we are sending trailers
        // - halfClosedRemoteLocalIdle, in which case we area server  sending either informational or final headers
        //     (see the comment on halfClosedRemoteLocalIdle for more)
        // - halfClosedRemoteLocalActive, in which case we are sending trailers
        switch self.state {
        case .idle(.client, localWindow: let localWindow, remoteWindow: let remoteWindow):
            let targetState: State = endStream ? .halfClosedLocalPeerIdle(remoteWindow: remoteWindow) : .halfOpenLocalPeerIdle(localWindow: localWindow, remoteWindow: remoteWindow)
            return self.processRequestHeaders(headers, targetState: targetState)

        case .halfOpenRemoteLocalIdle(localWindow: let localWindow, remoteWindow: let remoteWindow):
            let targetState: State = endStream ? .halfClosedLocalPeerActive(localRole: .server, initiatedBy: .client, remoteWindow: remoteWindow) : .fullyOpen(localRole: .server, localWindow: localWindow, remoteWindow: remoteWindow)
            return self.processResponseHeaders(headers, targetStateIfFinal: targetState)

        case .halfOpenLocalPeerIdle(localWindow: _, remoteWindow: let remoteWindow):
            return self.processTrailers(headers, isEndStreamSet: endStream, targetState: .halfClosedLocalPeerIdle(remoteWindow: remoteWindow))

        case .reservedLocal(let localWindow):
            let targetState: State = endStream ? .closed : .halfClosedRemoteLocalActive(localRole: .server, initiatedBy: .server, localWindow: localWindow)
            return self.processResponseHeaders(headers, targetStateIfFinal: targetState)

        case .fullyOpen(let localRole, localWindow: _, remoteWindow: let remoteWindow):
            return self.processTrailers(headers, isEndStreamSet: endStream, targetState: .halfClosedLocalPeerActive(localRole: localRole, initiatedBy: .client, remoteWindow: remoteWindow))

        case .halfClosedRemoteLocalIdle(let localWindow):
            let targetState: State = endStream ? .closed : . halfClosedRemoteLocalActive(localRole: .server, initiatedBy: .client, localWindow: localWindow)
            return self.processResponseHeaders(headers, targetStateIfFinal: targetState)

        case .halfClosedRemoteLocalActive:
            return self.processTrailers(headers, isEndStreamSet: endStream, targetState: .closed)

        // Sending a HEADERS frame as an idle server, or on a closed stream, is a connection error
        // of type PROTOCOL_ERROR. In any other state, sending a HEADERS frame is a stream error of
        // type PROTOCOL_ERROR.
        // (Authors note: I can find nothing in the RFC that actually states what kind of error is
        // triggered for HEADERS frames outside the valid states. So I just guessed here based on what
        // seems reasonable to me: specifically, if we have a stream to fail, fail it, otherwise treat
        // the error as connection scoped.)
        case .idle(.server, _, _), .closed:
            return .connectionError(underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        case .reservedRemote, .halfClosedLocalPeerIdle, .halfClosedLocalPeerActive:
            return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        }
    }

    mutating func receiveHeaders(headers: HPACKHeaders, isEndStreamSet endStream: Bool) -> StateMachineResult {
        // We can receive headers in the following states:
        //
        // - idle, when we are a server, in which case we are receiving request headers
        // - halfOpenLocalPeerIdle, in which case we are receiving either informational or final response headers
        // - halfOpenRemoteLocalIdle, in which case we are receiving trailers
        // - reservedRemote, in which case we are a client receiving either informational or final response headers
        // - fullyOpen, in which case we are receiving trailers
        // - halfClosedLocalPeerIdle, in which case we are receiving either informational or final headers
        //     (see the comment on halfClosedLocalPeerIdle for more)
        // - halfClosedLocalPeerActive, in which case we are receiving trailers
        switch self.state {
        case .idle(.server, localWindow: let localWindow, remoteWindow: let remoteWindow):
            let targetState: State = endStream ? .halfClosedRemoteLocalIdle(localWindow: localWindow) : .halfOpenRemoteLocalIdle(localWindow: localWindow, remoteWindow: remoteWindow)
            return self.processRequestHeaders(headers, targetState: targetState)

        case .halfOpenLocalPeerIdle(localWindow: let localWindow, remoteWindow: let remoteWindow):
            let targetState: State = endStream ? .halfClosedRemoteLocalActive(localRole: .client,initiatedBy: .client, localWindow: localWindow) : .fullyOpen(localRole: .client, localWindow: localWindow, remoteWindow: remoteWindow)
            return self.processResponseHeaders(headers, targetStateIfFinal: targetState)

        case .halfOpenRemoteLocalIdle(localWindow: let localWindow, remoteWindow: _):
            return self.processTrailers(headers, isEndStreamSet: endStream, targetState: .halfClosedRemoteLocalIdle(localWindow: localWindow))

        case .reservedRemote(let remoteWindow):
            let targetState: State = endStream ? .closed : .halfClosedLocalPeerActive(localRole: .client, initiatedBy: .server, remoteWindow: remoteWindow)
            return self.processResponseHeaders(headers, targetStateIfFinal: targetState)

        case .fullyOpen(let localRole, localWindow: let localWindow, remoteWindow: _):
            return self.processTrailers(headers, isEndStreamSet: endStream, targetState: .halfClosedRemoteLocalActive(localRole: localRole, initiatedBy: .client, localWindow: localWindow))

        case .halfClosedLocalPeerIdle(let remoteWindow):
            let targetState: State = endStream ? .closed : . halfClosedLocalPeerActive(localRole: .client, initiatedBy: .client, remoteWindow: remoteWindow)
            return self.processResponseHeaders(headers, targetStateIfFinal: targetState)

        case .halfClosedLocalPeerActive:
            return self.processTrailers(headers, isEndStreamSet: endStream, targetState: .closed)

        // Receiving a HEADERS frame as an idle client, or on a closed stream, is a connection error
        // of type PROTOCOL_ERROR. In any other state, receiving a HEADERS frame is a stream error of
        // type PROTOCOL_ERROR.
        // (Authors note: I can find nothing in the RFC that actually states what kind of error is
        // triggered for HEADERS frames outside the valid states. So I just guessed here based on what
        // seems reasonable to me: specifically, if we have a stream to fail, fail it, otherwise treat
        // the error as connection scoped.)
        case .idle(.client, _, _), .closed:
            return .connectionError(underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        case .reservedLocal, .halfClosedRemoteLocalIdle, .halfClosedRemoteLocalActive:
            return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        }
    }

    mutating func sendData(flowControlledBytes: Int, isEndStreamSet endStream: Bool) -> StateMachineResult {
        do {
            // We can send DATA frames in the following states:
            //
            // - halfOpenLocalPeerIdle, in which case we are a client sending request data before the server
            //     has sent its final response headers.
            // - fullyOpen, where we could be either a client or a server using a fully bi-directional stream.
            // - halfClosedRemoteLocalActive, where the remote peer has completed its data, but we have more to send.
            switch self.state {
            case .halfOpenLocalPeerIdle(localWindow: var localWindow, remoteWindow: let remoteWindow):
                try localWindow.consume(flowControlledBytes: flowControlledBytes)
                self.state = endStream ? .halfClosedLocalPeerIdle(remoteWindow: remoteWindow) : .halfOpenLocalPeerIdle(localWindow: localWindow, remoteWindow: remoteWindow)
                return .succeed

            case .fullyOpen(let localRole, localWindow: var localWindow, remoteWindow: let remoteWindow):
                try localWindow.consume(flowControlledBytes: flowControlledBytes)
                self.state = endStream ? .halfClosedLocalPeerActive(localRole: localRole, initiatedBy: .client, remoteWindow: remoteWindow) : .fullyOpen(localRole: localRole, localWindow: localWindow, remoteWindow: remoteWindow)
                return .succeed

            case .halfClosedRemoteLocalActive(let localRole, let initiatedBy, var localWindow):
                try localWindow.consume(flowControlledBytes: flowControlledBytes)
                self.state = endStream ? .closed : .halfClosedRemoteLocalActive(localRole: localRole, initiatedBy: initiatedBy, localWindow: localWindow)
                return .succeed

            // Sending a DATA frame outside any of these states is a stream error of type STREAM_CLOSED (RFC7540 § 6.1)
            case .idle, .halfOpenRemoteLocalIdle, .reservedLocal, .reservedRemote, .halfClosedLocalPeerIdle,
                 .halfClosedLocalPeerActive, .halfClosedRemoteLocalIdle, .closed:
                return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .streamClosed)
            }
        } catch let error where error is NIOHTTP2Errors.FlowControlViolation {
            return .streamError(streamID: self.streamID, underlyingError: error, type: .flowControlError)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
    }

    mutating func receiveData(flowControlledBytes: Int, isEndStreamSet endStream: Bool) -> StateMachineResult {
        do {
            // We can receive DATA frames in the following states:
            //
            // - halfOpenRemoteLocalIdle, in which case we are a server receiving request data before we have
            //     sent our final response headers.
            // - fullyOpen, where we could be either a client or a server using a fully bi-directional stream.
            // - halfClosedLocalPeerActive, whe have completed our data, but the remote peer has more to send.
            switch self.state {
            case .halfOpenRemoteLocalIdle(localWindow: let localWindow, remoteWindow: var remoteWindow):
                try remoteWindow.consume(flowControlledBytes: flowControlledBytes)
                self.state = endStream ? .halfClosedRemoteLocalIdle(localWindow: localWindow) : .halfOpenRemoteLocalIdle(localWindow: localWindow, remoteWindow: remoteWindow)
                return .succeed

            case .fullyOpen(let localRole, localWindow: let localWindow, remoteWindow: var remoteWindow):
                try remoteWindow.consume(flowControlledBytes: flowControlledBytes)
                self.state = endStream ? .halfClosedRemoteLocalActive(localRole: localRole, initiatedBy: .client, localWindow: localWindow) : .fullyOpen(localRole: localRole, localWindow: localWindow, remoteWindow: remoteWindow)
                return .succeed

            case .halfClosedLocalPeerActive(let localRole, let initiatedBy, var remoteWindow):
                try remoteWindow.consume(flowControlledBytes: flowControlledBytes)
                self.state = endStream ? .closed : .halfClosedLocalPeerActive(localRole: localRole, initiatedBy: initiatedBy, remoteWindow: remoteWindow)
                return .succeed

            // Receiving a DATA frame outside any of these states is a stream error of type STREAM_CLOSED (RFC7540 § 6.1)
            case .idle, .halfOpenLocalPeerIdle, .reservedLocal, .reservedRemote, .halfClosedLocalPeerIdle,
                 .halfClosedRemoteLocalActive, .halfClosedRemoteLocalIdle, .closed:
                return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .streamClosed)
            }
        } catch let error where error is NIOHTTP2Errors.FlowControlViolation {
            return .streamError(streamID: self.streamID, underlyingError: error, type: .flowControlError)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
    }

    mutating func sendPushPromise(headers: HPACKHeaders) -> StateMachineResult {
        // We can send PUSH_PROMISE frames in the following states:
        //
        // - fullyOpen when we are a server. In this case we assert that the stream was initiated by the client.
        // - halfClosedRemoteLocalActive, when we are a server, and when the stream was initiated by the client.
        //
        // RFC 7540 § 6.6 forbids sending PUSH_PROMISE frames on locally-initiated streams.
        switch self.state {
        case .fullyOpen(localRole: .server, localWindow: _, remoteWindow: _),
             .halfClosedRemoteLocalActive(localRole: .server, initiatedBy: .client, localWindow: _):
            return self.processRequestHeaders(headers, targetState: self.state)

        // Sending a PUSH_PROMISE frame outside any of these states is a stream error of type PROTOCOL_ERROR.
        // Authors note: I cannot find a citation for this in RFC 7540, but this seems a sensible choice.
        case .idle, .reservedLocal, .reservedRemote, .halfClosedLocalPeerIdle, .halfClosedLocalPeerActive,
             .halfClosedRemoteLocalIdle, .halfOpenLocalPeerIdle, .halfOpenRemoteLocalIdle, .closed,
             .fullyOpen(localRole: .client, localWindow: _, remoteWindow: _),
             .halfClosedRemoteLocalActive(localRole: .client, initiatedBy: _, localWindow: _),
             .halfClosedRemoteLocalActive(localRole: .server, initiatedBy: .server, localWindow: _):
            return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        }
    }

    mutating func receivePushPromise(headers: HPACKHeaders) -> StateMachineResult {
        // We can receive PUSH_PROMISE frames in the following states:
        //
        // - fullyOpen when we are a client. In this case we assert that the stream was initiated by us.
        // - halfClosedLocalPeerActive, when we are a client, and when the stream was initiated by us.
        //
        // RFC 7540 § 6.6 forbids receiving PUSH_PROMISE frames on remotely-initiated streams.
        switch self.state {
        case .fullyOpen(localRole: .client, localWindow: _, remoteWindow: _),
             .halfClosedLocalPeerActive(localRole: .client, initiatedBy: .client, remoteWindow: _):
            return self.processRequestHeaders(headers, targetState: self.state)

        // Receiving a PUSH_PROMISE frame outside any of these states is a stream error of type PROTOCOL_ERROR.
        // Authors note: I cannot find a citation for this in RFC 7540, but this seems a sensible choice.
        case .idle, .reservedLocal, .reservedRemote, .halfClosedLocalPeerIdle, .halfClosedRemoteLocalIdle,
             .halfClosedRemoteLocalActive, .halfOpenLocalPeerIdle, .halfOpenRemoteLocalIdle, .closed,
             .fullyOpen(localRole: .server, localWindow: _, remoteWindow: _),
             .halfClosedLocalPeerActive(localRole: .server, initiatedBy: _, remoteWindow: _),
             .halfClosedLocalPeerActive(localRole: .client, initiatedBy: .server, remoteWindow: _):
            return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        }
    }

    mutating func sendWindowUpdate(windowIncrement: UInt32) -> StateMachineResult {
        do {
            // RFC 7540 does not limit the states in which WINDOW_UDPATE frames can be sent. For this reason we need to be
            // fairly conservative about applying limits. In essence, we allow sending WINDOW_UPDATE frames in all but the
            // following states:
            //
            // - idle, because the stream hasn't been created yet so the stream ID is invalid
            // - reservedLocal, because the remote peer will never be able to send data
            // - halfClosedRemoteLocalIdle and halfClosedRemoteLocalActive, because the remote peer has sent END_STREAM and
            //     can send no further data
            // - closed, because the entire stream is closed now
            switch self.state {
            case .reservedRemote(remoteWindow: var remoteWindow):
                try remoteWindow.windowUpdate(by: windowIncrement)
                self.state = .reservedRemote(remoteWindow: remoteWindow)

            case .halfOpenLocalPeerIdle(localWindow: let localWindow, remoteWindow: var remoteWindow):
                try remoteWindow.windowUpdate(by: windowIncrement)
                self.state = .halfOpenLocalPeerIdle(localWindow: localWindow, remoteWindow: remoteWindow)

            case .halfOpenRemoteLocalIdle(localWindow: let localWindow, remoteWindow: var remoteWindow):
                try remoteWindow.windowUpdate(by: windowIncrement)
                self.state = .halfOpenRemoteLocalIdle(localWindow: localWindow, remoteWindow: remoteWindow)

            case .fullyOpen(localRole: let localRole, localWindow: let localWindow, remoteWindow: var remoteWindow):
                try remoteWindow.windowUpdate(by: windowIncrement)
                self.state = .fullyOpen(localRole: localRole, localWindow: localWindow, remoteWindow: remoteWindow)

            case .halfClosedLocalPeerIdle(remoteWindow: var remoteWindow):
                try remoteWindow.windowUpdate(by: windowIncrement)
                self.state = .halfClosedLocalPeerIdle(remoteWindow: remoteWindow)

            case .halfClosedLocalPeerActive(localRole: let localRole, initiatedBy: let initiatedBy, remoteWindow: var remoteWindow):
                try remoteWindow.windowUpdate(by: windowIncrement)
                self.state = .halfClosedLocalPeerActive(localRole: localRole, initiatedBy: initiatedBy, remoteWindow: remoteWindow)

            case .idle, .reservedLocal, .halfClosedRemoteLocalIdle, .halfClosedRemoteLocalActive, .closed:
                return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
            }
        } catch let error where error is NIOHTTP2Errors.InvalidFlowControlWindowSize {
            return .streamError(streamID: self.streamID, underlyingError: error, type: .flowControlError)
        } catch let error where error is NIOHTTP2Errors.InvalidWindowIncrementSize {
            return .streamError(streamID: self.streamID, underlyingError: error, type: .protocolError)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }

        return .succeed
    }

    mutating func receiveWindowUpdate(windowIncrement: UInt32) -> StateMachineResult {
        do {
            // RFC 7540 does not limit the states in which WINDOW_UDPATE frames can be received. For this reason we need to be
            // fairly conservative about applying limits. In essence, we allow receiving WINDOW_UPDATE frames in all but the
            // following states:
            //
            // - idle, because the stream hasn't been created yet so the stream ID is invalid
            // - reservedRemote, because we will never be able to send data so it's silly to manipulate our flow control window
            // - closed, because the entire stream is closed now
            //
            // Note that, unlike with sending, we allow receiving window update frames when we are half-closed. This is because
            // it is possible that those frames may have been in flight when we were closing the stream, and so we shouldn't cause
            // the stream to explode simply for that reason. In this case, we just ignore the data.
            switch self.state {
            case .reservedLocal(localWindow: var localWindow):
                try localWindow.windowUpdate(by: windowIncrement)
                self.state = .reservedLocal(localWindow: localWindow)

            case .halfOpenLocalPeerIdle(localWindow: var localWindow, remoteWindow: let remoteWindow):
                try localWindow.windowUpdate(by: windowIncrement)
                self.state = .halfOpenLocalPeerIdle(localWindow: localWindow, remoteWindow: remoteWindow)

            case .halfOpenRemoteLocalIdle(localWindow: var localWindow, remoteWindow: let remoteWindow):
                try localWindow.windowUpdate(by: windowIncrement)
                self.state = .halfOpenRemoteLocalIdle(localWindow: localWindow, remoteWindow: remoteWindow)

            case .fullyOpen(localRole: let localRole, localWindow: var localWindow, remoteWindow: let remoteWindow):
                try localWindow.windowUpdate(by: windowIncrement)
                self.state = .fullyOpen(localRole: localRole, localWindow: localWindow, remoteWindow: remoteWindow)

            case .halfClosedRemoteLocalIdle(localWindow: var localWindow):
                try localWindow.windowUpdate(by: windowIncrement)
                self.state = .halfClosedRemoteLocalIdle(localWindow: localWindow)

            case .halfClosedRemoteLocalActive(localRole: let localRole, initiatedBy: let initiatedBy, localWindow: var localWindow):
                try localWindow.windowUpdate(by: windowIncrement)
                self.state = .halfClosedRemoteLocalActive(localRole: localRole, initiatedBy: initiatedBy, localWindow: localWindow)

            case .halfClosedLocalPeerIdle, .halfClosedLocalPeerActive:
                // No-op, see above
                break

            case .idle, .reservedRemote, .closed:
                return .streamError(streamID: self.streamID, underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
            }
        } catch let error where error is NIOHTTP2Errors.InvalidFlowControlWindowSize {
            return .streamError(streamID: self.streamID, underlyingError: error, type: .flowControlError)
        } catch let error where error is NIOHTTP2Errors.InvalidWindowIncrementSize {
            return .streamError(streamID: self.streamID, underlyingError: error, type: .protocolError)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }

        return .succeed
    }

    mutating func sendRstStream() -> StateMachineResult {
        // We can send RST_STREAM frames in almost all states. The only state where it is entirely forbidden
        // by RFC 7540 is idle, which is a transitory state that we tend to leave pretty quickly.
        if case .idle = self.state {
            return .connectionError(underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        }

        self.state = .closed
        return .succeed
    }

    mutating func receiveRstStream() -> StateMachineResult {
        // We can receive RST_STREAM frames in any state but idle.
        // TODO(cory): Right now this is identical to sendRstStream. If we end up doing separate handling for this,
        // we'll want the two functions, but if that never changes then we can just have this function call the one
        // above.
        if case .idle = self.state {
            return .connectionError(underlyingError: NIOHTTP2Errors.BadStreamStateTransition(), type: .protocolError)
        }

        self.state = .closed
        return .succeed
    }

    /// The local value of SETTINGS_INITIAL_WINDOW_SIZE has been changed, and the change has been ACKed.
    ///
    /// This change causes the remote flow control window to be resized.
    mutating func localInitialWindowSizeChanged(by change: Int32) throws {
        switch self.state {
        case .idle(localRole: let role, localWindow: let localWindow, remoteWindow: var remoteWindow):
            try remoteWindow.initialSizeChanged(by: change)
            self.state = .idle(localRole: role, localWindow: localWindow, remoteWindow: remoteWindow)

        case .reservedRemote(remoteWindow: var remoteWindow):
            try remoteWindow.initialSizeChanged(by: change)
            self.state = .reservedRemote(remoteWindow: remoteWindow)

        case .halfOpenLocalPeerIdle(localWindow: let localWindow, remoteWindow: var remoteWindow):
            try remoteWindow.initialSizeChanged(by: change)
            self.state = .halfOpenLocalPeerIdle(localWindow: localWindow, remoteWindow: remoteWindow)

        case .halfOpenRemoteLocalIdle(localWindow: let localWindow, remoteWindow: var remoteWindow):
            try remoteWindow.initialSizeChanged(by: change)
            self.state = .halfOpenRemoteLocalIdle(localWindow: localWindow, remoteWindow: remoteWindow)

        case .fullyOpen(localRole: let localRole, localWindow: let localWindow, remoteWindow: var remoteWindow):
            try remoteWindow.initialSizeChanged(by: change)
            self.state = .fullyOpen(localRole: localRole, localWindow: localWindow, remoteWindow: remoteWindow)

        case .halfClosedLocalPeerIdle(remoteWindow: var remoteWindow):
            try remoteWindow.initialSizeChanged(by: change)
            self.state = .halfClosedLocalPeerIdle(remoteWindow: remoteWindow)

        case .halfClosedLocalPeerActive(localRole: let localRole, initiatedBy: let initiatedBy, remoteWindow: var remoteWindow):
            try remoteWindow.initialSizeChanged(by: change)
            self.state = .halfClosedLocalPeerActive(localRole: localRole, initiatedBy: initiatedBy, remoteWindow: remoteWindow)

        case .reservedLocal, .halfClosedRemoteLocalIdle, .halfClosedRemoteLocalActive:
            // In these states the remote side of this stream is closed and will never be open, so its flow control window is not relevant.
            // This is a no-op.
            break

        case .closed:
            // This should never occur.
            preconditionFailure("Updated window of a closed stream.")
        }
    }

    /// The remote value of SETTINGS_INITIAL_WINDOW_SIZE has been changed.
    ///
    /// This change causes the local flow control window to be resized.
    mutating func remoteInitialWindowSizeChanged(by change: Int32) throws {
        switch self.state {
        case .idle(localRole: let role, localWindow: var localWindow, remoteWindow: let remoteWindow):
            try localWindow.initialSizeChanged(by: change)
            self.state = .idle(localRole: role, localWindow: localWindow, remoteWindow: remoteWindow)

        case .reservedLocal(localWindow: var localWindow):
            try localWindow.initialSizeChanged(by: change)
            self.state = .reservedLocal(localWindow: localWindow)

        case .halfOpenLocalPeerIdle(localWindow: var localWindow, remoteWindow: let remoteWindow):
            try localWindow.initialSizeChanged(by: change)
            self.state = .halfOpenLocalPeerIdle(localWindow: localWindow, remoteWindow: remoteWindow)

        case .halfOpenRemoteLocalIdle(localWindow: var localWindow, remoteWindow: let remoteWindow):
            try localWindow.initialSizeChanged(by: change)
            self.state = .halfOpenRemoteLocalIdle(localWindow: localWindow, remoteWindow: remoteWindow)

        case .fullyOpen(localRole: let localRole, localWindow: var localWindow, remoteWindow: let remoteWindow):
            try localWindow.initialSizeChanged(by: change)
            self.state = .fullyOpen(localRole: localRole, localWindow: localWindow, remoteWindow: remoteWindow)

        case .halfClosedRemoteLocalIdle(localWindow: var localWindow):
            try localWindow.initialSizeChanged(by: change)
            self.state = .halfClosedRemoteLocalIdle(localWindow: localWindow)

        case .halfClosedRemoteLocalActive(localRole: let localRole, initiatedBy: let initiatedBy, localWindow: var localWindow):
            try localWindow.initialSizeChanged(by: change)
            self.state = .halfClosedRemoteLocalActive(localRole: localRole, initiatedBy: initiatedBy, localWindow: localWindow)

        case .reservedRemote, .halfClosedLocalPeerIdle, .halfClosedLocalPeerActive:
            // In these states the local side of this stream is closed and will never be open, so its flow control window is not relevant.
            // This is a no-op.
            break

        case .closed:
            // This should never occur.
            preconditionFailure("Updated window of a closed stream.")
        }
    }
}

// MARK:- Functions for handling headers frames.
extension HTTP2StreamStateMachine {
    /// Validate that the request headers meet the requirements of RFC 7540. If they do,
    /// transitions to the target state.
    private mutating func processRequestHeaders(_ headers: HPACKHeaders, targetState target: State) -> StateMachineResult {
        // TODO(cory): Implement
        self.state = target
        return .succeed
    }

    /// Validate that the response headers meet the requirements of RFC 7540. Also characterises
    /// them to check whether the headers are informational or final, and if the headers are
    /// valid and correspond to a final response, transitions to the appropriate target state.
    private mutating func processResponseHeaders(_ headers: HPACKHeaders, targetStateIfFinal finalState: State) -> StateMachineResult {
        // TODO(cory): Implement

        // The barest minimum of functionality is to distinguish final and non-final headers, so we do that for now.
        if !headers.isInformationalResponse {
            // Non-informational responses cause state transitions.
            self.state = finalState
        }
        return .succeed
    }

    /// Validates that the trailers meet the requirements of RFC 7540. If they do, transitions to the
    /// target final state.
    private mutating func processTrailers(_ headers: HPACKHeaders, isEndStreamSet endStream: Bool, targetState target: State) -> StateMachineResult {
        // TODO(cory): Implement
        self.state = target
        return .succeed
    }
}


private extension HPACKHeaders {
    /// Whether this `HPACKHeaders` corresponds to a final response or not.
    ///
    /// This property is only valid if called on a response header block. If the :status header
    /// is not present, this will return "false"
    var isInformationalResponse: Bool {
        return self.first { $0.name == ":status" }?.value.first == "1"
    }
}
