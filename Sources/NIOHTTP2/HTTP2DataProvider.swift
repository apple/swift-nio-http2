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
import NIOHTTP1

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
    case .eof(let written, let trailers):
        dataFlags!.pointee |= NGHTTP2_DATA_FLAG_EOF.rawValue
        if let trailers = trailers {
            // If there are trailers to submit, we want to set NO_END_STREAM as the trailers will carry
            // END_STREAM.
            dataFlags!.pointee |= NGHTTP2_DATA_FLAG_NO_END_STREAM.rawValue

            // Annoyingly we have to submit the trailers here.
            // TODO(cory): error handling or something
            // TODO(cory): Get this allocator from somewhere my god.
            let rc = trailers.withNGHTTP2Headers(allocator: ByteBufferAllocator()) {
                nghttp2_submit_trailer(session, streamID, $0, $1)
            }
            precondition(rc == 0)
        }
        return written
    case .written(let written):
        assert(written > 0)
        return written
    case .framePending:
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
        case eof(HTTPHeaders?)
        case write(IOData, EventLoopPromise<Void>?)
    }

    /// The result of writing into a given buffer.
    enum WriteResult {
        /// We wrote some number of bytes.
        case written(Int)

        /// We wrote some number of bytes, and no more are coming.
        case eof(Int, HTTPHeaders?)

        /// We have no bytes to write now, but more are coming.
        case framePending
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

        /// We are in an error state, and can no longer be used.
        case error

        fileprivate mutating func resumed() {
            precondition(self == .pending, "Resumed while in state \(self)")
            self = .writing
        }

        /// Called when we have written some data. Potentially transitions the state of the enum.
        fileprivate mutating func wroteData(_ count: Int) {
            assert(count > 0)
            switch self {
            case .eof, .pending, .error:
                preconditionFailure("Should not write data when in state \(self)")
            case .idle, .writing:
                self = .writing
            }
        }

        /// Called when we sent EOF.
        fileprivate mutating func sentEOF() {
            switch self {
            case .eof, .error, .pending:
                preconditionFailure("Sent EOF when in state \(self)")
            case .idle, .writing:
                self = .eof
            }
        }

        /// Called when we had no data to send.
        fileprivate mutating func awaitingData() {
            switch self {
            case .eof, .error, .pending:
                preconditionFailure("Asked to write data in state \(self)")
            case .idle, .writing:
                self = .pending
            }
        }
    }

    /// The buffer of pending writes.
    private var writeBuffer: CircularBuffer<BufferedWrite> = CircularBuffer(initialRingCapacity: 8)

    /// The number of flushed bytes currently in `writeBuffer`.
    private var flushedBufferedBytes = 0

    /// The number of bytes written to the last data frame.
    private var lastDataFrameSize = -1

    /// The current state of this provider.
    var state: State = .idle

    private var mayWrite: Bool {
        return self.state != .error
    }

    /// An nghttp2_data_provider corresponding to this object.
    internal var nghttp2DataProvider: nghttp2_data_provider {
        var dp = nghttp2_data_provider()
        dp.source = .init(ptr: UnsafeMutableRawPointer(Unmanaged<HTTP2DataProvider>.passUnretained(self).toOpaque()))
        dp.read_callback = nghttp2DataProviderReadCallback
        return dp
    }

    /// Buffer a stream write.
    func bufferWrite(write: IOData, promise: EventLoopPromise<Void>?) {
        precondition(self.mayWrite)
        self.writeBuffer.append(.write(write, promise))
        self.flushedBufferedBytes += write.readableBytes
    }

    /// Buffer the EOF flag. The EOF may optionally also contain trailers.
    func bufferEOF(trailers: HTTPHeaders?) {
        precondition(self.mayWrite)
        self.writeBuffer.append(.eof(trailers))
    }

    /// Prepare a number of writes for emitting into a data frame.
    ///
    /// This function does not actually do anything: it just prepares for actually sending the data in the next
    /// stage. This is because we use "pass-through" writes to avoid copying data around.
    func write(size: Int) -> WriteResult {
        precondition(self.mayWrite)
        precondition(size > 0, "Asked to write \(size) bytes")
        precondition(self.lastDataFrameSize == -1, "write called before any written data was popped")

        let bytesToWrite = min(size, self.flushedBufferedBytes)
        self.lastDataFrameSize = bytesToWrite

        if self.reachedEOF(bytesToWrite: bytesToWrite) {
            self.state.sentEOF()
            return .eof(bytesToWrite, self.trailers)
        } else if bytesToWrite > 0 {
            self.state.wroteData(bytesToWrite)
            return .written(bytesToWrite)
        } else {
            assert(bytesToWrite == 0)
            // Set this to -1 as we won't actually write a frame here.
            self.lastDataFrameSize = -1
            self.state.awaitingData()
            return .framePending
        }
    }

    /// Calls `body` once for each write that needs to be emitted in a data frame.
    ///
    /// - parameters:
    ///     - body: The callback to be invoked for each element in the data frame. Will be invoked with both
    //          the `IOData` of the write and the promise associated with that write, if any.
    func forWriteInDataFrame(_ body: (IOData, EventLoopPromise<Void>?) -> Void) {
        precondition(self.mayWrite)
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
                    _ = self.writeBuffer.removeFirst()
                }

                self.flushedBufferedBytes -= write.readableBytes
                self.lastDataFrameSize -= write.readableBytes
                body(write, promise)
            case .eof:
                preconditionFailure("Should never write over EOF")
            }
        }

        // Zero length writes are a thing, we need to pull them off the queue here and dispatch them as well or
        // we run the risk of leaking promises.
        while self.writeBuffer.count > 0 {
            guard case .write(let write, let promise) = self.writeBuffer.first!, write.readableBytes == 0 else {
                break
            }

            body(write, promise)
            _ = self.writeBuffer.removeFirst()
        }

        assert(self.lastDataFrameSize == 0)
        self.lastDataFrameSize = -1
    }

    // We're done here, report as much.
    func failAllWrites(error: Error) {
        precondition(self.mayWrite)
        self.state = .error
        self.flushedBufferedBytes = 0
        self.lastDataFrameSize = -1

        let bufferedWrites = self.writeBuffer
        self.writeBuffer = CircularBuffer(initialRingCapacity: 0)
        bufferedWrites.forEach {
            if case .write(_, let p) = $0 {
                p?.fail(error: error)
            }
        }
    }

    /// Called when sending data has been resumed by the session.
    func didResume() {
        self.state.resumed()
    }

    /// Obtains the trailers for this stream, if any.
    private var trailers: HTTPHeaders? {
        guard case .eof(let trailers) = self.writeBuffer[self.writeBuffer.endIndex - 1] else {
            return nil
        }
        return trailers
    }

    /// Tells us whether the write we're about to emit includes EOF.
    ///
    /// The write includes EOF if a) the marked entity is an EOF marker, and
    /// if b) the write size is all of our buffered writes.
    private func reachedEOF(bytesToWrite: Int) -> Bool {
        guard bytesToWrite == self.flushedBufferedBytes else {
            return false
        }

        guard self.writeBuffer.count > 0 else {
            return false
        }

        if case .eof = self.writeBuffer[self.writeBuffer.endIndex - 1] {
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
            assert(b.readableBytes > writeSize)
            let bufferToWrite = b.readSlice(length: writeSize)!
            self.writeBuffer[self.writeBuffer.startIndex] = .write(.byteBuffer(b), promise)
            return .byteBuffer(bufferToWrite)
        case .fileRegion(var f):
            assert(f.readableBytes > writeSize)
            let fileToWrite = FileRegion(fileHandle: f.fileHandle, readerIndex: f.readerIndex, endIndex: f.readerIndex + writeSize)
            f.moveReaderIndex(forwardBy: writeSize)
            self.writeBuffer[self.writeBuffer.startIndex] = .write(.fileRegion(f), promise)
            return .fileRegion(fileToWrite)
        }
    }
}
