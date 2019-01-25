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

public class NIOHTTP2FlowControlHandler: ChannelDuplexHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    /// A buffer of the data sent on the stream that has not yet been passed to the the connection state machine.
    private var streamDataBuffers: [HTTP2StreamID: StreamFlowControlState]

    // TODO(cory): This will eventually need to grow into a priority implementation. For now, it's sufficient to just
    // use a set and worry about the data structure costs later.
    /// The streams with pending data to output.
    private var flushableStreams: Set<HTTP2StreamID> = Set()

    /// The current size of the connection flow control window. May be negative.
    private var connectionWindowSize: Int

    /// The current value of SETTINGS_MAX_FRAME_SIZE set by the peer.
    private var maxFrameSize: Int

    /// Whether we need to flush on channelReadComplete.
    private var needToFlush = false

    public init(initialConnectionWindowSize: Int = 65535, initialMaxFrameSize: Int = 1<<14) {
        /// By and large there won't be that many concurrent streams floating around, so we pre-allocate a decent-ish
        /// size.
        // TODO(cory): HEAP! This should be a heap, sorted off the number of pending bytes!
        self.streamDataBuffers = Dictionary(minimumCapacity: 16)
        self.connectionWindowSize = initialConnectionWindowSize
        self.maxFrameSize = initialMaxFrameSize
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        switch frame.payload {
        case .data(let body):
            // We buffer DATA frames.
            if !self.streamDataBuffers[frame.streamID].apply({ $0.dataBuffer.bufferWrite((.data(body), frame.flags, promise)) }) {
                // We don't have this stream ID. This is an internal error, but we won't precondition on it as
                // it can happen due to channel handler misconfiguration or other weirdness. We'll just complain.
                let error = NIOHTTP2Errors.NoSuchStream(streamID: frame.streamID)
                promise?.fail(error: error)
                ctx.fireErrorCaught(error)
            }
        case .headers(let headers, let priorityData):
            // Headers are special. If we have a data frame buffered, we buffer behind it to avoid frames
            // being reordered. However, if we don't have a data frame buffered we pass the headers frame on
            // immediately, as there is no risk of violating ordering guarantees.
            let bufferResult = self.streamDataBuffers[frame.streamID].modify { (state: inout StreamFlowControlState) -> Bool in
                if state.dataBuffer.haveBufferedDataFrame {
                    state.dataBuffer.bufferWrite((.headers(headers, priorityData), frame.flags, promise))
                    return true
                } else {
                    return false
                }
            }

            switch bufferResult {
            case .some(true):
                // Buffered, do nothing.
                break
            case .some(false), .none:
                // We don't need to buffer this, pass it on.
                ctx.write(data, promise: promise)
            }
        default:
            // For all other frame types, we don't care about them, pass them on.
            ctx.write(data, promise: promise)
        }
    }

    public func flush(ctx: ChannelHandlerContext) {
        // Two stages of flushing. The first thing is to mark the flush point on all of the streams we have.
        self.streamDataBuffers.mutatingForEachValue {
            let hadData = $0.hasPendingData
            $0.dataBuffer.markFlushPoint()
            if $0.hasPendingData && !hadData {
                assert(!self.flushableStreams.contains($0.streamID))
                self.flushableStreams.insert($0.streamID)
            }
        }

        // Ok, we want to send as much data as we can.
        // This loop here is a while because we make outcalls here, and these outcalls
        // may cause re-entrant behaviour. We need to not be holding our structures mutably
        // over the duration of this outcall.
        self.writeIfPossible(ctx: ctx)
        ctx.flush()
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as NIOHTTP2WindowUpdatedEvent:
            // We don't try to write here, we do it in channelReadComplete or flush.
            self.updateWindowOfStream(event.streamID, newSize: event.newWindowSize)
        case let event as StreamClosedEvent:
            self.streamClosed(event.streamID, errorCode: event.reason ?? .streamClosed)
        case let event as NIOHTTP2StreamCreatedEvent:
            self.streamCreated(event.streamID, initialWindowSize: event.localInitialWindowSize)
        default:
            break
        }

        ctx.fireUserInboundEventTriggered(event)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        if case .settings(let newSettings) = frame.payload, !frame.flags.contains(.ack) {
            // This is a SETTINGS frame for new settings from the remote peer. We
            // should apply this change. We only care about the value of SETTINGS_MAX_FRAME_SIZE:
            // settings changes that affect flow control windows are notified to us in other ways.
            if let newMaxFrameSize = newSettings.reversed().first(where: {$0.parameter == .maxFrameSize})?.value {
                self.maxFrameSize = newMaxFrameSize
            }
        }

        ctx.fireChannelRead(data)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        let didWrite = self.writeIfPossible(ctx: ctx)
        if didWrite {
            ctx.flush()
        }
    }

    private func nextStreamToSend() -> HTTP2StreamID? {
        return self.flushableStreams.first
    }

    private func updateWindowOfStream(_ streamID: HTTP2StreamID, newSize: Int32) {
        if streamID == .rootStream {
            self.connectionWindowSize = Int(newSize)
        } else {
            // We don't bother to check for missing stream dictionaries here, as we operate
            // in a concurrent world where all sorts of weird nonsense can occur.
            // If we have got the window update for the stream after the stream was closed
            // or before it was opened, that's ok, do nothing.
            self.streamDataBuffers[streamID].apply {
                let hadData = $0.hasPendingData
                $0.currentWindowSize = Int(newSize)
                if $0.hasPendingData && !hadData {
                    assert(!self.flushableStreams.contains($0.streamID))
                    self.flushableStreams.insert($0.streamID)
                }
            }
        }
    }

    private func streamCreated(_ streamID: HTTP2StreamID, initialWindowSize: UInt32) {
        assert(streamID != .rootStream)

        let streamState = StreamFlowControlState(streamID: streamID, initialWindowSize: Int(initialWindowSize))
        self.streamDataBuffers[streamID] = streamState
    }

    // We received a stream closed event. Drop any stream state we're holding. If we have any
    // unflushed or buffered DATA frames, we fail their promises.
    private func streamClosed(_ streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode) {
        self.flushableStreams.remove(streamID)
        guard var streamData = self.streamDataBuffers.removeValue(forKey: streamID) else {
            // Huh, we didn't have any data for this stream. Oh well. That was easy.
            return
        }
        streamData.failAllWrites(error: NIOHTTP2Errors.StreamClosed(streamID: streamID, errorCode: errorCode))
    }

    /// Writes whatever data may be written in a loop.
    ///
    /// - returns: Whether this issued a write.
    @discardableResult
    private func writeIfPossible(ctx: ChannelHandlerContext) -> Bool {
        // This loop here is a while because we make outcalls here, and these outcalls
        // may cause re-entrant behaviour. We need to not be holding our structures mutably
        // over the duration of this outcall.
        var didWrite = false

        while let nextStreamID = self.nextStreamToSend(), self.connectionWindowSize > 0 {
            let nextWrite = self.streamDataBuffers[nextStreamID].modify { (state: inout StreamFlowControlState) -> DataBuffer.BufferElement in
                let nextWrite = state.nextWrite(maxSize: min(self.connectionWindowSize, self.maxFrameSize))
                if !state.hasPendingData {
                    self.flushableStreams.remove(nextStreamID)
                }
                return nextWrite
            }
            guard let (payload, flags, promise) = nextWrite else {
                // The stream was not present. This is weird, it shouldn't ever happen, but we tolerate it
                self.flushableStreams.remove(nextStreamID)
                continue
            }

            let frame = HTTP2Frame(streamID: nextStreamID, flags: flags, payload: payload)
            ctx.write(self.wrapOutboundOut(frame), promise: promise)
            didWrite = true
        }

        return didWrite
    }
}


private struct StreamFlowControlState {
    let streamID: HTTP2StreamID
    var currentWindowSize: Int
    var dataBuffer: DataBuffer

    var hasPendingData: Bool {
        return self.dataBuffer.hasMark && (self.currentWindowSize > 0 || self.dataBuffer.nextWriteIsHeaders)
    }

    init(streamID: HTTP2StreamID, initialWindowSize: Int) {
        self.streamID = streamID
        self.currentWindowSize = initialWindowSize
        self.dataBuffer = DataBuffer()
    }

    mutating func nextWrite(maxSize: Int) -> DataBuffer.BufferElement {
        assert(maxSize > 0)
        let writeSize = min(maxSize, currentWindowSize)
        let nextWrite = self.dataBuffer.nextWrite(maxSize: writeSize)

        if case .data(let payload) = nextWrite.0 {
            self.currentWindowSize -= payload.readableBytes
        }

        assert(self.currentWindowSize >= 0)
        return nextWrite
    }

    mutating func failAllWrites(error: Error) {
        self.dataBuffer.failAllWrites(error: error)
    }
}


private struct DataBuffer {
    typealias BufferElement = (HTTP2Frame.FramePayload, HTTP2Frame.FrameFlags, EventLoopPromise<Void>?)

    private var bufferedChunks: MarkedCircularBuffer<BufferElement>

    internal private(set) var flushedBufferedBytes: UInt

    var haveBufferedDataFrame: Bool {
        return self.bufferedChunks.count > 0
    }

    var nextWriteIsHeaders: Bool {
        if case .some(.headers) = self.bufferedChunks.first?.0 {
            return true
        } else {
            return false
        }
    }

    var hasMark: Bool {
        return self.bufferedChunks.hasMark()
    }

    init() {
        self.bufferedChunks = MarkedCircularBuffer(initialRingCapacity: 8)
        self.flushedBufferedBytes = 0
    }

    mutating func bufferWrite(_ write: BufferElement) {
        self.bufferedChunks.append(write)
    }

    /// Marks the current point in the buffer as the place up to which we have flushed.
    mutating func markFlushPoint() {
        if let markIndex = self.bufferedChunks.markedElementIndex() {
            for element in self.bufferedChunks.suffix(from: markIndex) {
                if case .data(let contents) = element.0 {
                    self.flushedBufferedBytes += UInt(contents.readableBytes)
                }
            }
            self.bufferedChunks.mark()
        } else if self.bufferedChunks.count > 0 {
            for element in self.bufferedChunks {
                if case .data(let contents) = element.0 {
                    self.flushedBufferedBytes += UInt(contents.readableBytes)
                }
            }
            self.bufferedChunks.mark()
        }
    }

    mutating func nextWrite(maxSize: Int) -> BufferElement {
        assert(maxSize >= 0)
        precondition(self.bufferedChunks.count > 0)

        let firstElementIndex = self.bufferedChunks.startIndex

        // First check that the next write is DATA. If it's not, just pass it on.
        guard case .data(var contents) = self.bufferedChunks[firstElementIndex].0 else {
            return self.bufferedChunks.removeFirst()
        }

        // Now check if we have enough space to return the next DATA frame wholesale.
        let firstElementReadableBytes = contents.readableBytes
        if firstElementReadableBytes <= maxSize {
            // Return the whole element.
            self.flushedBufferedBytes -= UInt(firstElementReadableBytes)
            return self.bufferedChunks.removeFirst()
        }

        // Here we have too many bytes. So we need to slice out a copy of the data we need
        // and leave the rest.
        let newElement = contents.slicePrefix(maxSize)
        self.flushedBufferedBytes -= UInt(maxSize)
        self.bufferedChunks[0].0 = .data(contents)
        return (.data(newElement), HTTP2Frame.FrameFlags(), nil)
    }

    mutating func failAllWrites(error: Error) {
        while self.bufferedChunks.count > 0 {
            let (_, _, promise) = self.bufferedChunks.removeFirst()
            promise?.fail(error: error)
        }
    }
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


private extension Optional where Wrapped == StreamFlowControlState {
    // This function exists as a performance optimisation: by mutating the optional returned from Dictionary directly
    // inline, we can avoid the dictionary needing to hash the key twice, which it would have to do if we removed the
    // value, mutated it, and then re-inserted it.
    //
    // However, we need to be a bit careful here, as the performance gain from doing this would be completely swamped
    // if the Swift compiler failed to inline this method into its caller. This would force the closure to have its
    // context heap-allocated, and the cost of doing that is vastly higher than the cost of hashing the key a second
    // time. So for this reason we make it clear to the compiler that this method *must* be inlined at the call-site.
    // Sorry about doing this!
    //
    /// Apply a transform to a wrapped DataBuffer.
    ///
    /// - parameters:
    ///     - body: A block that will modify the contained value in the
    ///         optional, if there is one present.
    /// - returns: Whether the value was present or not.
    @inline(__always)
    @discardableResult
    mutating func apply(_ body: (inout Wrapped) -> Void) -> Bool {
        if self == nil {
            return false
        }

        var unwrapped = self!
        self = nil
        body(&unwrapped)
        self = unwrapped
        return true
    }

    // This function exists as a performance optimisation: by mutating the optional returned from Dictionary directly
    // inline, we can avoid the dictionary needing to hash the key twice, which it would have to do if we removed the
    // value, mutated it, and then re-inserted it.
    //
    // However, we need to be a bit careful here, as the performance gain from doing this would be completely swamped
    // if the Swift compiler failed to inline this method into its caller. This would force the closure to have its
    // context heap-allocated, and the cost of doing that is vastly higher than the cost of hashing the key a second
    // time. So for this reason we make it clear to the compiler that this method *must* be inlined at the call-site.
    // Sorry about doing this!
    //
    /// Apply a transform to a wrapped DataBuffer and return the result.
    ///
    /// - parameters:
    ///     - body: A block that will modify the contained value in the
    ///         optional, if there is one present.
    /// - returns: The return value of the modification, or nil if there was no object to modify.
    mutating func modify<T>(_ body: (inout Wrapped) -> T) -> T? {
        if self == nil {
            return nil
        }

        var unwrapped = self!
        self = nil
        let r = body(&unwrapped)
        self = unwrapped
        return r
    }
}
