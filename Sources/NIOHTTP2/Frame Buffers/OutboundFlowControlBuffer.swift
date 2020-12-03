//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIO

/// A structure that manages buffering outbound frames for active streams to ensure that those streams do not violate flow control rules.
///
/// This buffer is an extremely performance sensitive part of the HTTP/2 stack. This is because all outbound data passes through it, and
/// all application data needs to be actively buffered by it. The result of this is that state management is extremely expensive, and we
/// need efficient algorithms to process them.
///
/// The core of the data structure are a collection of `StreamFlowControlState` objects. These objects keep track of the flow control window
/// available for a given stream, as well as any pending writes that may be present on the stream. The pending writes include both DATA and
/// HEADERS frames, as if we've buffered any DATA frames we need to queue HEADERS frames up behind them.
///
/// Data is appended to these objects on write(). Each write() will trigger both a lookup in the stream data buffers _and_ an append to a
/// data buffer. It is therefore deeply important that both of these operations are as cheap as possible.
///
/// However, these operations are fundamentally constant in size. Once we have found the stream data buffer, we do not need to worry about
/// all the others. The cost of the write() operation is therefore no more expensive than the cost of the lookup. The same is unfortunately
/// not true for flush().
///
/// When we get a flush(), we need to update a bunch of state. In particular, we need to record any previously-written frames that are
/// now flushed, as well as compute which streams may have become writable as a result of the flush call. In early versions of this code
/// we would do a linear scan across _all buffers_, check whether they were writable before, mark their flush point, check if they'd become
/// writable, and then store them in the set of flushable streams. This was monstrously expensive, and worse still the cost was not proportional
/// to the amount of writing done but to the amount of flushing done and the number of active streams.
///
/// The current design avoids this by having the `StreamFlowControlState` be much more explicit about when it transitions from non-writable to
/// writable and back again. This allows us to keep an Array of writable streams that we use to avoid needing to touch all the streams whenever
/// a flush occurs. This greatly reduces our workload! Additionally, by caching all stream state changes we are not forced to perform repeated
/// expensive computations, but can instead incrementalise the cost on a per-write instead of per-flush basis, keeping track of exactly the
/// decisions we're making.
internal struct OutboundFlowControlBuffer {
    /// A buffer of the data sent on the stream that has not yet been passed to the the connection state machine.
    private var streamDataBuffers: StreamMap<StreamFlowControlState>

    /// The streams that have been written to since the last flush.
    ///
    /// This object is a cache that is used to keep track of what streams need to be modified whenever we get a flush()
    /// call. Streams that have been invalidated or removed don't get removed from here: we deal with them once we flush
    /// and go to find them to actually write from them. They are not a correctness problem.
    private var writableStreams: Set<HTTP2StreamID> = Set()

    /// The streams with pending data to output.
    private var flushableStreams: Set<HTTP2StreamID> = Set()

    /// The current size of the connection flow control window. May be negative.
    internal var connectionWindowSize: Int

    /// The current value of SETTINGS_MAX_FRAME_SIZE set by the peer.
    internal var maxFrameSize: Int

    internal init(initialConnectionWindowSize: Int = 65535, initialMaxFrameSize: Int = 1<<14) {
        // TODO(cory): HEAP! This should be a heap, sorted off the number of pending bytes!
        self.streamDataBuffers = StreamMap()
        self.connectionWindowSize = initialConnectionWindowSize
        self.maxFrameSize = initialMaxFrameSize

        // Avoid some resizes.
        self.writableStreams.reserveCapacity(16)
        self.flushableStreams.reserveCapacity(16)
    }

    internal mutating func processOutboundFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) throws -> OutboundFrameAction {
        // A side note: there is no special handling for RST_STREAM frames here, unlike in the concurrent streams buffer. This is because
        // RST_STREAM frames will cause stream closure notifications, which will force us to drop our buffers. For this reason we can
        // simplify our code here, which helps a lot.
        let streamID = frame.streamID

        switch frame.payload {
        case .data:
            // We buffer DATA frames.
            if !self.streamDataBuffers.apply(streamID: streamID, { $0.bufferWrite((frame.payload, promise)) }) {
                // We don't have this stream ID. This is an internal error, but we won't precondition on it as
                // it can happen due to channel handler misconfiguration or other weirdness. We'll just complain.
                throw NIOHTTP2Errors.noSuchStream(streamID: streamID)
            }

            self.writableStreams.insert(streamID)
            return .nothing
        case .headers:
            // Headers are special. If we have a data frame buffered, we buffer behind it to avoid frames
            // being reordered. However, if we don't have a data frame buffered we pass the headers frame on
            // immediately, as there is no risk of violating ordering guarantees.
            let bufferResult = self.streamDataBuffers.modify(streamID: streamID) { (state: inout StreamFlowControlState) -> Bool in
                if state.haveBufferedDataFrame {
                    state.bufferWrite((frame.payload, promise))
                    return true
                } else {
                    return false
                }
            }

            switch bufferResult {
            case .some(true):
                self.writableStreams.insert(streamID)
                return .nothing
            case .some(false), .none:
                // We don't need to buffer this, pass it on.
                return .forward
            }
        default:
            // For all other frame types, we don't care about them, pass them on.
            return .forward
        }
    }

    internal mutating func flushReceived() {
        // Mark the flush points on all the streams we believe are writable.
        // We need to double-check here: has their flow control window dropped below zero? If it
        // has, the streamID isn't actually writable, and we should abandon adding it here. However,
        // we still mark the flush point.
        for streamID in self.writableStreams {
            let actuallyWritable: Bool? = self.streamDataBuffers.modify(streamID: streamID) { dataBuffer in
                dataBuffer.markFlushPoint()
                return dataBuffer.hasFlowControlWindowSpaceForNextWrite
            }
            if let actuallyWritable = actuallyWritable, actuallyWritable {
                self.flushableStreams.insert(streamID)
            }
        }

        self.writableStreams.removeAll(keepingCapacity: true)
    }

    private func nextStreamToSend() -> HTTP2StreamID? {
        return self.flushableStreams.first
    }

    internal mutating func updateWindowOfStream(_ streamID: HTTP2StreamID, newSize: Int32) {
        assert(streamID != .rootStream)

        self.streamDataBuffers.apply(streamID: streamID) {
            switch $0.updateWindowSize(newSize: Int(newSize)) {
            case .unchanged:
                // No change, do nothing.
                ()
            case .changed(newValue: true):
                // Became writable, and specifically became _flushable_.
                self.flushableStreams.insert(streamID)
            case .changed(newValue: false):
                // Became unwritable.
                self.flushableStreams.remove(streamID)
            }
        }
    }

    internal func invalidateBuffer(reason: ChannelError) {
        self.streamDataBuffers.forEachValue { buffer in
            buffer.failAllWrites(error: reason)
        }
    }

    internal mutating func streamCreated(_ streamID: HTTP2StreamID, initialWindowSize: UInt32) {
        assert(streamID != .rootStream)

        let streamState = StreamFlowControlState(streamID: streamID, initialWindowSize: Int(initialWindowSize))
        self.streamDataBuffers.insert(streamState)
    }

    // We received a stream closed event. Drop any stream state we're holding.
    //
    // - returns: Any buffered stream state we may have been holding so their promises can be failed.
    internal mutating func streamClosed(_ streamID: HTTP2StreamID) -> MarkedCircularBuffer<(HTTP2Frame.FramePayload, EventLoopPromise<Void>?)>? {
        self.flushableStreams.remove(streamID)
        guard var streamData = self.streamDataBuffers.removeValue(forStreamID: streamID) else {
            // Huh, we didn't have any data for this stream. Oh well. That was easy.
            return nil
        }

        // To avoid too much work higher up the stack, we only return writes from here if there actually are any.
        let writes = streamData.evacuatePendingWrites()
        if writes.count > 0 {
            return writes
        } else {
            return nil
        }
    }

    internal mutating func nextFlushedWritableFrame() -> (HTTP2Frame, EventLoopPromise<Void>?)? {
        // If the channel isn't writable, we don't want to send anything.
        guard let nextStreamID = self.nextStreamToSend(), self.connectionWindowSize > 0 else {
            return nil
        }

        let nextWrite = self.streamDataBuffers.modify(streamID: nextStreamID) { (state: inout StreamFlowControlState) -> DataBuffer.BufferElement in
            let (nextWrite, writabilityState) = state.nextWrite(maxSize: min(self.connectionWindowSize, self.maxFrameSize))

            switch writabilityState {
            case .changed(newValue: false):
                self.flushableStreams.remove(nextStreamID)
            case .changed(newValue: true), .unchanged:
                ()
            }

            return nextWrite
        }
        guard let (payload, promise) = nextWrite else {
            // The stream was not present. This is weird, it shouldn't ever happen, but we tolerate it, and recurse.
            self.flushableStreams.remove(nextStreamID)
            return self.nextFlushedWritableFrame()
        }

        let frame = HTTP2Frame(streamID: nextStreamID, payload: payload)
        return (frame, promise)
    }

    internal mutating func initialWindowSizeChanged(_ delta: Int) {
        self.streamDataBuffers.mutatingForEachValue {
            switch $0.updateWindowSize(newSize: $0.currentWindowSize + delta) {
            case .unchanged:
                // No change, do nothing.
                ()
            case .changed(newValue: true):
                // Became flushable
                self.flushableStreams.insert($0.streamID)
            case .changed(newValue: false):
                // Became unflushable.
                self.flushableStreams.remove($0.streamID)
            }
        }
    }
}


// MARK: Priority API
extension OutboundFlowControlBuffer {
    /// A frame with new priority data has been received that affects prioritisation of outbound frames.
    internal mutating func priorityUpdate(streamID: HTTP2StreamID, priorityData: HTTP2Frame.StreamPriorityData) throws {
        // Right now we don't actually do anything with priority information. However, we do want to police some parts of
        // RFC 7540 § 5.3, where we can, so this hook is already in place for us to extend later.
        if streamID == priorityData.dependency {
            // Streams may not depend on themselves!
            throw NIOHTTP2Errors.priorityCycle(streamID: streamID)
        }
    }
}


private struct StreamFlowControlState: PerStreamData {
    let streamID: HTTP2StreamID
    internal private(set) var currentWindowSize: Int
    private var dataBuffer: DataBuffer

    var haveBufferedDataFrame: Bool {
        return self.dataBuffer.haveBufferedDataFrame
    }

    var hasFlowControlWindowSpaceForNextWrite: Bool {
        return self.currentWindowSize > 0 || self.dataBuffer.nextWriteIsZeroSized
    }

    init(streamID: HTTP2StreamID, initialWindowSize: Int) {
        self.streamID = streamID
        self.currentWindowSize = initialWindowSize
        self.dataBuffer = DataBuffer()
    }

    mutating func bufferWrite(_ write: DataBuffer.BufferElement) {
        self.dataBuffer.bufferWrite(write)
    }

    mutating func updateWindowSize(newSize: Int) -> WritabilityState {
        let oldWindowSize = self.currentWindowSize
        self.currentWindowSize = newSize

        // If we have no marked writes, nothing changed.
        guard self.dataBuffer.hasMark else {
            return .unchanged
        }

        if oldWindowSize <= 0 && self.currentWindowSize > 0 {
            // Window opened. We can now write.
            return .changed(newValue: true)
        }

        if self.currentWindowSize <= 0 && oldWindowSize > 0 {
            // Window closed. We can now only write if the first write is zero-sized.
            if self.dataBuffer.nextWriteIsZeroSized {
                return .unchanged
            }

            return .changed(newValue: false)
        }

        return .unchanged
    }

    mutating func markFlushPoint() {
        self.dataBuffer.markFlushPoint()
    }

    /// Removes all pending writes, invalidating this structure as it does so.
    mutating func evacuatePendingWrites() -> MarkedCircularBuffer<DataBuffer.BufferElement> {
        return self.dataBuffer.evacuatePendingWrites()
    }

    func failAllWrites(error: ChannelError) {
        self.dataBuffer.failAllWrites(error: error)
    }

    mutating func nextWrite(maxSize: Int) -> (DataBuffer.BufferElement, WritabilityState) {
        assert(maxSize > 0)
        let writeSize = min(maxSize, currentWindowSize)
        let nextWrite = self.dataBuffer.nextWrite(maxSize: writeSize)
        var writabilityState = WritabilityState.unchanged

        if case .data(let payload) = nextWrite.0 {
            self.currentWindowSize -= payload.data.readableBytes

            if !self.dataBuffer.hasMark {
                // Eaten the mark, no longer writable.
                writabilityState = .changed(newValue: false)
            } else if !self.hasFlowControlWindowSpaceForNextWrite {
                // No flow control space for writing anymore.
                writabilityState = .changed(newValue: false)
            }
        } else if !self.dataBuffer.hasMark {
            // Eaten the mark, no longer writable.
            writabilityState = .changed(newValue: false)
        }

        assert(self.currentWindowSize >= 0)
        return (nextWrite, writabilityState)
    }
}


private struct DataBuffer {
    typealias BufferElement = (HTTP2Frame.FramePayload, EventLoopPromise<Void>?)

    private var bufferedChunks: MarkedCircularBuffer<BufferElement>

    var haveBufferedDataFrame: Bool {
        return self.bufferedChunks.count > 0
    }

    var nextWriteIsZeroSized: Bool {
        return self.bufferedChunks.first?.0.isZeroSizedWrite ?? false
    }

    var hasMark: Bool {
        return self.bufferedChunks.hasMark
    }

    /// An empty buffer, we use this avoid an allocation in 'evacuatePendingWrites'.
    private static let emptyBuffer = MarkedCircularBuffer<BufferElement>(initialCapacity: 0)

    init() {
        self.bufferedChunks = MarkedCircularBuffer(initialCapacity: 8)
    }

    mutating func bufferWrite(_ write: BufferElement) {
        self.bufferedChunks.append(write)
    }

    /// Marks the current point in the buffer as the place up to which we have flushed.
    mutating func markFlushPoint() {
        self.bufferedChunks.mark()
    }

    mutating func nextWrite(maxSize: Int) -> BufferElement {
        assert(maxSize >= 0)
        assert(self.hasMark)
        precondition(self.bufferedChunks.count > 0)

        let firstElementIndex = self.bufferedChunks.startIndex

        // First check that the next write is DATA. If it's not, just pass it on.
        guard case .data(var contents) = self.bufferedChunks[firstElementIndex].0 else {
            return self.bufferedChunks.removeFirst()
        }

        // Now check if we have enough space to return the next DATA frame wholesale.
        let firstElementReadableBytes = contents.data.readableBytes
        if firstElementReadableBytes <= maxSize {
            // Return the whole element.
            return self.bufferedChunks.removeFirst()
        }

        // Here we have too many bytes. So we need to slice out a copy of the data we need
        // and leave the rest.
        let dataSlice = contents.data.slicePrefix(maxSize)
        self.bufferedChunks[self.bufferedChunks.startIndex].0 = .data(contents)
        return (.data(.init(data: dataSlice)), nil)
    }

    /// Removes all pending writes, invalidating this structure as it does so.
    mutating func evacuatePendingWrites() -> MarkedCircularBuffer<BufferElement> {
        var buffer = DataBuffer.emptyBuffer
        swap(&buffer, &self.bufferedChunks)
        return buffer
    }

    func failAllWrites(error: ChannelError) {
        for chunk in self.bufferedChunks {
            chunk.1?.fail(error)
        }
    }
}


/// Used to communicate whether a stream has had its writability state change.
fileprivate enum WritabilityState {
    case changed(newValue: Bool)
    case unchanged
}


private extension IOData {
    mutating func slicePrefix(_ length: Int) -> IOData {
        assert(length < self.readableBytes)

        switch self {
        case .byteBuffer(var buf):
            // This force-unwrap is safe, as we only invoke this when we have already checked the length.
            let newBuf = buf.readSlice(length: length)!
            self = .byteBuffer(buf)
            return .byteBuffer(newBuf)

        case .fileRegion(var region):
            let newRegion = FileRegion(fileHandle: region.fileHandle, readerIndex: region.readerIndex, endIndex: region.readerIndex + length)
            region.moveReaderIndex(forwardBy: length)
            self = .fileRegion(region)
            return .fileRegion(newRegion)
        }
    }
}


extension HTTP2Frame.FramePayload {
    fileprivate var isZeroSizedWrite: Bool {
        switch self {
        case .data(let payload):
            return payload.data.readableBytes == 0 && payload.paddingBytes == nil
        default:
            return true
        }
    }
}


extension StreamMap where Element == StreamFlowControlState {
    //
    /// Apply a transform to a wrapped DataBuffer.
    ///
    /// - parameters:
    ///     - body: A block that will modify the contained value in the
    ///         optional, if there is one present.
    /// - returns: Whether the value was present or not.
    @discardableResult
    fileprivate mutating func apply(streamID: HTTP2StreamID, _ body: (inout Element) -> Void) -> Bool {
        return self.modify(streamID: streamID, body) != nil
    }
}
