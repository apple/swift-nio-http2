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


/// A representation of the state of the HTTP/2 streams in a single HTTP/2 connection.
struct ConnectionStreamState {
    /// The "safe" default value of SETTINGS_MAX_CONCURRENT_STREAMS.
    static let defaultMaxConcurrentStreams: UInt32 = 100

    fileprivate static let emptyStreamMap = StreamMap<HTTP2StreamStateMachine>.empty()

    /// The underlying data storage for the HTTP/2 stream state.
    private var activeStreams: StreamMap<HTTP2StreamStateMachine>

    /// A collection of recently reset streams.
    ///
    /// The recently closed streams are stored to provide better resilience against synchronization errors between
    /// the local and remote sides of the connection. Specifically, if a stream was recently closed, frames may have
    /// been in flight that should not be considered errors. We maintain a small amount of state to protect against
    /// this case.
    private var recentlyResetStreams: CircularBuffer<HTTP2StreamID>

    /// The maximum number of reset streams we'll persist.
    ///
    /// TODO (cory): Make this configurable!
    private let maxResetStreams: Int = 32

    /// The current number of streams that are active and that were initiated by the client.
    private var clientStreamCount: UInt32 = 0

    /// The current number of streams that are active and that were initiated by the server.
    private var serverStreamCount: UInt32 = 0

    /// The highest stream ID opened or reserved by the client.
    private var lastClientStreamID: HTTP2StreamID = .rootStream

    /// The highest stream ID opened or reserved by the server.
    private var lastServerStreamID: HTTP2StreamID = .rootStream

    /// The maximum number of streams that may be active at once, initiated by the client.
    ///
    /// Corresponds to the value of SETTINGS_MAX_CONCURRENT_STREAMS set by the client.
    var maxClientInitiatedStreams: UInt32 = ConnectionStreamState.defaultMaxConcurrentStreams

    /// The maximum number of streams that may be active at once, initiated by the server.
    ///
    /// Corresponds to the value of SETTINGS_MAX_CONCURRENT_STREAMS set by the server.
    var maxServerInitiatedStreams: UInt32 = ConnectionStreamState.defaultMaxConcurrentStreams

    /// The total number of streams currently active.
    var openStreams: Int {
        return Int(self.clientStreamCount) + Int(self.serverStreamCount)
    }

    init() {
        self.activeStreams = StreamMap()
        self.recentlyResetStreams = CircularBuffer(initialCapacity: self.maxResetStreams)
    }

    /// Create stream state for a remotely pushed stream.
    ///
    /// Unlike with idle streams, which are served by `modifyStreamStateCreateIfNeeded`, for pushed streams we do not
    /// have to perform a modification operation. For this reason, we can use a simpler control flow.
    ///
    /// - parameters:
    ///     - streamID: The ID of the pushed stream.
    ///     - remoteInitialWindowSize: The initial window size of the remote peer.
    /// - throws: If the stream ID is invalid.
    mutating func createRemotelyPushedStream(streamID: HTTP2StreamID, remoteInitialWindowSize: UInt32) throws {
        try self.reserveServerStreamID(streamID)
        let streamState = HTTP2StreamStateMachine(receivedPushPromiseCreatingStreamID: streamID, remoteInitialWindowSize: remoteInitialWindowSize)
        self.activeStreams.insert(streamState)
    }

    /// Create stream state for a locally pushed stream.
    ///
    /// Unlike with idle streams, which are served by `modifyStreamStateCreateIfNeeded`, for pushed streams we do not
    /// have to perform a modification operation. For this reason, we can use a simpler control flow.
    ///
    /// - parameters:
    ///     - streamID: The ID of the pushed stream.
    ///     - localInitialWindowSize: Our initial window size..
    /// - throws: If the stream ID is invalid.
    mutating func createLocallyPushedStream(streamID: HTTP2StreamID, localInitialWindowSize: UInt32) throws {
        try self.reserveServerStreamID(streamID)
        let streamState = HTTP2StreamStateMachine(sentPushPromiseCreatingStreamID: streamID, localInitialWindowSize: localInitialWindowSize)
        self.activeStreams.insert(streamState)
    }

    /// Obtains a stream state machine in order to modify its state, potentially creating it if necessary.
    ///
    /// The `creator` block will be called if the stream does not exist already. The `modifier` block will be called
    /// if the stream was created, or if it was found in the map.
    ///
    /// - parameters:
    ///     - streamID: The ID of the stream to modify.
    ///     - localRole: The connection role of the local peer.
    ///     - localInitialWindowSize: The initial size of the local flow control window for new streams.
    ///     - remoteInitialWindowSize: The initial size of the remote flow control window for new streams.
    ///     - modifier: A block that will be invoked to modify the stream state, if present.
    /// - throws: Any errors thrown from the creator.
    /// - returns: The result of the state modification, as well as any state change that occurred to the stream.
    mutating func modifyStreamStateCreateIfNeeded(streamID: HTTP2StreamID,
                                                  localRole: HTTP2StreamStateMachine.StreamRole,
                                                  localInitialWindowSize: UInt32,
                                                  remoteInitialWindowSize: UInt32,
                                                  modifier: (inout HTTP2StreamStateMachine) -> StateMachineResultWithStreamEffect) throws -> StateMachineResultWithStreamEffect {
        func creator() throws -> HTTP2StreamStateMachine {
            try self.reserveClientStreamID(streamID)
            let initialValue = HTTP2StreamStateMachine(streamID: streamID,
                                                       localRole: localRole,
                                                       localInitialWindowSize: localInitialWindowSize,
                                                       remoteInitialWindowSize: remoteInitialWindowSize)
            return initialValue
        }

        // FIXME(cory): This isn't ideal, but it's necessary to avoid issues with overlapping accesses on the activeStreams
        // map. The above closure takes a mutable copy of self, which is a big issue, so we should investigate whether
        // it's possible for me to be smarter here.
        var activeStreams = ConnectionStreamState.emptyStreamMap
        swap(&activeStreams, &self.activeStreams)
        defer {
            swap(&activeStreams, &self.activeStreams)
        }

        guard let result = try activeStreams.transformOrCreateAutoClose(streamID: streamID, creator, modifier) else {
            preconditionFailure("Stream was missing even though we should have created it!")
        }

        if let effect = result.effect, effect.closedStream {
            self.streamClosed(streamID)
        }

        return result
    }

    /// Obtains a stream state machine in order to modify its state.
    ///
    /// The block will be called so long as the stream exists in the currently active streams. If it does not, we will check
    /// whether the stream has been closed already.
    ///
    /// - parameters:
    ///     - streamID: The ID of the stream to modify.
    ///     - ignoreRecentlyReset: Whether a recently reset stream should be ignored. Should be set to `true` when receiving frames.
    ///     - ignoreClosed: Whether a closed stream should be ignored. Should be set to `true` when receiving window update or reset stream frames.
    ///     - modifier: A block that will be invoked to modify the stream state, if present.
    /// - returns: The result of the state modification, as well as any state change that occurred to the stream.
    mutating func modifyStreamState(streamID: HTTP2StreamID,
                                    ignoreRecentlyReset: Bool,
                                    ignoreClosed: Bool = false,
                                    _ modifier: (inout HTTP2StreamStateMachine) -> StateMachineResultWithStreamEffect) -> StateMachineResultWithStreamEffect {
        guard let result = self.activeStreams.autoClosingTransform(streamID: streamID, modifier) else {
            return StateMachineResultWithStreamEffect(result: self.streamMissing(streamID: streamID, ignoreRecentlyReset: ignoreRecentlyReset, ignoreClosed: ignoreClosed), effect: nil)
        }

        if let effect = result.effect, effect.closedStream {
            self.streamClosed(streamID)
        }

        return result
    }

    /// Obtains a stream state machine in order to modify its state due to a stream reset initiated locally.
    ///
    /// The block will be called so long as the stream exists in the currently active streams. If it does not, we will check
    /// whether the stream has been closed already.
    ///
    /// This block must close the stream. Failing to do so is a programming error.
    ///
    /// - parameters:
    ///     - streamID: The ID of the stream to modify.
    ///     - modifier: A block that will be invoked to modify the stream state, if present.
    /// - returns: The result of the state modification, as well as any state change that occurred to the stream.
    @inline(__always)
    mutating func locallyResetStreamState(streamID: HTTP2StreamID,
                                          _ modifier: (inout HTTP2StreamStateMachine) -> StateMachineResultWithStreamEffect) -> StateMachineResultWithStreamEffect {
        guard let result = self.activeStreams.autoClosingTransform(streamID: streamID, modifier) else {
            // We never ignore recently reset streams here, as this should only ever be used when *sending* frames.
            return StateMachineResultWithStreamEffect(result: self.streamMissing(streamID: streamID, ignoreRecentlyReset: false, ignoreClosed: false), effect: nil)
        }


        guard let effect = result.effect, effect.closedStream else {
            preconditionFailure("Locally resetting stream state did not close it!")
        }
        self.recentlyResetStreams.prependWithoutExpanding(streamID)
        self.streamClosed(streamID)

        return result
    }

    /// Performs a state-modifying operation on all streams.
    ///
    /// As with the other block-taking functions in this module, this is @inline(__always) to ensure
    /// that we don't end up actually heap-allocating a closure here. We're sorry about it!
    @inline(__always)
    mutating func forAllStreams(_ body: (inout HTTP2StreamStateMachine) throws -> Void) rethrows {
        try self.activeStreams.mutatingForEachValue(body)
    }

    /// Adjusts the stream state to reserve a client stream ID.
    mutating func reserveClientStreamID(_ streamID: HTTP2StreamID) throws {
        guard self.clientStreamCount < self.maxClientInitiatedStreams else {
            throw NIOHTTP2Errors.maxStreamsViolation()
        }

        guard streamID > self.lastClientStreamID else {
            throw NIOHTTP2Errors.streamIDTooSmall()
        }

        guard streamID.mayBeInitiatedBy(.client) else {
            throw NIOHTTP2Errors.invalidStreamIDForPeer()
        }

        self.lastClientStreamID = streamID
        self.clientStreamCount += 1
    }

    /// Adjusts the stream state to reserve a server stream ID.
    mutating func reserveServerStreamID(_ streamID: HTTP2StreamID) throws {
        guard self.serverStreamCount < self.maxServerInitiatedStreams else {
            throw NIOHTTP2Errors.maxStreamsViolation()
        }

        guard streamID > self.lastServerStreamID else {
            throw NIOHTTP2Errors.streamIDTooSmall()
        }

        guard streamID.mayBeInitiatedBy(.server) else {
            throw NIOHTTP2Errors.invalidStreamIDForPeer()
        }

        self.lastServerStreamID = streamID
        self.serverStreamCount += 1
    }

    /// Drop all streams with stream IDs larger than the given stream ID that were initiated by the given role.
    ///
    /// - parameters:
    ///     - streamID: The last stream ID the remote peer is promising to handle.
    ///     - droppedLocally: Whether this drop was caused by sending a GOAWAY frame or receiving it.
    ///     - initiator: The peer that sent the GOAWAY frame.
    /// - returns: the stream IDs closed by this operation.
    mutating func dropAllStreamsWithIDHigherThan(_ streamID: HTTP2StreamID,
                                                 droppedLocally: Bool,
                                                 initiatedBy initiator: HTTP2ConnectionStateMachine.ConnectionRole) -> [HTTP2StreamID]? {
        var droppedIDs: [HTTP2StreamID] = []
        self.activeStreams.dropDataWithStreamIDGreaterThan(streamID, initiatedBy: initiator) { data in
            droppedIDs = data.map { $0.streamID }
        }

        guard droppedIDs.count > 0 else {
            return nil
        }

        if droppedLocally {
            self.recentlyResetStreams.prependWithoutExpanding(contentsOf: droppedIDs)
        }

        switch initiator {
        case .client:
            self.clientStreamCount -= UInt32(droppedIDs.count)
        case .server:
            self.serverStreamCount -= UInt32(droppedIDs.count)
        }

        return droppedIDs
    }

    /// Determines the state machine result to generate when we've been asked to modify a missing stream.
    ///
    /// - parameters:
    ///     - streamID: The ID of the missing stream.
    ///     - ignoreRecentlyReset: Whether a recently reset stream should be ignored.
    ///     - ignoreClosed: Whether a closed stream should be ignored.
    /// - returns: A `StateMachineResult` for this frame error.
    private func streamMissing(streamID: HTTP2StreamID, ignoreRecentlyReset: Bool, ignoreClosed: Bool) -> StateMachineResult {
        if ignoreRecentlyReset && self.recentlyResetStreams.contains(streamID) {
            return .ignoreFrame
        }

        switch streamID.mayBeInitiatedBy(.client) {
        case true where streamID > self.lastClientStreamID,
             false where streamID > self.lastServerStreamID:
            // The stream in question is idle.
            return .connectionError(underlyingError: NIOHTTP2Errors.noSuchStream(streamID: streamID), type: .protocolError)
        default:
            // This stream must have already been closed.
            if ignoreClosed {
                return .ignoreFrame
            } else {
                return .connectionError(underlyingError: NIOHTTP2Errors.noSuchStream(streamID: streamID), type: .streamClosed)
            }
        }
    }

    private mutating func streamClosed(_ streamID: HTTP2StreamID) {
        assert(!self.activeStreams.contains(streamID: streamID))
        if streamID.mayBeInitiatedBy(.client) {
            self.clientStreamCount -= 1
        } else {
            self.serverStreamCount -= 1
        }
    }
}


extension CircularBuffer {
    // CircularBuffer may never be "full": that is, capacity may never equal count.
    var effectiveCapacity: Int {
        return self.capacity - 1
    }

    /// Prepends `element` without expanding the capacity, by dropping the
    /// element at the end if necessary.
    mutating func prependWithoutExpanding(_ element: Element) {
        if self.effectiveCapacity == self.count {
            self.removeLast()
        }
        self.prepend(element)
    }

    // NOTE: this could be generic over RandomAccessCollection if we wanted, I'm just saving code size by defining
    // it specifically for now.
    mutating func prependWithoutExpanding(contentsOf newElements: [Element]) {
        // We're going to need to insert these new elements _backwards_, as though they were inserted
        // one at a time.
        var newElements = newElements.reversed()[...]
        let newElementCount = newElements.count
        let freeSpace = self.effectiveCapacity - self.count

        if newElementCount >= self.effectiveCapacity {
            // We need to completely replace the storage, and then only insert `self.effectiveCapacity` elements.
            self.removeAll(keepingCapacity: true)
            newElements = newElements.prefix(self.effectiveCapacity)
        } else if newElementCount > freeSpace {
            // We need to free up enough space to store everything we need, but some of the old elements will remain.
            let elementsToRemove = newElementCount - freeSpace
            self.removeLast(elementsToRemove)
        }

        assert(newElements.count <= self.effectiveCapacity - self.count)
        self.insert(contentsOf: newElements, at: self.startIndex)
    }
}


extension StreamStateChange {
    fileprivate var closedStream: Bool {
        switch self {
        case .streamClosed, .streamCreatedAndClosed:
            return true
        case .streamCreated, .windowSizeChange:
            return false
        }
    }
}
