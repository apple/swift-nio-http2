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
import CNIONghttp2
import NIO

/// The static data provider read callback used by NIOHTTP2.
private func nghttp2DataProviderReadCallback(session: OpaquePointer?,
                                             streamID: Int32,
                                             targetBuffer: UnsafeMutablePointer<UInt8>?,
                                             targetBufferSize: Int,
                                             dataFlags: UnsafeMutablePointer<UInt32>?,
                                             source: UnsafeMutablePointer<nghttp2_data_source>?,
                                             userData: UnsafeMutableRawPointer?) -> Int {
    let dataProvider = Unmanaged<HTTP2DataProvider>.fromOpaque(source!.pointee.ptr).takeUnretainedValue()
    let writeResult = dataProvider.write(size: targetBufferSize)
    dataFlags!.pointee |= NGHTTP2_DATA_FLAG_NO_COPY.rawValue  // We do passthrough writes, always.

    switch writeResult {
    case .eof(let written):
        dataFlags!.pointee |= NGHTTP2_DATA_FLAG_EOF.rawValue
        return written
    case .written(let written) where written > 0:
        return written
    case .written(let written):
        assert(written == 0)
        return Int(NGHTTP2_ERR_DEFERRED.rawValue)
    }
}

/// A nghttp2 data provider for DATA frames on a single stream.
///
/// nghttp2 writes data frames using so-called "data" providers. These are entities that can write
/// data into nghttp2's buffers whenever nghttp2 is trying to serialize a data frame, or that can
/// write data directly to the network. These are reference objects, as they must be passed by
/// pointer into nghttp2.
///
/// As a general note, nghttp2 allows pausing and resuming the sending of data frames on a given
/// stream. This data provider knows how to signal that state for nghttp2. It also knows how to tell
/// nghttp2 when the last data frame has been received.
///
/// This provider also plays by the standard channel rules for flushing data: specifically, it knows
/// not to deliver unflushed data.
class HTTP2DataProvider {
    /// A single buffered write.
    enum BufferedWrite {
        case eof
        case write(IOData, EventLoopPromise<Void>?)
    }

    /// The result of writing into a given buffer.
    enum WriteResult {
        /// We wrote some number of bytes.
        case written(Int)

        /// We wrote some number of bytes, and no more are coming.
        case eof(Int)
    }

    /// The current state of this provider.
    enum State {
        /// Currently idle: nghttp2 has not yet asked this provider for
        /// data.
        case idle

        /// Currently writing: nghttp2 has asked this provider for data and
        /// the last time it asked this provider had data to provide.
        case writing

        /// Currently awaiting more data to write: nghttp2 has asked this provider
        /// for data, but the last time it asked this provider had no data to provide
        /// and asked nghttp2 to temporarily stop requesting it.
        case pending

        /// Complete: the provider has sent all data including EOF. nghttp2 will not ask
        /// this provider for further data.
        case eof

        /// Called when we have written some data. Potentially transitions the state of the enum.
        fileprivate mutating func wroteData(_ count: Int) {
            switch (self, count) {
            case (.idle, 0):
                self = .pending
            case (.idle, _):
                assert(count > 0)
                self = .writing
            case (.pending, let x) where x > 0:
                self = .writing
            case (.writing, let x) where x == 0:
                self = .pending

            // For EOF, it should not be possible to write bytes in the EOF state.
            // This assertion checks that.
            case (.eof, _):
                assertionFailure("Should not write data when in EOF state")

            // These two cases are to make the enum exhaustive: they contain
            // only assertions to validate correctness.
            case (.pending, let x):
                assert(x == 0)
            case (.writing, let x):
                assert(x > 0)
            }
        }

        /// Called when we sent EOF.
        fileprivate mutating func sentEOF() {
            switch self {
            case .idle, .pending, .writing:
                self = .eof
            case .eof:
                assertionFailure("Transitioned into EOF when in state \(self)")
            }
        }
    }

    /// The buffer of pending writes.
    private var writeBuffer: MarkedCircularBuffer<BufferedWrite> = MarkedCircularBuffer(initialRingCapacity: 8)

    /// The number of flushed bytes currently in `writeBuffer`.
    private var flushedBufferedBytes = 0

    /// The number of bytes written to the last data frame.
    private var lastDataFrameSize = -1

    /// The promise to fulfil for all pending writes. Should be extracted when a write is
    /// being emitted and passed onto that frame write.
    var completedWritePromise: EventLoopPromise<Void>?

    /// The current state of this provider.
    var state: State = .idle

    /// The current index of the write we have written up to.
    ///
    /// This value is used to support nghttp2's "pass through writes", while maximising efficiency. This index
    /// should be valid only for extremely short periods of time.
    // TODO(cory): Consider merging into a structure with `writeBuffer`.
    private var writtenToIndex = -1

    /// An nghttp2_data_provider corresponding to this object.
    internal var nghttp2DataProvider: nghttp2_data_provider {
        var dp = nghttp2_data_provider()
        dp.source = .init(ptr: UnsafeMutableRawPointer(Unmanaged<HTTP2DataProvider>.passUnretained(self).toOpaque()))
        dp.read_callback = nghttp2DataProviderReadCallback
        return dp
    }

    /// Buffer a stream write.
    func bufferWrite(write: IOData, promise: EventLoopPromise<Void>?) {
        self.writeBuffer.append(.write(write, promise))
    }

    /// Buffer the EOF flag.
    func bufferEOF() {
        self.writeBuffer.append(.eof)
    }

    /// Mark that we have flushed up to this point.
    func markFlushCheckpoint() {
        self.writeBuffer.mark()
        self.updateFlushedWriteCount()
    }

    /// Prepare a number of writes for emitting into a data frame.
    ///
    /// This function does not actually do anything: it just prepares for actually sending the data in the next
    /// stage. This is because we use "pass-through" writes to avoid copying data around.
    func write(size: Int) -> WriteResult {
        precondition(size > 0, "Asked to write \(size) bytes")
        precondition(self.lastDataFrameSize == -1, "write called before any written data was popped")

        let bytesToWrite = min(size, self.flushedBufferedBytes)
        self.lastDataFrameSize = bytesToWrite

        if self.reachedEOF(bytesToWrite: bytesToWrite) {
            self.state.sentEOF()
            return .eof(bytesToWrite)
        } else {
            self.state.wroteData(bytesToWrite)
            return .written(bytesToWrite)
        }
    }

    /// Calls `body` once for each write that needs to be emitted in a data frame.
    ///
    /// - parameters:
    ///     - body: The callback to be invoked for each element in the data frame. Will be invoked with both
    //          the `IOData` of the write and the promise associated with that write, if any.
    func forWriteInDataFrame(_ body: (IOData, EventLoopPromise<Void>?) -> Void) {
        while self.lastDataFrameSize > 0 {
            let write = self.writeBuffer.first!

            switch write {
            case .write(let data, var promise):
                let write: IOData
                if self.lastDataFrameSize < data.readableBytes {
                    write = sliceWrite(write: data, promise: promise, writeSize: self.lastDataFrameSize)
                    promise = nil
                } else {
                    write = data
                }

                self.flushedBufferedBytes -= write.readableBytes
                self.lastDataFrameSize -= write.readableBytes
                body(write, promise)
                _ = self.writeBuffer.removeFirst()
            case .eof:
                preconditionFailure("Should never write over EOF")
            }
        }

        // Zero length writes are a thing, we need to pull them off the queue here and dispatch them as well or
        // we run the risk of leaking promises.
        while self.writeBuffer.hasMark() {
            guard case .write(let write, let promise) = self.writeBuffer.first!, write.readableBytes == 0 else {
                break
            }

            body(write, promise)
            _ = self.writeBuffer.removeFirst()
        }

        assert(self.lastDataFrameSize == 0)
        self.lastDataFrameSize = -1
    }

    /// Tells us whether the write we're about to emit includes EOF.
    ///
    /// The write includes EOF if a) the marked entity is an EOF marker, and
    /// if b) the write size is all of our buffered writes.
    private func reachedEOF(bytesToWrite: Int) -> Bool {
        guard bytesToWrite == self.flushedBufferedBytes else {
            return false
        }

        if case .some(.eof) = self.writeBuffer.markedElement() {
            return true
        } else {
            return false
        }
    }

    /// Performs a partial write of the given `IOData`, writing only `writeSize` bytes and putting the
    /// rest of the write back on the buffer along with its associated `EventLoopPromise`.
    ///
    /// - parameters:
    ///     - write: The `IOData` to slice.
    ///     - promise: The `EventLoopPromise` associated with this `IOData`.
    /// - returns: The writable portion of the `IOData`.
    private func sliceWrite(write: IOData, promise: EventLoopPromise<Void>?, writeSize: Int) -> IOData {
        switch write {
        case .byteBuffer(var b):
            assert(b.readableBytes < writeSize)
            let bufferToWrite = b.readSlice(length: writeSize)!
            self.writeBuffer[self.writeBuffer.startIndex] = .write(.byteBuffer(b), promise)
            return .byteBuffer(bufferToWrite)
        case .fileRegion(var f):
            assert(f.readableBytes < writeSize)
            let fileToWrite = FileRegion(fileHandle: f.fileHandle, readerIndex: f.readerIndex, endIndex: f.readerIndex + writeSize)
            f.moveReaderIndex(forwardBy: writeSize)
            self.writeBuffer[self.writeBuffer.startIndex] = .write(.fileRegion(f), promise)
            return .fileRegion(fileToWrite)
        }
    }

    /// Updates the count of the flushed bytes. Used to keep track of how much data is outstanding to write.
    private func updateFlushedWriteCount() {
        self.flushedBufferedBytes = 0

        guard let markIndex = self.writeBuffer.markedElementIndex() else {
            return
        }

        for idx in (self.writeBuffer.startIndex...markIndex) {
            switch self.writeBuffer[idx]{
            case .write(let d, _):
                self.flushedBufferedBytes += d.readableBytes
            case .eof:
                assert(idx == markIndex)
            }
        }
    }
}
