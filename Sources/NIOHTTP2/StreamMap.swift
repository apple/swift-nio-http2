//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

fileprivate let binarySearchThreshold = 200

/// StreamMap is a specialized data structure built to optimise lookups of per-stream state.
///
/// It is common when working with HTTP/2 to need to store "per-stream" state. This is state that is
/// reproduced once per stream, and independent. In general we want to be able to store this state in such
/// a way that we can look it up by stream ID as efficiently as possible.
///
/// Naively we can use a dictionary for this, but dictionaries incur substantial hashing costs. This is
/// straightforward, but we can do better by noting that streams are inherently _ordered_. That is, within
/// a stream ID space (client or server), all streams are created in stricly ascending order. As a result
/// we can efficiently use linear scans to find streams in arrays instead, so long as we have a separate array
/// for both client and server-initated streams.
///
/// This data structure encapsulates this idea. To tolerate high-load cases, we don't actually use `Array`
/// directly: instead we use `CircularBuffer`. This reduces our need to reallocate memory because we can re-use
/// slots from previous stream data. It also avoids the need to compact the array, as old streams are more likely
/// to complete before new ones, which would leave gaps at the front of the array.
///
/// Finally, we have to discuss the complexity of lookups. By moving from a dictionary we go from O(1) to O(n) cost
/// for lookups. This is worse! Why would we want this?
///
/// Well, most of the time the number of streams on any given connection is very low. On modern processors, it is often
/// faster to do a linear search of an array than to do the hashing required to index into the dictionary. Linear scans
/// are cache-friendly and branch-predictor-friendly, which means it can in some cases be cheaper to do a linear scan of
/// 100 items than to do a binary search or hash table lookup.
///
/// Our strategy here is therefore hybrid. Up to 200 streams we will do linear searches to find our stream. Beyond that,
/// we'll do a binary search.
struct StreamMap<Element: PerStreamData> {
    private var serverInitiated: CircularBuffer<Element>
    private var clientInitiated: CircularBuffer<Element>

    init() {
        // We begin by creating our circular buffers at 16 elements in size. This is a good balance between not wasting too
        // much memory, but avoiding the first few quadratic resizes.
        self.serverInitiated = CircularBuffer(initialCapacity: 16)
        self.clientInitiated = CircularBuffer(initialCapacity: 16)
    }

    fileprivate init(serverInitiated: CircularBuffer<Element>, clientInitiated: CircularBuffer<Element>) {
        self.serverInitiated = serverInitiated
        self.clientInitiated = clientInitiated
    }

    /// Creates an "empty" stream map. This should be used only to create static singletons
    /// whose purpose is to be swapped to avoid CoWs. Otherwise use regular init().
    static func empty() -> StreamMap<Element> {
        let sortaEmptyCircularBuffer = CircularBuffer<Element>()
        return StreamMap(serverInitiated: sortaEmptyCircularBuffer, clientInitiated: sortaEmptyCircularBuffer)
    }

    func contains(streamID: HTTP2StreamID) -> Bool {
        if streamID.mayBeInitiatedBy(.client) {
            return self.clientInitiated.findIndexForStreamID(streamID) != nil
        } else {
            return self.serverInitiated.findIndexForStreamID(streamID) != nil
        }
    }

    /// Calls the closure with the given element, if it is present. Returns nil if the element is not present.
    mutating func modify<ReturnType>(streamID: HTTP2StreamID, _ body: (inout Element) throws -> ReturnType) rethrows -> ReturnType? {
        if streamID.mayBeInitiatedBy(.client) {
            guard let index = self.clientInitiated.findIndexForStreamID(streamID) else {
                return nil
            }
            return try self.clientInitiated.modify(index, body)
        } else {
            guard let index = self.serverInitiated.findIndexForStreamID(streamID) else {
                return nil
            }
            return try self.serverInitiated.modify(index, body)
        }
    }

    mutating func insert(_ element: Element) {
        let streamID = element.streamID

        if streamID.mayBeInitiatedBy(.client) {
            assert((self.clientInitiated.last?.streamID ?? 0) < streamID)
            self.clientInitiated.append(element)
        } else {
            assert((self.serverInitiated.last?.streamID ?? 0) < streamID)
            self.serverInitiated.append(element)
        }
    }

    mutating func mutatingForEachValue(_ body: (inout Element) throws -> Void) rethrows {
        try self.clientInitiated.mutatingForEach(body)
        try self.serverInitiated.mutatingForEach(body)
    }

    func forEachValue(_ body: (Element) throws -> Void) rethrows {
        try self.clientInitiated.forEach(body)
        try self.serverInitiated.forEach(body)
    }

    @discardableResult
    mutating func removeValue(forStreamID streamID: HTTP2StreamID) -> Element? {
        if streamID.mayBeInitiatedBy(.client), let index = self.clientInitiated.findIndexForStreamID(streamID) {
            return self.clientInitiated.remove(at: index)
        } else if streamID.mayBeInitiatedBy(.server), let index = self.serverInitiated.findIndexForStreamID(streamID) {
            return self.serverInitiated.remove(at: index)
        } else {
            return nil
        }
    }

    func elements(initiatedBy: HTTP2ConnectionStateMachine.ConnectionRole) -> CircularBuffer<Element>.Iterator {
        switch initiatedBy {
        case .client:
            return self.clientInitiated.makeIterator()
        case .server:
            return self.serverInitiated.makeIterator()
        }
    }

    /// This is a special case helper for the ConnectionStreamsState, which has to handle GOAWAY. In that case we
    /// drop all stream state for a bunch of streams all at once. These streams are guaranteed to be sequential and based at a certain stream ID.
    ///
    /// It's useful to get that data back too, and helpfully CircularBuffer will let us slice it out. We can't return it though: that will cause the mutation
    /// to trigger a CoW. Instead we pass it to the caller in a block, and then do the removal.
    ///
    /// This helper can turn a complex operation that involves repeated resizing of the base objects into a much faster one that also avoids
    /// allocation.
    mutating func dropDataWithStreamIDGreaterThan(_ streamID: HTTP2StreamID,
                                                  initiatedBy role: HTTP2ConnectionStateMachine.ConnectionRole,
                                                  _ block: (CircularBuffer<Element>.SubSequence) -> Void) {
        switch role {
        case .client:
            let index = self.clientInitiated.findIndexForFirstStreamIDLargerThan(streamID)
            block(self.clientInitiated[index...])
            self.clientInitiated.removeSubrange(index...)
        case .server:
            let index = self.serverInitiated.findIndexForFirstStreamIDLargerThan(streamID)
            block(self.serverInitiated[index...])
            self.serverInitiated.removeSubrange(index...)
        }
    }
}

internal extension StreamMap where Element == HTTP2StreamStateMachine {
    // This function exists as a performance optimisation: we can keep track of the index and where we are, and
    // thereby avoid searching the array twice.
    //
    /// Transform the value of an HTTP2StreamStateMachine, closing it if it ends up closed.
    ///
    /// - parameters:
    ///     - modifier: A block that will modify the contained value in the
    ///          map, if there is one present.
    /// - returns: The return value of the block or `nil` if the element was not present.
    mutating func autoClosingTransform<T>(streamID: HTTP2StreamID, _ modifier: (inout Element) -> T) -> T? {
        if streamID.mayBeInitiatedBy(.client) {
            return self.clientInitiated.autoClosingTransform(streamID: streamID, modifier)
        } else {
            return self.serverInitiated.autoClosingTransform(streamID: streamID, modifier)
        }
    }


    // This function exists as a performance optimisation: we can keep track of the index and where we are, and
    // thereby avoid searching the array twice.
    mutating func transformOrCreateAutoClose<T>(streamID: HTTP2StreamID,
                                                _ creator: () throws -> Element,
                                                _ transformer: (inout Element) -> T) rethrows -> T? {
        if streamID.mayBeInitiatedBy(.client) {
            return try self.clientInitiated.transformOrCreateAutoClose(streamID: streamID, creator, transformer)
        } else {
            return try self.serverInitiated.transformOrCreateAutoClose(streamID: streamID, creator, transformer)
        }
    }
}

extension CircularBuffer where Element: PerStreamData {
    fileprivate mutating func mutatingForEach(_ body: (inout Element) throws -> Void) rethrows {
        var index = self.startIndex
        let endIndex = self.endIndex
        while index != endIndex {
            try self.modify(index, body)
            self.formIndex(after: &index)
        }
    }

    fileprivate func findIndexForStreamID(_ streamID: HTTP2StreamID) -> Index? {
        if self.count < binarySearchThreshold {
            return self.linearScanForStreamID(streamID)
        } else {
            return self.binarySearchForStreamID(streamID)
        }
    }

    private func linearScanForStreamID(_ streamID: HTTP2StreamID) -> Index? {
        var index = self.startIndex

        while index < self.endIndex {
            let currentStreamID = self[index].streamID
            if currentStreamID == streamID {
                return index
            }
            if currentStreamID > streamID {
                // Stop looping, we won't find this.
                return nil
            }
            self.formIndex(after: &index)
        }

        return nil
    }

    // Binary search is somewhat complex code compared to a linear scan, so we don't want to inline this code if we can avoid it.
    @inline(never)
    private func binarySearchForStreamID(_ streamID: HTTP2StreamID) -> Index? {
        var left = self.startIndex
        var right = self.endIndex

        while left != right {
            let pivot = self.index(left, offsetBy: self.distance(from: left, to: right) / 2)
            let currentStreamID = self[pivot].streamID
            if currentStreamID > streamID {
                right = pivot
            } else if currentStreamID == streamID {
                return pivot
            } else {
                left = self.index(after: pivot)
            }
        }

        return nil
    }

    fileprivate func findIndexForFirstStreamIDLargerThan(_ streamID: HTTP2StreamID) -> Index {
        if self.count < binarySearchThreshold {
            return self.linearScanForFirstStreamIDLargerThan(streamID)
        } else {
            return self.binarySearchForFirstStreamIDLargerThan(streamID)
        }
    }

    private func linearScanForFirstStreamIDLargerThan(_ streamID: HTTP2StreamID) -> Index {
        var index = self.startIndex

        while index < self.endIndex {
            let currentStreamID = self[index].streamID
            if currentStreamID > streamID {
                return index
            }
            self.formIndex(after: &index)
        }

        return self.endIndex
    }

    // Binary search is somewhat complex code compared to a linear scan, so we don't want to inline this code if we can avoid it.
    @inline(never)
    private func binarySearchForFirstStreamIDLargerThan(_ streamID: HTTP2StreamID) -> Index {
        var left = self.startIndex
        var right = self.endIndex

        while left != right {
            let pivot = self.index(left, offsetBy: self.distance(from: left, to: right) / 2)
            let currentStreamID = self[pivot].streamID
            if currentStreamID > streamID {
                right = pivot
            } else if currentStreamID == streamID {
                // The stream ID is the one after.
                return self.index(after: pivot)
            } else {
                left = self.index(after: pivot)
            }
        }

        return left
    }
}

extension CircularBuffer where Element == HTTP2StreamStateMachine {
    // This function exists as a performance optimisation: we can keep track of the index and where we are, and
    // thereby avoid searching the array twice.
    //
    /// Transform the value of an HTTP2StreamStateMachine, closing it if it ends up closed.
    ///
    /// - parameters:
    ///     - modifier: A block that will modify the contained value in the
    ///         map, if there is one present.
    /// - returns: The return value of the block or `nil` if the element was not in the map.
    mutating func autoClosingTransform<ResultType>(streamID: HTTP2StreamID, _ modifier: (inout Element) -> ResultType) -> ResultType? {
        guard let index = self.findIndexForStreamID(streamID) else {
            return nil
        }

        return self.modifyAutoClose(index: index, modifier)
    }

    // This function exists as a performance optimisation: we can keep track of the index and where we are, and
    // thereby avoid searching the array twice.
    mutating func transformOrCreateAutoClose<ResultType>(streamID: HTTP2StreamID,
                                                         _ creator: () throws -> Element,
                                                         _ transformer: (inout Element) -> ResultType) rethrows -> ResultType? {
        if let index = self.findIndexForStreamID(streamID) {
            return self.modifyAutoClose(index: index, transformer)
        } else {
            self.append(try creator())
            let index = self.index(before: self.endIndex)
            return self.modifyAutoClose(index: index, transformer)
        }
    }

    private mutating func modifyAutoClose<ResultType>(index: Index, _ modifier: (inout Element) -> ResultType) -> ResultType {
        let (result, closed): (ResultType, HTTP2StreamStateMachine.StreamClosureState) = self.modify(index) {
            let result = modifier(&$0)
            return (result, $0.closed)
        }

        if case .closed = closed {
            self.remove(at: index)
        }

        return result
    }
}

protocol PerStreamData {
    var streamID: HTTP2StreamID { get }
}
