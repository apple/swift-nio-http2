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

public enum RingBufferError {
    /// Error type thrown when a write would overrun the bounds of a
    /// CircularByteBuffer.
    public struct BufferOverrun : Error, Equatable {
        /// The amount by which the write would overrun.
        public let amount: Int
        
        public init(amount: Int) {
            self.amount = amount
        }
    }
}

@usableFromInline
internal func _toIndex(_ value: Int) -> SimpleRingBuffer.Index {
    return SimpleRingBuffer.Index(truncatingIfNeeded: value)
}

@usableFromInline
internal func _toCapacity(_ value: Int) -> SimpleRingBuffer.Capacity {
    return SimpleRingBuffer.Capacity(truncatingIfNeeded: value)
}

@usableFromInline
func _wrappingDifference(from: SimpleRingBuffer.Index, to: SimpleRingBuffer.Index, within: SimpleRingBuffer.Capacity) -> SimpleRingBuffer.Capacity {
    if from <= to {
        return to - from
    } else {
        return (within - from) + to
    }
}

public struct SimpleRingBuffer {
    typealias Index = UInt32
    typealias Capacity = UInt32
    
    @usableFromInline private(set) var _storage: _Storage
    @usableFromInline private(set) var _readerIndex: Index = 0
    @usableFromInline private(set) var _writerIndex: Index = 0
    @usableFromInline private(set) var _readableBytes: Capacity = 0
    
    @usableFromInline
    final class _Storage {
        @usableFromInline private(set) var capacity: Capacity
        @usableFromInline private(set) var bytes: UnsafeMutableRawPointer
        
        public init(bytesNoCopy: UnsafeMutableRawPointer, capacity: Capacity) {
            self.capacity = capacity
            self.bytes = bytesNoCopy
        }
        
        deinit {
            self.bytes.deallocate()
        }
        
        private static func allocateAndPrepareRawMemory(bytes: Capacity) -> UnsafeMutableRawPointer {
            let bytes = Int(bytes)
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 1)
            ptr.bindMemory(to: UInt8.self, capacity: bytes) // bind to ensure we can treat it as UInt8 elsewhere
            return ptr
        }
        
        public func allocateStorage() -> _Storage {
            return self.allocateStorage(capacity: self.capacity)
        }
        
        private func allocateStorage(capacity: Capacity) -> _Storage {
            let capacity = capacity == 0 ? Capacity(PAGE_SIZE) : capacity
            return _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: capacity),
                            capacity: capacity)
        }
        
        public func duplicate() -> _Storage {
            let new = self.allocateStorage()
            new.bytes.copyMemory(from: self.bytes, byteCount: Int(self.capacity))
            return new
        }
        
        public func reallocSlice(_ slice: Range<Index>, capacity: Capacity) -> _Storage {
            assert(slice.count <= capacity)
            let new = self.allocateStorage(capacity: capacity)
            new.bytes.copyMemory(from: self.bytes.advanced(by: Int(slice.lowerBound)), byteCount: slice.count)
            return new
        }
        
        public func copySlice(_ slice: Range<Index>, from source: _Storage, to index: Index) {
            assert(slice.count + Int(index) <= self.capacity)
            self.bytes.advanced(by: Int(index)).copyMemory(from: source.bytes.advanced(by: Int(slice.lowerBound)), byteCount: slice.count)
        }
        
        /// Moves the bytes in the specified range to the start of the allocated buffer.
        public func rebaseSlice(_ slice: Range<Index>, to target: Index = 0) {
            assert(slice.upperBound <= self.capacity)
            self.bytes.advanced(by: Int(target)).copyMemory(from: self.bytes.advanced(by: Int(slice.lowerBound)), byteCount: slice.count)
        }
        
        public func copyIn(_ source: UnsafeRawPointer, length: Capacity, to index: Index) {
            assert(index + length <= self.capacity)
            self.bytes.advanced(by: Int(index)).copyMemory(from: source, byteCount: Int(length))
        }
        
        public func reallocStorage(capacity newCapacity: Capacity) {
            let ptr = realloc(self.bytes, Int(newCapacity))!
            ptr.bindMemory(to: UInt8.self, capacity: Int(newCapacity))
            self.bytes = ptr
            self.capacity = newCapacity
        }
        
        private func deallocate() {
            bytes.deallocate()
        }
        
        public static func reallocated(newCapacity: Capacity) -> _Storage {
            return _Storage(bytesNoCopy: allocateAndPrepareRawMemory(bytes: newCapacity),
                            capacity: newCapacity)
        }
        
        public func dumpBytes(range: Range<Index>) -> String {
            var desc = "["
            for i in range {
                let byte = self.bytes.advanced(by: Int(i)).assumingMemoryBound(to: UInt8.self).pointee
                let hexByte = String(byte, radix: 16)
                desc += " \(hexByte.count == 1 ? "0" : "")\(hexByte)"
            }
            desc += "]"
            return desc
        }
    }
    
    fileprivate init(existingStorage: _Storage, readIndex: Index, writeIndex: Index) {
        self._storage = existingStorage
        self._readerIndex = readIndex
        self._writerIndex = writeIndex
        self._readableBytes = NIOHPACK._wrappingDifference(from: readIndex, to: writeIndex, within: existingStorage.capacity)
    }
    
    internal func _makeContiguousCopy() -> SimpleRingBuffer {
        let newBytes = _storage.allocateStorage()
        switch (_readerIndex, _writerIndex) {
        case (0, let w):
            // contiguous from start of buffer
            newBytes.copyIn(_storage.bytes, length: _storage.capacity, to: 0)
            return SimpleRingBuffer(existingStorage: newBytes, readIndex: 0, writeIndex: w)
        case let (r, w) where r == w:
            // nothing in the buffer to copy
            return SimpleRingBuffer(existingStorage: newBytes, readIndex: 0, writeIndex: 0)
        case let (r, w) where r < w:
            // contiguous bytes, just copy them in
            newBytes.copyIn(_storage.bytes.advanced(by: Int(r)), length: w - r, to: 0)
            return SimpleRingBuffer(existingStorage: newBytes, readIndex: 0, writeIndex: w - r)
        case let (r, w):
            // split range, just copy in the subranges
            newBytes.copyIn(_storage.bytes.advanced(by: Int(r)), length: _storage.capacity - r, to: 0)
            newBytes.copyIn(_storage.bytes, length: w, to: _storage.capacity - r)
            return SimpleRingBuffer(existingStorage: newBytes, readIndex: 0, writeIndex: _toIndex(self.writableBytes))
        }
    }
    
    private mutating func _makeContiguous() {
        switch (_readerIndex, _writerIndex) {
        case (0, _):
            // already contiguous from start of buffer
            break
            
        case let (r, w) where r == w:
            // nothing in the buffer, just move both pointers to zero
            self._moveReaderIndex(to: 0)
            self._moveWriterIndex(to: 0)
            
        case let (r, w) where r < w:
            // contiguous bytes, just need to move them down
            self._storage.rebaseSlice(r ..< w)
            self._moveWriterIndex(to: w - r)
            self._moveReaderIndex(to: 0)
            
        case let (r, w) where self._storage.capacity - r <= r - w:
            // reader is above writer, but we have room in the middle to move the lower
            // segment forward to make way for the higher segment
            // i.e.:
            //      +---------------------------------------+
            //  1.  |------W                        R-------|
            //      +---------------------------------------+
            //
            //      +---------------------------------------+
            //  2.  |        ------W                R-------|
            //      +---------------------------------------+
            //
            //      +---------------------------------------+
            //  3.  |R-------------W                        |
            //      +---------------------------------------+
            self._storage.rebaseSlice(0 ..< w, to: w)
            self._storage.rebaseSlice(r ..< self._storage.capacity)
            
        case let (r, w):
            // every other option has been exhausted. Now we have a buffer
            // where reader > writer, and there's not enough room in the middle
            // to move things around. Now while we could look at the available
            // space and shuffle that many bytes around, it's likely no faster
            // than reallocating and copying.
            let endChunk = r ..< self._storage.capacity
            let newStorage = self._storage.reallocSlice(endChunk, capacity: self._storage.capacity)
            newStorage.copySlice(0 ..< w, from: self._storage, to: _toIndex(endChunk.count))
            self._storage = newStorage
        }
    }
    
    @inlinable
    func _hasContiguousWriteSpace(for bytes: Capacity) -> Bool {
        switch (self._readerIndex, self._writerIndex) {
        case let (r, w) where r >= w:
            return r - w >= bytes
        case let (_, w):
            return self._storage.capacity - w >= bytes
        }
    }
    
    @inlinable
    func _hasContiguousReadSpace(for bytes: Capacity) -> Bool {
        switch (self._readerIndex, self._writerIndex) {
        case let (r, w) where r <= w:
            return w - r >= bytes
        case let (r, _):
            return self._storage.capacity - r >= bytes
        }
    }
    
    @inlinable
    mutating func _reallocateStorageAndRebase(capacity: Capacity) {
        let capacity = max(self._storage.capacity, capacity)
        switch (self._readerIndex, self._writerIndex) {
        case (0, let w):
            // indices don't need to change
            self._storage = self._storage.reallocSlice(0 ..< w, capacity: capacity)
            
        case let (r, w) where r == w:
            // make a new store and zero indices
            self._storage = self._storage.allocateStorage()
            self._moveReaderIndex(to: 0)
            self._moveWriterIndex(to: 0)
            
        case let (r, w) where r < w:
            // reallocate the middle bit and reset the indices
            self._storage = self._storage.reallocSlice(r ..< w, capacity: capacity)
            self._moveReaderIndex(to: 0)
            self._moveWriterIndex(to: w - r)
            
        case let (r, w):
            // two copies are needed
            let endChunk = r ..< self._storage.capacity
            let newStorage = self._storage.reallocSlice(r ..< self._storage.capacity, capacity: capacity)
            newStorage.copySlice(0 ..< w, from: self._storage, to: _toIndex(endChunk.count))
            self._storage = newStorage
            self._moveReaderIndex(to: 0)
            self._moveWriterIndex(to: _toIndex(endChunk.count) + w)
        }
    }
    
    @inlinable
    mutating func _copyStorageAndRebase() {
        _reallocateStorageAndRebase(capacity: self._storage.capacity)
    }
    
    @inlinable
    internal mutating func _copyStorageAndRebaseIfNeeded() {
        if !isKnownUniquelyReferenced(&_storage) {
            _copyStorageAndRebase()
        }
    }
    
    @inlinable
    internal mutating func _copyStorageAndRebaseIfNeeded(adjusting index: Index) -> Index {
        if !isKnownUniquelyReferenced(&_storage) {
            let oldReaderIndex = self._readerIndex
            _copyStorageAndRebase()
            if oldReaderIndex > index {
                return index + self._storage.capacity - oldReaderIndex
            } else {
                return index - oldReaderIndex
            }
        }
        return index
    }
    
    @inlinable
    internal mutating func _copyStorage() {
        self._storage = _storage.duplicate()
    }
    
    @inlinable
    internal mutating func _copyStorageIfNeeded() {
        if !isKnownUniquelyReferenced(&_storage) {
            _copyStorage()
        }
    }
    
    @usableFromInline
    func _wrappingDifference(from: Index, to: Index) -> Capacity {
        return NIOHPACK._wrappingDifference(from: from, to: to, within: self._storage.capacity)
    }
    
    @inlinable
    mutating func _moveReaderIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._readerIndex = newIndex
    }
    
    @inlinable
    mutating func _moveReaderIndex(forwardBy amount: Int) {
        assert(amount >= 0)
        let readerIsBelowWriter = self._readerIndex <= self._writerIndex
        var newIndex = self._readerIndex + _toIndex(amount)
        
        // reader index should not pass writer index
        if readerIsBelowWriter {
            assert(newIndex <= self._writerIndex)
        } else if newIndex >= self._storage.capacity {
            // wrap it around
            newIndex -= self._storage.capacity
            // now test that it didn't pass writer
            assert(newIndex < self._writerIndex)
        }
        
        self._moveReaderIndex(to: newIndex)
        self._readableBytes -= _toCapacity(amount)
    }
    
    @inlinable
    mutating func _moveWriterIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._writerIndex = newIndex
    }
    
    @inlinable
    mutating func _moveWriterIndex(forwardBy amount: Int) {
        assert(amount >= 0)
        let writerIsBelowReader = self._writerIndex < self._readerIndex
        var newIndex = self._writerIndex + _toIndex(amount)
        
        // writer index should not pass readerIndex
        if writerIsBelowReader {
            assert(newIndex <= self._readerIndex)
        } else if newIndex >= self._storage.capacity {
            // wrap it around
            newIndex -= self._storage.capacity
            // now test it
            assert(newIndex <= self._readerIndex)
        }
        
        self._moveWriterIndex(to: newIndex)
        self._readableBytes += _toCapacity(amount)
    }
    
    @inlinable
    mutating func moveReaderIndex(forwardBy amount: Int) {
        self._moveReaderIndex(forwardBy: amount)
    }
    
    @inlinable
    mutating func moveWriterIndex(forwardBy amount: Int) {
        self._moveWriterIndex(forwardBy: amount)
    }
    
    @inlinable
    mutating func unwrite(byteCount: Int) {
        assert(byteCount >= 0)
        let idxCount = _toIndex(byteCount)
        if idxCount <= self._writerIndex {
            self._writerIndex -= idxCount
        } else {
            self._writerIndex = self._capacity - idxCount + self._writerIndex
        }
        self._readableBytes -= idxCount
    }
    
    @inlinable
    mutating func unread(byteCount: Int) {
        assert(byteCount >= 0)
        let idxCount = _toIndex(byteCount)
        if idxCount <= self._readerIndex {
            self._readerIndex -= idxCount
        } else {
            self._readerIndex = self._capacity - idxCount + self._readerIndex
        }
        self._readableBytes += idxCount
    }
    
    @usableFromInline
    internal var _capacity: Capacity {
        return self._storage.capacity
    }
    
    @usableFromInline
    internal var _readEndIndex: Index {
        return _writerIndex == 0 ? self._storage.capacity : _writerIndex
    }
    
    @usableFromInline
    internal var _writeEndIndex: Index {
        return _readerIndex == 0 ? self._storage.capacity : _readerIndex
    }
    
    @inlinable
    mutating func _set(bytes: UnsafeRawBufferPointer, at index: Index) -> Capacity {
        let firstPart = self._capacity - index
        if firstPart >= bytes.count {
            _storage.copyIn(bytes.baseAddress!, length: _toCapacity(bytes.count), to: index)
        } else {
            let secondPart = _toCapacity(bytes.count) - firstPart
            _storage.copyIn(bytes.baseAddress!, length: firstPart, to: index)
            _storage.copyIn(bytes.baseAddress!.advanced(by: Int(firstPart)), length: secondPart, to: 0)
        }
        return _toCapacity(bytes.count)
    }
    
    @inlinable
    mutating func _set<S : ContiguousCollection>(bytes: S, at index: Index) throws -> Capacity where S.Element == UInt8 {
        let totalCount = _toCapacity(bytes.count)
        guard totalCount <= self.writableBytes else {
            throw RingBufferError.BufferOverrun(amount: Int(totalCount - self._capacity))
        }
        
        let newIndex = self._copyStorageAndRebaseIfNeeded(adjusting: index)
        return bytes.withUnsafeBytes { ptr in
            return self._set(bytes: ptr, at: newIndex)
        }
    }
    
    @inlinable
    mutating func _setRemainder<I : IteratorProtocol>(iterator: I, at index: Index, available: Capacity) throws -> Capacity where I.Element == UInt8 {
        var iterator = iterator
        var idx = Int(index)
        var written: Capacity = 0
        let base = self._storage.bytes.assumingMemoryBound(to: UInt8.self)
        while let b = iterator.next() {
            guard written <= available else {
                // how much space?
                var needed = 1
                while let _ = iterator.next() {
                    needed += 1
                }
                throw RingBufferError.BufferOverrun(amount: needed)
            }
            
            // loop around if necessary
            if idx >= self._capacity {
                idx = 0
            }
            base[idx] = b
            idx += 1
            written += 1
        }
        
        return written
    }
    
    @inlinable
    mutating func _set<S : Sequence>(bytes: S, at index: Index) throws -> Capacity where S.Element == UInt8 {
        assert(!([Array<S.Element>.self, StaticString.self, ContiguousArray<S.Element>.self, UnsafeRawBufferPointer.self, UnsafeBufferPointer<UInt8>.self].contains(where: { (t: Any.Type) -> Bool in t == type(of: bytes) })),
               "called the slower set<S: Sequence> function even though \(S.self) is a ContiguousCollection")
        guard bytes.underestimatedCount <= self.writableBytes else {
            throw RingBufferError.BufferOverrun(amount: Int(self._capacity) - bytes.underestimatedCount)
        }
        
        // it *should* fit. Let's see though.
        let underestimatedCount = bytes.underestimatedCount
        let newIndex = self._copyStorageAndRebaseIfNeeded(adjusting: index)
        var base = self._storage.bytes.advanced(by: Int(newIndex)).assumingMemoryBound(to: UInt8.self)
        let highestWritableAddress = self._readerIndex > self._writerIndex ? min(self._capacity, self._readerIndex) : self._capacity
        let remainderWritten: Capacity
        
        // since we end up with an iterator from either the base sequence type or its subsequence type, we handle
        // the clash of generics by passing that on to another (generic on iterator type) function to handle.
        if highestWritableAddress - newIndex >= _toCapacity(underestimatedCount) {
            let (iterator, idx) = UnsafeMutableBufferPointer(start: base, count: underestimatedCount).initialize(from: bytes)
            assert(idx == underestimatedCount)
            remainderWritten = try _setRemainder(iterator: iterator, at: newIndex + _toIndex(idx),
                                                 available: _toCapacity(self.writableBytes - idx))
        } else {
            // first part...
            let firstPart = Int(self._capacity - newIndex)
            let secondPart = underestimatedCount - firstPart
            let (_, firstIdx) = UnsafeMutableBufferPointer(start: base, count: firstPart).initialize(from: bytes)
            // second part...
            base = self._storage.bytes.assumingMemoryBound(to: UInt8.self)
            let (iterator, idx) = UnsafeMutableBufferPointer(start: base, count: secondPart).initialize(from: bytes.dropFirst(firstIdx))
            assert(firstIdx + idx == underestimatedCount)
            remainderWritten = try _setRemainder(iterator: iterator, at: _toIndex(idx), available: self._capacity - _toCapacity(firstIdx + idx))
        }
        
        return _toCapacity(underestimatedCount) + remainderWritten
    }
    
    // MARK: Public Core API
    
    init(capacity: Int) {
        self._storage = _Storage.reallocated(newCapacity: _toCapacity(capacity))
    }
    
    /// The number of bytes available to read.
    public var readableBytes: Int {
        // we maintain readable (used) byte count separately because readIdx == writeIdx could mean either empty or full.
        return Int(self._readableBytes)
    }
    
    /// The number of available bytes for writing.
    public var writableBytes: Int {
        return self.capacity - self.readableBytes
    }
    
    /// The total capacity of this `CircularByteBuffer`.
    public var capacity: Int {
        return Int(self._storage.capacity)
    }
    
    /// Change the capacity to exactly `to` bytes.
    ///
    /// - parameters:
    ///     - to: The desired minimum capacity.
    /// - precondition: Capacity cannot shrink beyond the number of bytes
    ///                 currently in the buffer.
    public mutating func changeCapacity(to newCapacity: Int) {
        precondition(newCapacity >= self.readableBytes,
                     "new capacity \(newCapacity) is too small to contain current buffer contents")
        if newCapacity == self._storage.capacity {
            return
        }
        
        // we know this capacity is ok
        self._reallocateStorageAndRebase(capacity: _toCapacity(newCapacity))
    }
    
    /// This vends a pointer to the storage of the `CircularByteBuffer`. It's marked as _very unsafe_ because it might contain
    /// uninitialised memory and it's undefined behaviour to read it. In most cases you should use `withUnsafeReadableBytes`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    @inlinable
    public func withVeryUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try body(UnsafeRawBufferPointer(start: self._storage.bytes, count: Int(self._storage.capacity)))
    }
    
    /// See `withUnsafeReadableBytesWithStorageManagement` and `withVeryUnsafeBytes`.
    @inlinable
    public func withVeryUnsafeBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._storage)
        return try body(UnsafeRawBufferPointer(start: self._storage.bytes, count: self.capacity), storageReference)
    }
    
    /// Returns a `ByteBuffer` of size `length` bytes, containing `length` bytes of the available bytes
    /// in this ring buffer.
    ///
    /// The `readerIndex` of the returned `ByteBuffer` will be `0`, the `writerIndex` will be `length`.
    ///
    /// - parameters:
    ///     - length: The length of the requested region.
    public func copyRegion(length: Int) -> ByteBuffer? {
        precondition(length >= 0, "length must not be negative")
        precondition(length <= self.readableBytes, "length must not be more than we can supply")
        var buffer = ByteBufferAllocator().buffer(capacity: length)
        
        if self._readerIndex <= self.capacity - length {
            buffer.write(bytes: UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: self.readerIndex), count: length))
        } else {
            // two reads
            let firstRead = Int(self._capacity - self._readerIndex)
            let secondRead = length - firstRead
            buffer.write(bytes: UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._readerIndex)), count: firstRead))
            buffer.write(bytes: UnsafeRawBufferPointer(start: self._storage.bytes, count: secondRead))
        }
        
        return buffer
    }
    
    /// Discard the bytes before the reader index. The byte at index `readerIndex` before calling this method will be
    /// at index `0` after the call returns.
    ///
    /// - returns: `true` if one or more bytes have been discarded, `false` if there are no bytes to discard.
    @discardableResult
    public mutating func discardReadBytes() -> Bool {
        guard self._readerIndex > 0 else {
            return false    // we're already based at zero
        }
        
        if isKnownUniquelyReferenced(&_storage) {
            let alreadyEmpty = self._readerIndex == self._writerIndex
            self._makeContiguous()
            return !alreadyEmpty
        } else {
            self._copyStorageAndRebase()
        }
        
        return true
    }
    
    /// Resets the state of this `SimpleRingBuffer` to the state of a freshly allocated one, if possible without
    /// allocations. This is the cheapest way to recycle a `SimpleRingBuffer` for a new use-case.
    ///
    /// - note: This method will allocate if the underlying storage is referenced by another `SimpleRingBuffer`. Even if an
    /// allocation is necessary this will be cheaper as the copy of the storage is elided.
    public mutating func clear() {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.allocateStorage()
        }
        self._moveWriterIndex(to: 0)
        self._moveReaderIndex(to: 0)
    }
}

extension SimpleRingBuffer {
    /// Copy the collection of `bytes` into the `CircularByteBuffer` at `index`.
    @discardableResult
    @usableFromInline
    internal mutating func set<S: ContiguousCollection>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
        return Int(try self._set(bytes: bytes, at: _toIndex(index)))
    }
    
    @discardableResult
    @usableFromInline
    internal mutating func set<S: Sequence>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
        return Int(try self._set(bytes: bytes, at: _toIndex(index)))
    }
    
    @usableFromInline
    internal var readerIndex: Int {
        return Int(self._readerIndex)
    }
    
    @usableFromInline
    internal var writerIndex: Int {
        return Int(self._writerIndex)
    }
    
    // MARK: [UInt8] APIs
    
    /// Get `length` bytes starting at `index` and return the result as `[UInt8]`.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `SimpleRingBuffer`.
    ///     - length: The number of bytes of interest.
    /// - returns: A `[UInt8]` value containing the bytes of interest or `nil` if the `SimpleRingBuffer` doesn't contain
    ///            those bytes.
    internal func getBytes(index: Int, length: Int) -> [UInt8]? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        guard self.capacity >= length else {
            return nil
        }
        
        return self.withVeryUnsafeBytes { ptr in
            if capacity - index <= length {
                // single read
                return Array(UnsafeBufferPointer<UInt8>(start: ptr.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: length))
            } else {
                // need two reads
                let firstPart = capacity - index
                var array = Array(UnsafeBufferPointer<UInt8>(start: ptr.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: firstPart))
                array.append(contentsOf: UnsafeBufferPointer<UInt8>(start: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: length - firstPart))
                return array
            }
        }
    }
    
    /// Peek `length` bytes from this `SimpleRingBuffer`'s readable bytes, without modifying the content or the reader index.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `SimpleRingBuffer`.
    /// - returns: A `[UInt8]` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    public func peekBytes(length: Int) -> [UInt8]? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        return self.getBytes(index: self.readerIndex, length: length)
    }
    
    /// Read `length` bytes off this `SimpleRingBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `[UInt8]`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `SimpleRingBuffer`.
    /// - returns: A `[UInt8]` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    public mutating func readBytes(length: Int) -> [UInt8]? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        defer { self._moveReaderIndex(forwardBy: length) }
        return self.getBytes(index: self.readerIndex, length: length)!  /* must work, enough readable bytes */
    }
    
    // MARK: StaticString APIs
    
    /// Write the static `string` into this `SimpleRingBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func write(staticString string: StaticString) throws -> Int {
        let written = try self.set(staticString: string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    
    /// Write the static `string` into this `SimpleRingBuffer` at `index` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @discardableResult
    internal mutating func set(staticString string: StaticString, at index: Int) throws -> Int {
        return try self.set(bytes: UnsafeRawBufferPointer(start: string.utf8Start, count: string.utf8CodeUnitCount), at: index)
    }
    
    // MARK: String APIs
    
    /// Write `string` into this `SimpleRingBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func write(string: String) throws -> Int {
        let written = try self.set(string: string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    
    /// Write `string` into this `SimpleRingBuffer` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @discardableResult
    internal mutating func set(string: String, at index: Int) throws -> Int {
        return try self.set(bytes: string.utf8, at: index)
    }
    
    /// Get the string at `index` from this `SimpleRingBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    ///
    /// - parameters:
    ///     - index: The starting index into `ByteBuffer` containing the string of interest.
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value deserialized from this `SimpleRingBuffer` or `nil` if the requested bytes aren't contained in this `ByteBuffer`.
    internal func getString(at index: Int, length: Int) -> String? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        
        guard length <= self.capacity else {
            return nil
        }
        
        return self.withVeryUnsafeBytes { ptr in
            if self.capacity - index >= length {
                // single read
                return String(decoding: UnsafeBufferPointer(start: ptr.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: length), as: UTF8.self)
            } else {
                // double read-- we will need to provide an intermediate buffer for the String API to read.
                let firstPart = self.capacity - index
                var bytes = ContiguousArray<UInt8>()
                bytes.reserveCapacity(length)
                bytes.append(contentsOf: UnsafeBufferPointer(start: ptr.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: firstPart))
                bytes.append(contentsOf: UnsafeBufferPointer(start: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: length - firstPart))
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }
    
    public func peekString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard length <= self.readableBytes else {
            return nil
        }
        
        return self.getString(at: self.readerIndex, length: length)
    }
    
    public mutating func readString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard length <= self.readableBytes else {
            return nil
        }
        
        defer { self._moveReaderIndex(forwardBy: length) }
        return self.getString(at: self.readerIndex, length: length)
    }
    
    /// Write `bytes`, a `Sequence` of `UInt8` into this `SimpleRingBuffer`. Moves the writer index forward by the number of bytes written.
    ///
    /// - parameters:
    ///     - bytes: A `Collection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @inlinable
    public mutating func write<S: Sequence>(bytes: S) throws -> Int where S.Element == UInt8 {
        let written = try set(bytes: bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    
    /// Write `bytes`, a `ContiguousCollection` of `UInt8` into this `SimpleRingBuffer`. Moves the writer index forward by the number of bytes written.
    /// This method is likely more efficient than the one operating on plain `Collection` as it will use `memcpy` to copy all the bytes in one go.
    ///
    /// - parameters:
    ///     - bytes: A `ContiguousCollection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @inlinable
    public mutating func write<S: ContiguousCollection>(bytes: S) throws -> Int where S.Element == UInt8 {
        let written = try set(bytes: bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
}

extension SimpleRingBuffer {
    /// Returns a copy containing our readable *and writable* bytes in a contiguous space.
    internal func asByteBuffer(using allocator: ByteBufferAllocator = ByteBufferAllocator()) -> ByteBuffer {
        var buf = allocator.buffer(capacity: self.capacity)
        var newWriterIndex = 0
        
        buf.withUnsafeMutableWritableBytes { ptr in
            switch (self._readerIndex, self._writerIndex) {
            case (0, let w):
                // copy the region as-is
                ptr.copyMemory(from: UnsafeRawBufferPointer(start: self._storage.bytes, count: Int(self._storage.capacity)))
                newWriterIndex = Int(w)
                
            case let (r, w) where r == w:
                // all writable, no readable, in two chunks
                let firstLength = Int(self._storage.capacity - r)
                let secondLength = Int(self._storage.capacity) - firstLength
                
                var bytePtr = ptr.baseAddress!
                bytePtr.copyMemory(from: self._storage.bytes.advanced(by: Int(r)), byteCount: firstLength)
                bytePtr = bytePtr.advanced(by: firstLength)
                bytePtr.copyMemory(from: self._storage.bytes, byteCount: secondLength)
                // no need to update writer index
                
            case let (r, w) where r < w:
                let readableLength = Int(w - r)
                let firstWriteLength = Int(self._storage.capacity - w)
                let secondWriteLength = Int(r)
                
                var bytePtr = ptr.baseAddress!
                
                // copy readable bytes, which are contiguous
                bytePtr.copyMemory(from: self._storage.bytes.advanced(by: Int(r)), byteCount: readableLength)
                bytePtr = bytePtr.advanced(by: readableLength)
                
                // writable bytes at the end of the buffer
                if firstWriteLength > 0 {
                    bytePtr.copyMemory(from: self._storage.bytes.advanced(by: Int(w)), byteCount: firstWriteLength)
                    bytePtr = bytePtr.advanced(by: firstWriteLength)
                }
                
                // second write length cannot be zero (reader index can't be zero)
                bytePtr.copyMemory(from: self._storage.bytes, byteCount: secondWriteLength)
                
                // update writer index
                newWriterIndex = readableLength
                
            case let (r, w):
                // w < r, by definition
                let firstReadLength = Int(self._storage.capacity - r)
                let secondReadLength = Int(w)
                let writeLength = Int(r - w)
                
                var bytePtr = ptr.baseAddress!
                
                // copy readable chunk from end of buffer
                bytePtr.copyMemory(from: self._storage.bytes.advanced(by: Int(r)), byteCount: firstReadLength)
                bytePtr = bytePtr.advanced(by: firstReadLength)
                
                // copy readable chunk from beginning of buffer; if write index is zero, nothing to copy
                if secondReadLength > 0 {
                    bytePtr.copyMemory(from: self._storage.bytes, byteCount: secondReadLength)
                    bytePtr = bytePtr.advanced(by: secondReadLength)
                }
                
                // must be some writable bytes, or we'd have landed in the r == w case.
                bytePtr.copyMemory(from: self._storage.bytes.advanced(by: secondReadLength), byteCount: writeLength)
                
                // set output writer index
                newWriterIndex = firstReadLength + secondReadLength
            }
        }
        
        buf.moveWriterIndex(to: newWriterIndex)
        return buf
    }
    
    internal func readableContentsMatch(_ rhs: SimpleRingBuffer) -> Bool {
        guard self.readableBytes == rhs.readableBytes else {
            // different sizes
            return false
        }
        
        // not especially happy doing a copy here, but this function exists purely for the more paranoid unit tests, so...
        let myBuf = self.asByteBuffer()
        let theirBuf = rhs.asByteBuffer()
        
        return myBuf == theirBuf
    }
    
    internal func allContentsMatch(_ rhs: SimpleRingBuffer) -> Bool {
        guard self.capacity == rhs.capacity else {
            return false
        }
        return self.withVeryUnsafeBytes { myBytes in
            rhs.withVeryUnsafeBytes { theirBytes in
                memcmp(myBytes.baseAddress!, theirBytes.baseAddress!, myBytes.count) == 0
            }
        }
    }
}
