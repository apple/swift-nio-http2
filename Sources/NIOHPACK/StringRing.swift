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

enum RingBufferError {
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

struct StringRing {
    @_versioned private(set) var _storage: ByteBuffer
    @_versioned private(set) var _ringHead = 0
    @_versioned private(set) var _ringTail = 0
    @_versioned private(set) var _readableBytes = 0
    
    // private but tests
    @_inlineable
    mutating func _reallocateStorageAndRebase(capacity: Int) {
        let capacity = max(self._storage.capacity, capacity)
        switch (self._ringHead, self._ringTail) {
        case (0, _):
            // indices don't need to change
            self._storage.changeCapacity(to: capacity)
            
        case let (r, w) where r == w:
            // make a new store and zero indices
            self._storage.changeCapacity(to: capacity)
            self.moveHead(to: 0)
            self.moveTail(to: 0)
            
        case let (r, w) where r < w:
            // move the middle bit down and reset the indices
            var newBytes = self._storage
            newBytes.clear()
            newBytes.changeCapacity(to: capacity)
            newBytes.write(bytes: self._storage.viewBytes(at: r, length: w - r))
            self._storage = newBytes
            self.moveHead(to: 0)
            self.moveTail(to: w - r)
            
        case let (r, w):
            // two copies are needed
            var newBytes = self._storage
            newBytes.clear()
            newBytes.changeCapacity(to: capacity)
            newBytes.write(bytes: self._storage.viewBytes(at: r, length: self._storage.capacity - r))
            newBytes.write(bytes: self._storage.viewBytes(at: 0, length: w))
            self.moveHead(to: 0)
            self.moveTail(to: self._storage.capacity - r + w)
            self._storage = newBytes
        }
    }
    
    @_inlineable
    mutating func moveHead(to newIndex: Int) {
        precondition(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._ringHead = newIndex
    }
    
    @_inlineable
    mutating func moveHead(forwardBy amount: Int) {
        precondition(amount >= 0)
        let readerIsBelowWriter = self._ringHead <= self._ringTail
        var newIndex = self._ringHead + amount
        
        // reader index should not pass writer index
        if readerIsBelowWriter {
            precondition(newIndex <= self._ringTail)
        } else if newIndex >= self._storage.capacity {
            // wrap it around
            newIndex -= self._storage.capacity
            // now test that it didn't pass writer
            precondition(newIndex <= self._ringTail)
        }
        
        self.moveHead(to: newIndex)
        self._readableBytes -= amount
    }
    
    @_inlineable
    mutating func moveTail(to newIndex: Int) {
        precondition(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._ringTail = newIndex
    }
    
    @_inlineable
    mutating func moveTail(forwardBy amount: Int) {
        precondition(amount >= 0)
        let writerIsBelowReader = self._ringTail < self._ringHead
        var newIndex = self._ringTail + amount
        
        // writer index should not pass readerIndex
        if writerIsBelowReader {
            precondition(newIndex <= self._ringHead)
        } else if newIndex >= self._storage.capacity {
            // wrap it around
            newIndex -= self._storage.capacity
            // now test it
            precondition(newIndex <= self._ringHead)
        }
        
        self.moveTail(to: newIndex)
        self._readableBytes += amount
    }
    
    @_inlineable
    mutating func unwrite(byteCount: Int) {
        precondition(byteCount >= 0)
        precondition(byteCount <= self.readableBytes)
        if byteCount <= self._ringTail {
            self._ringTail -= byteCount
        } else {
            self._ringTail = self._storage.capacity - byteCount + self._ringTail
        }
        self._readableBytes -= byteCount
    }
    
    @_inlineable
    mutating func unread(byteCount: Int) {
        precondition(byteCount >= 0)
        precondition(byteCount <= self.writableBytes)
        if byteCount <= self._ringHead {
            self._ringHead -= byteCount
        } else {
            self._ringHead = self._storage.capacity - byteCount + self._ringHead
        }
        self._readableBytes += byteCount
    }
    
    @_inlineable
    mutating func set<S: ContiguousCollection>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
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
    
    @_inlineable
    mutating func set<S : Sequence>(bytes: S, at index: Int) throws -> Int where S.Element == UInt8 {
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
                
                // split into two sub-sequences that won't go bang inside _copyMemory() if the available target memory is
                // less than the sequence's 'underestimatedCount'.
                let firstSubSequence = bytes.dropLast(secondPart)
                let secondSubSequence = bytes.dropFirst(firstPart)
                
                let (_, firstIdx) = UnsafeMutableBufferPointer(start: base, count: firstPart).initialize(from: firstSubSequence)
                // second part...
                base = UnsafeMutablePointer(mutating: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                let (iterator, idx) = UnsafeMutableBufferPointer(start: base, count: secondPart).initialize(from: secondSubSequence)
                assert(firstIdx + idx == underestimatedCount)
                remainderWritten = try _setRemainder(iterator: iterator, at: idx, available: ptr.count - firstIdx + idx)
            }
            
            return underestimatedCount + remainderWritten
        }
    }
    
    // MARK: Core API
    
    init(allocator: ByteBufferAllocator, capacity: Int) {
        self._storage = allocator.buffer(capacity: capacity)
    }
    
    /// The number of bytes available to read.
    var readableBytes: Int {
        // we maintain readable (used) byte count separately because readIdx == writeIdx could mean either empty or full.
        return self._readableBytes
    }
    
    /// The number of available bytes for writing.
    var writableBytes: Int {
        return self.capacity - self.readableBytes
    }
    
    /// The total capacity of this `CircularByteBuffer`.
    var capacity: Int {
        return Int(self._storage.capacity)
    }
    
    /// Change the capacity to exactly `to` bytes.
    ///
    /// - parameters:
    ///     - to: The desired minimum capacity.
    /// - precondition: Int cannot shrink beyond the number of bytes
    ///                 currently in the buffer.
    mutating func changeCapacity(to newCapacity: Int) {
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
    @_inlineable
    func withVeryUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try self._storage.withVeryUnsafeBytes(body)
    }
    
    /// Resets the state of this `StringRing` to the state of a freshly allocated one, if possible without
    /// allocations. This is the cheapest way to recycle a `StringRing` for a new use-case.
    mutating func clear() {
        self._storage.clear()
        self.moveTail(to: 0)
        self.moveHead(to: 0)
        self._readableBytes = 0
    }
}

extension StringRing {
    @_inlineable @_versioned
    internal var ringHead: Int {
        return self._ringHead
    }
    
    @_inlineable @_versioned
    internal var ringTail: Int {
        return self._ringTail
    }
    
    // MARK: StaticString APIs
    
    /// Write the static `string` into this `StringRing` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    mutating func write(staticString string: StaticString) throws -> Int {
        let written = try self.set(staticString: string, at: self.ringTail)
        self.moveTail(forwardBy: written)
        return written
    }
    
    /// Write the static `string` into this `StringRing` at `index` using UTF-8 encoding, moving the writer index forward appropriately.
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
    
    /// Write `string` into this `StringRing` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    mutating func write(string: String) throws -> Int {
        let written = try self.set(string: string, at: self.ringTail)
        self.moveTail(forwardBy: written)
        return written
    }
    
    /// Write `string` into this `StringRing` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @discardableResult
    internal mutating func set(string: String, at index: Int) throws -> Int {
        return try self.set(bytes: string.utf8, at: index)
    }
    
    /// Get the string at `index` from this `StringRing` decoding using the UTF-8 encoding. Does not move the reader index.
    ///
    /// - parameters:
    ///     - index: The starting index into `ByteBuffer` containing the string of interest.
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value deserialized from this `StringRing` or `nil` if the requested bytes aren't contained in this `ByteBuffer`.
    internal func getString(at index: Int, length: Int) -> String? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        
        guard length <= self.capacity else {
            return nil
        }
        
        return self.withVeryUnsafeBytes { ptr in
            if self.capacity - index >= length {
                // single read
                return String(decoding: ptr[index..<(index+length)], as: UTF8.self)
            } else {
                // double read-- we will need to provide an intermediate buffer for the String API to read.
                let firstPart = self.capacity - index
                var bytes = ContiguousArray<UInt8>()
                bytes.reserveCapacity(length)
                bytes.append(contentsOf: ptr[index..<(index+firstPart)])
                bytes.append(contentsOf: ptr[0..<(length-firstPart)])
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }
    
    func peekString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard length <= self.readableBytes else {
            return nil
        }
        
        return self.getString(at: self.ringHead, length: length)
    }
    
    mutating func readString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard length <= self.readableBytes else {
            return nil
        }
        
        defer { self.moveHead(forwardBy: length) }
        return self.getString(at: self.ringHead, length: length)
    }
    
    /// Write `bytes`, a `Sequence` of `UInt8` into this `StringRing`. Moves the writer index forward by the number of bytes written.
    ///
    /// - parameters:
    ///     - bytes: A `Collection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @_inlineable
    mutating func write<S: Sequence>(bytes: S) throws -> Int where S.Element == UInt8 {
        let written = try set(bytes: bytes, at: self.ringTail)
        self.moveTail(forwardBy: written)
        return written
    }
    
    /// Write `bytes`, a `ContiguousCollection` of `UInt8` into this `StringRing`. Moves the writer index forward by the number of bytes written.
    /// This method is likely more efficient than the one operating on plain `Collection` as it will use `memcpy` to copy all the bytes in one go.
    ///
    /// - parameters:
    ///     - bytes: A `ContiguousCollection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @_inlineable
    mutating func write<S: ContiguousCollection>(bytes: S) throws -> Int where S.Element == UInt8 {
        let written = try set(bytes: bytes, at: self.ringTail)
        self.moveTail(forwardBy: written)
        return written
    }
}
