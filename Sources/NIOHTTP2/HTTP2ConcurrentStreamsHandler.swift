//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIO


/// A `ChannelHandler` that buffers new stream creation attempts to avoid violating
/// the HTTP/2 setting `SETTINGS_MAX_CONCURRENT_STREAMS`.
///
/// HTTP/2 provides tools for bounding the maximum amount of concurrent streams that a
/// given peer can create. This is used to limit the amount of state that a peer will need
/// to allocate for a given connection.
///
/// In an high-efficiency pipeline it will generally be better to limit the maximum number of
/// concurrent streams by avoiding creating new outbound streams. However, simpler applications
/// may prefer to delay stream creation instead, buffering frames until they can be delivered.
/// This `ChannelHandler` manages this transparently to the user by keeping track of the number
/// of active outbound streams and delaying any stream creation until safe.
///
/// Note that this `ChannelHandler` can and will re-order flushed frames. Having this `ChannelHandler`
/// in the pipeline means that frames written logically before others may nonetheless have their write
/// promises satisfied later. If this is a concern for your application, consider using the
/// `HTTP2StreamMultiplexer` to avoid a single `Channel` having its writes reordered.
public class NIOHTTP2ConcurrentStreamsHandler: ChannelDuplexHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    /// The buffer that will store frames as needed. Provides most of the logic of this
    /// ChannelHandler.
    private var frameBuffer: StreamFrameBuffer

    /// The mode of the Channel we're operating in
    private var mode: NIOHTTP2Handler.ParserMode {
        get {
            return self.frameBuffer.mode
        }
    }

    public init(mode: NIOHTTP2Handler.ParserMode, initialMaxOutboundStreams: Int) {
        self.frameBuffer = StreamFrameBuffer(mode: mode, initialMaxOutboundStreams: initialMaxOutboundStreams)
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as StreamClosedEvent:
            // This event may make some frames writable. If it does, then we may be in write()
            // (in which case we expect a pending flush), or we may be in flush() (in which case we're
            // already looping) or we may be in a read cycle (in which case we'll get channelReadComplete
            // soon). In any case, we will soon be writing frames, so we do not need to do so here.
            // Instead, just keep track of the change internally.
            self.frameBuffer.streamClosed(event.streamID)
        case let event as NIOHTTP2StreamCreatedEvent:
            self.frameBuffer.streamCreated(event.streamID)
        default:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        guard case .settings(let newSettings) = frame.payload, !frame.flags.contains(.ack) else {
            // Either this is not a settings frame, or it's a settings ACK. Either way we don't care.
            // TODO(cory): We should handle GOAWAY!
            context.fireChannelRead(data)
            return
        }

        guard let newMaxConcurrentStreams = newSettings.lazy.reversed().first(where: { $0.parameter == .maxConcurrentStreams }).map( { $0.value } ) else {
            // This settings frame didn't change the value of SETTINGS_MAX_CONCURRENT_STREAMS
            context.fireChannelRead(data)
            return
        }

        // This is allowed to shrink maxConcurrentStreams.
        self.frameBuffer.maxOutboundStreams = newMaxConcurrentStreams
        context.fireChannelRead(data)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        if self.writeIfPossible(context: context) {
            context.flush()
        }

        context.fireChannelReadComplete()
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)

        let operation: StreamFrameBuffer.OutboundFrameAction
        do {
            operation = try self.frameBuffer.processOutboundFrame(frame, promise: promise)
        } catch {
            promise?.fail(error)
            return
        }

        switch operation {
        case .nothing:
            break
        case .forward:
            context.write(data, promise: promise)
        case .forwardAndDrop(let writesToDrop, let error):
            // We forward *first*, drop *second*.
            context.write(data, promise: promise)
            for (_, promise) in writesToDrop {
                promise?.fail(error)
            }
        case .succeedAndDrop(let writesToDrop, let error):
            // We drop *first*, succeed *second*
            for (_, promise) in writesToDrop {
                promise?.fail(error)
            }
            promise?.succeed(())
        }
    }

    public func flush(context: ChannelHandlerContext) {
        self.frameBuffer.flushReceived()
        self.writeIfPossible(context: context)
        context.flush()
    }

    @discardableResult
    private func writeIfPossible(context: ChannelHandlerContext) -> Bool {
        // We need to spin our writing loop. How does this work?
        //
        // We may be buffering a number of frames for streams that are now ready to be unbuffered.
        // These streams will have become ready to be unbuffered due to some combination of flush
        // calls and stream closures. Here we loop forward over all buffers capable of being somewhat
        // unbuffered and punt those frames out. The act of punting those frames out may in fact cause
        // more streams to become able to be flushed, which is just fine: nothing bad should happen.
        var didWrite = false

        while let (frame, promise) = self.frameBuffer.nextFlushedWritableFrame() {
            context.write(self.wrapOutboundOut(frame), promise: promise)
            didWrite = true
        }

        return didWrite
    }
}


/// An object that manages buffering stream frames to avoid violating SETTINGS_MAX_CONCURRENT_STREAMS.
struct StreamFrameBuffer {
    fileprivate struct FrameBuffer {
        var frames: MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>
        var streamID: HTTP2StreamID
        var currentlyUnblocking: Bool

        init(streamID: HTTP2StreamID) {
            self.streamID = streamID
            self.frames = MarkedCircularBuffer(initialCapacity: 16)
            self.currentlyUnblocking = false
        }
    }

    /// The mode of the HTTP/2 channel in which we're operating: client or server.
    let mode: NIOHTTP2Handler.ParserMode

    /// The current number of active outbound streams.
    private(set) var currentOutboundStreams: Int = 0

    /// The maximum number of active outbound streams, as set by the remote peer.
    var maxOutboundStreams: Int

    /// The last outbound stream we initiated.
    private var lastOutboundStream: HTTP2StreamID = .rootStream

    /// The frames we've buffered are stored here.
    ///
    /// This circular buffer has an interesting property: by definition, it should always be sorted. This is because
    /// correct construction of new streams requires that stream IDs monotonically increase. As we always pop streams off the
    /// front and push them on the back of this buffer, it should remain in a sorted order forever. We have code that maintains
    /// this invariant.
    ///
    /// We regularly search this buffer, and rely on the ability to safely and quickly binary search this buffer.
    private var bufferedFrames = SortedCircularBuffer(initialRingCapacity: 16)

    init(mode: NIOHTTP2Handler.ParserMode, initialMaxOutboundStreams: Int) {
        self.mode = mode
        self.maxOutboundStreams = initialMaxOutboundStreams
    }

    /// Called when a stream has been closed.
    ///
    /// Notes that the current number of outbound streams may have gone down, which is useful information
    /// when flushing writes.
    mutating func streamClosed(_ streamID: HTTP2StreamID) {
        // We only care about outbound streams.
        if streamID.mayBeInitiatedBy(self.mode) {
            self.currentOutboundStreams -= 1
        }
    }

    mutating func streamCreated(_ streamID: HTTP2StreamID) {
        // We only care about outbound streams.
        guard streamID.mayBeInitiatedBy(self.mode) else {
            return
        }

        self.currentOutboundStreams += 1
        precondition(self.currentOutboundStreams <= self.maxOutboundStreams)
        precondition(self.lastOutboundStream <= streamID)
        self.lastOutboundStream = streamID
    }

    mutating func flushReceived() {
        self.bufferedFrames.markFlushPoint()
    }

    /// The result of receiving a frame that is about to be sent.
    enum OutboundFrameAction {
        /// The caller should forward the frame on.
        case forward

        /// This object has buffered the frame, no action should be taken.
        case nothing

        /// A number of frames have to be dropped on the floor due to a RST_STREAM frame being emitted, and the RST_STREAM
        /// frame itself must be forwarded.
        /// This cannot be done automatically without potentially causing exclusive access violations.
        case forwardAndDrop(MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>, NIOHTTP2Errors.StreamClosed)

        /// A number of frames have to be dropped on the floor due to a RST_STREAM frame being emitted, and the RST_STREAM
        /// frame itself should be succeeded and not forwarded.
        /// This cannot be done automatically without potentially causing exclusive access violations.
        case succeedAndDrop(MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>, NIOHTTP2Errors.StreamClosed)
    }

    mutating func processOutboundFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) throws -> OutboundFrameAction {
        // If this frame is not for a locally initiated stream, then that's fine, just pass it on.
        guard frame.streamID != .rootStream && frame.streamID.mayBeInitiatedBy(self.mode) else {
            return .forward
        }

        // Working out what to do here is awkward. The first concern is whether we're currently buffering frames for streams.
        // If we are, it's possible we're buffering frames for this stream already. That may happen even when the stream is technically
        // "live" if we have been re-entrantly called and haven't yet finished draining the buffer for this stream. As a result, if we're
        // buffering frames we need to check if we're buffering for this stream. If we are, we just append to that buffer. If we're not,
        // we don't yet know whether we should be buffering.
        //
        // Before we search our buffers for this stream we do a quick sanity check: if its stream ID is lower than the first element in the
        // array, it won't be there.
        if let firstElement = self.bufferedFrames.first,
            frame.streamID >= firstElement.streamID,
            let bufferIndex = self.bufferedFrames.binarySearch(key: { $0.streamID }, needle: frame.streamID) {
            return self.bufferFrame(frame, promise: promise, bufferIndex: bufferIndex)
        }

        // Ok, we're not currently buffering frames for this stream.
        // Now we need to check if this is for a stream that has already been opened. If it is, and we aren't buffering it, pass
        // the frame through.
        if frame.streamID <= self.lastOutboundStream {
            return .forward
        }

        // Now we want to see whether we're allowed to initiate a new stream. If we aren't, then we will buffer this stream.
        if self.currentOutboundStreams >= self.maxOutboundStreams {
            // Ok, we can't create a new stream. In this case we need to buffer this. We can only have gotten this far if either this stream ID is lower
            // than the first stream ID, or if it's higher but doesn't match something in the buffer. As a result, it is an error for this frame to have
            // a stream ID lower than or equal to the highest stream ID in the buffer: if it did, we should have found it when we searched above. If that
            // constraint is breached, fail the write.
            if let lastElement = self.bufferedFrames.last, frame.streamID <= lastElement.streamID {
                throw NIOHTTP2Errors.StreamIDTooSmall()
            }

            // Ok, the stream ID is fine: buffer this frame.
            self.bufferFrameForNewStream(frame, promise: promise)
            return .nothing
        }

        // Good news, we're allowed to send this frame! Let's do it.
        return .forward
    }

    /// Returns the next flushed frame on a stream that is either currently active or which can be
    /// made active.
    mutating func nextFlushedWritableFrame() -> (HTTP2Frame, EventLoopPromise<Void>?)? {
        // The stream buffers are bisected into two segments. The first, towards the start of the buffer,
        // are currently unblocking: that is, we have a buffer, but the stream has been initiated already.
        // The second set are those that have not currently been unblocked. Due to the requirements of
        // ascending stream ID, if any of these have been flushed then the first one *must* have been.
        // Thus, if we have room for another outbound stream, check the next stream and see if it has a
        // flushed frame. If it does, flip its unblocking bit to true and grab the next frame out of it.
        // Otherwise, we're done.
        var index = self.bufferedFrames.startIndex
        while index < self.bufferedFrames.endIndex {
            guard self.bufferedFrames[index].currentlyUnblocking else {
                // We've run out of currently unblocking frames. To the next step!
                break
            }

            if self.bufferedFrames[index].frames.hasMark {
                return self.bufferedFrames.nextWriteFor(index)
            }

            self.bufferedFrames.formIndex(after: &index)
        }

        // Ok, last shot. Does the next stream exist? If not, we're done.
        guard index < self.bufferedFrames.endIndex else {
            return nil
        }

        // Do we have room to start a new stream?
        guard self.currentOutboundStreams < self.maxOutboundStreams else {
            return nil
        }

        // We have room and the stream exists. Does it have flushed frames?
        guard self.bufferedFrames[index].frames.hasMark else {
            return nil
        }

        // It has flushed frames! Flip it to "unbuffering" and emit the first frame.
        self.bufferedFrames.beginUnblocking(index)
        return self.bufferedFrames.nextWriteFor(index)
    }

    private mutating func bufferFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?, bufferIndex index: SortedCircularBuffer.Index) -> OutboundFrameAction {
        // Ok, we need to buffer this frame, and we know we have the index for it. What we do here depends on this frame type. For
        // almost all frames, we just append them to the buffer. For RST_STREAM, however, we're in a different spot. RST_STREAM is a
        // request to drop all resources for a given stream. We know we have some, but we shouldn't wait to unblock them, we should
        // just kill them now and immediately free the resources.
        if case .rstStream(let reason) = frame.payload {
            // We're going to remove the buffer and fail all the writes.
            let writeBuffer = self.bufferedFrames.remove(at: index)

            // If we're currently unbuffering this stream, we need to pass the RST_STREAM frame on for correctness. If we aren't, just
            // kill it.
            if writeBuffer.currentlyUnblocking {
                return .forwardAndDrop(writeBuffer.frames, NIOHTTP2Errors.StreamClosed(streamID: frame.streamID, errorCode: reason))
            } else {
                return .succeedAndDrop(writeBuffer.frames, NIOHTTP2Errors.StreamClosed(streamID: frame.streamID, errorCode: reason))
            }
        }

        // Ok, this is a frame we want to buffer. Append it.
        self.bufferedFrames.bufferWrite(index: index, frame: frame, promise: promise)
        return .nothing
    }

    private mutating func bufferFrameForNewStream(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        // We need to buffer this frame. We should have previously checked that it's safe to buffer, so
        // we charge on.
        assert(self.bufferedFrames.count == 0 || (frame.streamID > self.bufferedFrames.last!.streamID))

        var frameBuffer = FrameBuffer(streamID: frame.streamID)
        frameBuffer.frames.append((frame, promise))
        self.bufferedFrames.append(frameBuffer, key: { $0.streamID })
    }
}

/// A simple wrapper around CircularBuffer that ensures that it remains sorted.
///
/// This removes CircularBuffer's MutableCollection conformance because it's not necessary
/// for our use-case here, and it greatly complicates the implementation. If we need it back
/// at any point we can arrange to return it.
///
/// I could have implemented this as a more general `SortedRandomAccessCollection` structure and
/// then provided specific hooks for appropriate implementations of `MutableCollection`, but altogether
/// that seemed unnecessary. Instead, we provide basically just the surface area we need, but with the
/// implementation of binarySearch written against the RandomAccessCollection protocol to make it more
/// portable in the future.
private struct SortedCircularBuffer {
    private var _base: CircularBuffer<StreamFrameBuffer.FrameBuffer>

    init(initialRingCapacity: Int) {
        self._base = CircularBuffer(initialCapacity: initialRingCapacity)
    }

    /// Appends an element to this CircularBuffer. Traps if the element is not larger than the current end of this buffer.
    mutating func append<SortKey: Comparable>(_ element: Element, key: (Element) -> SortKey) {
        if let last = self._base.last {
            precondition(key(element) >= key(last), "Attempted to append unsorted element")
        }

        self._base.append(element)
    }

    mutating func bufferWrite(index: Index, frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        // To make this work without CoW, we need to temporarily swap out either the entire element or the circular buffer within it to ensure that it
        // is held loosely. We choose to swap the circular buffer within it as it avoids even temporarily violating the invariant that the
        // backing array is sorted.
        assert(frame.streamID == self._base[index].streamID)

        var tempBuffer = MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>(initialCapacity: 0)
        swap(&tempBuffer, &self._base[index].frames)
        tempBuffer.append((frame, promise))
        swap(&tempBuffer, &self._base[index].frames)
    }

    mutating func beginUnblocking(_ index: Index) {
        assert(!self._base[index].currentlyUnblocking)
        self._base[index].currentlyUnblocking = true
    }

    mutating func nextWriteFor(_ index: Index) -> (HTTP2Frame, EventLoopPromise<Void>?) {
        // It is an error to call this when there is nothing in the backing buffer!

        // To make this work without CoW, we need to temporarily swap out either the entire element or the circular buffer within it to ensure that it
        // is held loosely. We choose to swap the circular buffer within it as it avoids even temporarily violating the invariant that the
        // backing array is sorted.
        var tempBuffer = MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>(initialCapacity: 0)
        swap(&tempBuffer, &self._base[index].frames)
        let write = tempBuffer.removeFirst()
        swap(&tempBuffer, &self._base[index].frames)

        if self._base[index].frames.count == 0 {
            // We're done here, drop the buffer.
            self._base.remove(at: index)
        }

        return write
    }

    mutating func remove(at index: Index) -> Element {
        // This one is easy: simple removal does what we need here.
        return self._base.remove(at: index)
    }

    mutating func markFlushPoint() {
        var index = self._base.startIndex
        while index < self._base.endIndex {
            // This cannot CoW as it doesn't modify the circular buffer underneath the MCB.
            self._base[index].frames.mark()
            self._base.formIndex(after: &index)
        }
    }
}

extension SortedCircularBuffer: RandomAccessCollection {
    typealias Element = CircularBuffer<StreamFrameBuffer.FrameBuffer>.Element
    typealias Index = CircularBuffer<StreamFrameBuffer.FrameBuffer>.Index
    typealias SubSequence = CircularBuffer<StreamFrameBuffer.FrameBuffer>.SubSequence
    typealias Indices = CircularBuffer<StreamFrameBuffer.FrameBuffer>.Indices

    var startIndex: Index {
        return self._base.startIndex
    }

    var endIndex: Index {
        return self._base.endIndex
    }

    var indices: Indices {
        return self._base.indices
    }

    func distance(from start: Index, to end: Index) -> Int {
        return self._base.distance(from: start, to: end)
    }

    func formIndex(after i: inout Index) {
        self._base.formIndex(after: &i)
    }

    func formIndex(before i: inout Index) {
        self._base.formIndex(before: &i)
    }

    func index(_ i: Index, offsetBy distance: Int) -> Index {
        return self._base.index(i, offsetBy: distance)
    }

    func index(_ i: Index, offsetBy distance: Int, limitedBy limit: Index) -> Index? {
        return self._base.index(i, offsetBy: distance, limitedBy: limit)
    }

    func index(after i: Index) -> Index {
        return self._base.index(after: i)
    }

    func index(before i: Index) -> Index {
        return self._base.index(before: i)
    }

    subscript(_ i: Index) -> Element {
        return self._base[i]
    }

    subscript(_ range: Range<Index>) -> SubSequence {
        return self._base[range]
    }
}

extension SortedCircularBuffer {
    func binarySearch<SearchKey: Comparable>(key: (Element) -> SearchKey, needle: SearchKey) -> Index? {
        var bottomIndex = self.startIndex
        var topIndex = self.endIndex
        var sliceSize = self.distance(from: bottomIndex, to: topIndex)

        while sliceSize > 0 {
            let middleIndex = self.index(bottomIndex, offsetBy: sliceSize / 2)

            switch key(self[middleIndex]) {
            case let potentialKey where potentialKey > needle:
                // Too big. We want to search everything smaller than here.
                topIndex = middleIndex
            case let potentialKey where potentialKey < needle:
                // Too small. We want to search everything larger than here.
                bottomIndex = self.index(after: middleIndex)
            case let potentialKey:
                // Got an answer!
                assert(potentialKey == needle)
                return middleIndex
            }

            sliceSize = self.distance(from: bottomIndex, to: topIndex)
        }

        return nil
    }
}


private extension HTTP2StreamID {
    func mayBeInitiatedBy(_ mode: NIOHTTP2Handler.ParserMode) -> Bool {
        switch mode {
        case .client:
            return self.networkStreamID % 2 == 1
        case .server:
            return self.networkStreamID % 2 == 0
        }
    }
}
