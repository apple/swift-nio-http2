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

public struct SimpleRingBuffer {
    @usableFromInline private(set) var _storage: ByteBuffer
    @usableFromInline private(set) var _ringHead = 0
    @usableFromInline private(set) var _ringTail = 0
    @usableFromInline private(set) var _readableBytes = 0
    
    @inlinable
    mutating func _reallocateStorageAndRebase(capacity: Int) {
        let capacity = max(self._storage.capacity, capacity)
        switch (self._ringHead, self._ringTail) {
        case (0, _):
            // indices don't need to change
            self._storage.changeCapacity(to: capacity)
            
        case let (r, w) where r == w:
            // make a new store and zero indices
            self._storage.changeCapacity(to: capacity)
            self._moveHead(to: 0)
            self._moveTail(to: 0)
            
        case let (r, w) where r < w:
            // reallocate the middle bit and reset the indices
            var newBytes = self._storage
            newBytes.clear()
            newBytes.changeCapacity(to: capacity)
            newBytes.write(bytes: self._storage.viewBytes(at: r, length: w - r))
            self._storage = newBytes
            self._moveHead(to: 0)
            self._moveTail(to: w - r)
            
        case let (r, w):
            // two copies are needed
            var newBytes = self._storage
            newBytes.clear()
            newBytes.changeCapacity(to: capacity)
            newBytes.write(bytes: self._storage.viewBytes(at: r, length: self._storage.capacity - r))
            newBytes.write(bytes: self._storage.viewBytes(at: 0, length: w))
            self._moveHead(to: 0)
            self._moveTail(to: self._storage.capacity - r + w)
            self._storage = newBytes
        }
    }
    
    @inlinable
    mutating func _moveHead(to newIndex: Int) {
        assert(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._ringHead = newIndex
    }
    
    @inlinable
    mutating func _moveHead(forwardBy amount: Int) {
        assert(amount >= 0)
        let readerIsBelowWriter = self._ringHead <= self._ringTail
        var newIndex = self._ringHead + amount
        
        // reader index should not pass writer index
        if readerIsBelowWriter {
            assert(newIndex <= self._ringTail)
        } else if newIndex >= self._storage.capacity {
            // wrap it around
            newIndex -= self._storage.capacity
            // now test that it didn't pass writer
            assert(newIndex < self._ringTail)
        }
        
        self._moveHead(to: newIndex)
        self._readableBytes -= amount
    }
    
    @inlinable
    mutating func _moveTail(to newIndex: Int) {
        assert(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._ringTail = newIndex
    }
    
    @inlinable
    mutating func _moveTail(forwardBy amount: Int) {
        assert(amount >= 0)
        let writerIsBelowReader = self._ringTail < self._ringHead
        var newIndex = self._ringTail + amount
        
        // writer index should not pass readerIndex
        if writerIsBelowReader {
            assert(newIndex <= self._ringHead)
        } else if newIndex >= self._storage.capacity {
            // wrap it around
            newIndex -= self._storage.capacity
            // now test it
            assert(newIndex <= self._ringHead)
        }
        
        self._moveTail(to: newIndex)
        self._readableBytes += amount
    }
    
    @inlinable
    mutating func moveHead(forwardBy amount: Int) {
        self._moveHead(forwardBy: amount)
    }
    
    @inlinable
    mutating func moveTail(forwardBy amount: Int) {
        self._moveTail(forwardBy: amount)
    }
    
    @inlinable
    mutating func unwrite(byteCount: Int) {
        assert(byteCount >= 0)
        if byteCount <= self._ringTail {
            self._ringTail -= byteCount
        } else {
            self._ringTail = self._storage.capacity - byteCount + self._ringTail
        }
        self._readableBytes -= byteCount
    }
    
    @inlinable
    mutating func unread(byteCount: Int) {
        assert(byteCount >= 0)
        if byteCount <= self._ringHead {
            self._ringHead -= byteCount
        } else {
            self._ringHead = self._storage.capacity - byteCount + self._ringHead
        }
        self._readableBytes += byteCount
    }
    
    @inlinable
    mutating func _set<S: ContiguousCollection>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
        let totalCount = bytes.count
        guard totalCount <= self.writableBytes else {
            throw RingBufferError.BufferOverrun(amount: Int(totalCount - self._storage.capacity))
        }
        
        let firstPart = self._storage.capacity - index
        if firstPart >= bytes.count {
            _storage.set(bytes: bytes, at: index)
        } else {
            let secondPart = bytes.count - firstPart
            bytes.withUnsafeBytes { ptr in
                _storage.set(bytes: UnsafeRawBufferPointer(start: ptr.baseAddress!, count: firstPart), at: index)
                _storage.set(bytes: UnsafeRawBufferPointer(start: ptr.baseAddress!.advanced(by: firstPart), count: secondPart), at: 0)
            }
        }
        return bytes.count
    }
    
    @inlinable
    mutating func _set<S : Sequence>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
        assert(!([Array<S.Element>.self, StaticString.self, ContiguousArray<S.Element>.self, UnsafeRawBufferPointer.self, UnsafeBufferPointer<UInt8>.self].contains(where: { (t: Any.Type) -> Bool in t == type(of: bytes) })),
               "called the slower set<S: Sequence> function even though \(S.self) is a ContiguousCollection")
        guard bytes.underestimatedCount <= self.writableBytes else {
            throw RingBufferError.BufferOverrun(amount: Int(self._storage.capacity) - bytes.underestimatedCount)
        }
        
        // it *should* fit. Let's see though.
        let underestimatedCount = bytes.underestimatedCount
        
        return try self._storage.withVeryUnsafeBytes { ptr in
            var base = UnsafeMutablePointer(mutating: ptr.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self))
            let highestWritableAddress = self._ringHead > self._ringTail ? min(ptr.count, self._ringHead) : ptr.count
            let remainderWritten: Int
            
            // since we end up with an iterator from either the base sequence type or its subsequence type, we handle
            // the clash of generics by passing that on to another (generic on iterator type) function to handle.
            func _setRemainder<I : IteratorProtocol>(iterator: I, at index: Int, available: Int) throws -> Int where I.Element == UInt8 {
                var iterator = iterator
                var idx = Int(index)
                var written: Int = 0
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
                    if idx >= ptr.count {
                        idx = 0
                    }
                    base[idx] = b
                    idx += 1
                    written += 1
                }
                
                return written
            }
            
            if highestWritableAddress - index >= underestimatedCount {
                let (iterator, idx) = UnsafeMutableBufferPointer(start: base, count: underestimatedCount).initialize(from: bytes)
                assert(idx == underestimatedCount)
                remainderWritten = try _setRemainder(iterator: iterator, at: index + idx, available: self.writableBytes - idx)
            } else {
                // first part...
                let firstPart = ptr.count - index
                let secondPart = underestimatedCount - firstPart
                let (_, firstIdx) = UnsafeMutableBufferPointer(start: base, count: firstPart).initialize(from: bytes)
                // second part...
                base = UnsafeMutablePointer(mutating: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                let (iterator, idx) = UnsafeMutableBufferPointer(start: base, count: secondPart).initialize(from: bytes.dropFirst(firstIdx))
                assert(firstIdx + idx == underestimatedCount)
                remainderWritten = try _setRemainder(iterator: iterator, at: idx, available: ptr.count - firstIdx + idx)
            }
            
            return underestimatedCount + remainderWritten
        }
    }
    
    // MARK: Public Core API
    
    init(allocator: ByteBufferAllocator, capacity: Int) {
        self._storage = allocator.buffer(capacity: capacity)
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
    /// - precondition: Int cannot shrink beyond the number of bytes
    ///                 currently in the buffer.
    public mutating func changeCapacity(to newCapacity: Int) {
        precondition(newCapacity >= self.readableBytes,
                     "new capacity \(newCapacity) is too small to contain current buffer contents")
        if newCapacity == self._storage.capacity {
            return
        }
        
        // we know this capacity is ok
        self._reallocateStorageAndRebase(capacity: newCapacity)
    }
    
    /// This vends a pointer to the storage of the `CircularByteBuffer`. It's marked as _very unsafe_ because it might contain
    /// uninitialised memory and it's undefined behaviour to read it. In most cases you should use `withUnsafeReadableBytes`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    @inlinable
    public func withVeryUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try self._storage.withVeryUnsafeBytes(body)
    }
    
    /// See `withUnsafeReadableBytesWithStorageManagement` and `withVeryUnsafeBytes`.
    @inlinable
    public func withVeryUnsafeBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        return try self._storage.withVeryUnsafeBytesWithStorageManagement(body)
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
        
        if self._ringHead <= self.capacity - length {
            return self._storage.getSlice(at: self._ringHead, length: length)
        } else {
            // two reads
            let firstRead = Int(self._storage.capacity - self._ringHead)
            let secondRead = length - firstRead
            guard var buffer = self._storage.getSlice(at: self._ringHead, length: firstRead) else {
                return nil
            }
            
            buffer.write(bytes: self._storage.viewBytes(at: 0, length: secondRead))
            return buffer
        }
    }
    
    /// Resets the state of this `SimpleRingBuffer` to the state of a freshly allocated one, if possible without
    /// allocations. This is the cheapest way to recycle a `SimpleRingBuffer` for a new use-case.
    public mutating func clear() {
        self._storage.clear()
        self._moveTail(to: 0)
        self._moveHead(to: 0)
    }
}

extension SimpleRingBuffer {
    /// Copy the collection of `bytes` into the `CircularByteBuffer` at `index`.
    @discardableResult
    @usableFromInline
    internal mutating func set<S: ContiguousCollection>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
        return try self._set(bytes: bytes, at: index)
    }
    
    @discardableResult
    @usableFromInline
    internal mutating func set<S: Sequence>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
        return try self._set(bytes: bytes, at: index)
    }
    
    @usableFromInline
    internal var ringHead: Int {
        return self._ringHead
    }
    
    @usableFromInline
    internal var ringTail: Int {
        return self._ringTail
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
        return self.getBytes(index: self.ringHead, length: length)
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
        defer { self._moveHead(forwardBy: length) }
        return self.getBytes(index: self.ringHead, length: length)!  /* must work, enough readable bytes */
    }
    
    // MARK: StaticString APIs
    
    /// Write the static `string` into this `SimpleRingBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func write(staticString string: StaticString) throws -> Int {
        let written = try self.set(staticString: string, at: self.ringTail)
        self._moveTail(forwardBy: written)
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
        let written = try self.set(string: string, at: self.ringTail)
        self._moveTail(forwardBy: written)
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
        
        return self.getString(at: self.ringHead, length: length)
    }
    
    public mutating func readString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard length <= self.readableBytes else {
            return nil
        }
        
        defer { self._moveHead(forwardBy: length) }
        return self.getString(at: self.ringHead, length: length)
    }
    
    /// Write `bytes`, a `Sequence` of `UInt8` into this `SimpleRingBuffer`. Moves the writer index forward by the number of bytes written.
    ///
    /// - parameters:
    ///     - bytes: A `Collection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @inlinable
    public mutating func write<S: Sequence>(bytes: S) throws -> Int where S.Element == UInt8 {
        let written = try set(bytes: bytes, at: self.ringTail)
        self._moveTail(forwardBy: written)
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
        let written = try set(bytes: bytes, at: self.ringTail)
        self._moveTail(forwardBy: written)
        return written
    }
}
