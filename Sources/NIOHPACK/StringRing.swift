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
    struct BufferOverrun : Error, Equatable {
        /// The amount by which the write would overrun.
        let amount: Int
    }
}

struct StringRing {
    @_versioned private(set) var _storage: ByteBuffer
    @_versioned private(set) var _ringHead = 0
    @_versioned private(set) var _ringTail = 0
    @_versioned private(set) var _readableBytes = 0
    
    // private but tests
    @_inlineable @_versioned
    mutating func _reallocateStorageAndRebase(capacity: Int) {
        let capacity = max(self._storage.capacity, capacity)
        switch (self._ringHead, self._ringTail) {
        case (0, _):
            // indices don't need to change
            self._storage.reserveCapacity(capacity)
            
        case let (r, w) where r == w:
            // make a new store and zero indices
            self._storage.reserveCapacity(capacity)
            self.moveHead(to: 0)
            self.moveTail(to: 0)
            
        case let (r, w) where r < w:
            // move the middle bit down and reset the indices
            var newBytes = self._storage
            newBytes.clear()
            newBytes.reserveCapacity(capacity)
            newBytes.write(bytes: self._storage.viewBytes(at: r, length: w - r))
            self._storage = newBytes
            self.moveHead(to: 0)
            self.moveTail(to: w - r)
            
        case let (r, w):
            // two copies are needed
            var newBytes = self._storage
            newBytes.clear()
            newBytes.reserveCapacity(capacity)
            newBytes.write(bytes: self._storage.viewBytes(at: r, length: self._storage.capacity - r))
            newBytes.write(bytes: self._storage.viewBytes(at: 0, length: w))
            self.moveHead(to: 0)
            self.moveTail(to: self._storage.capacity - r + w)
            self._storage = newBytes
        }
    }
    
    @_inlineable @_versioned
    mutating func moveHead(to newIndex: Int) {
        precondition(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._ringHead = newIndex
    }
    
    @_inlineable @_versioned
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
    
    @_inlineable @_versioned
    mutating func moveTail(to newIndex: Int) {
        precondition(newIndex >= 0 && newIndex <= self._storage.capacity)
        self._ringTail = newIndex
    }
    
    @_inlineable @_versioned
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
    
    @_inlineable @_versioned
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
    
    @_inlineable @_versioned
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
    
    private var _contiguousWriteSpace: Int {
        switch (self._ringHead, self._ringTail) {
        case let (r, w) where r == w:
            if self._readableBytes == self.capacity {
                return 0
            }
            return self.capacity - w
        case let (r, w) where r < w:
            return self.capacity - w
        case let (r, w) where r > w:
            return r - w
        default:
            fatalError("This should be unreachable")
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
    @_inlineable @_versioned
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
    
    /// Write `bytes`, a `ContiguousCollection` of `UInt8` into this `StringRing`. Moves the writer index forward by the number of bytes written.
    /// This method is likely more efficient than the one operating on plain `Collection` as it will use `memcpy` to copy all the bytes in one go.
    ///
    /// - parameters:
    ///     - bytes: A `ContiguousCollection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @_inlineable @_versioned
    mutating func write<C: ContiguousCollection>(bytes: C) throws -> Int where C.Element == UInt8 {
        let totalCount = bytes.count
        guard totalCount <= self.writableBytes else {
            throw RingBufferError.BufferOverrun(amount: Int(totalCount - self._storage.capacity))
        }
        
        let firstPart = self._storage.capacity - self._ringTail
        if firstPart >= bytes.count {
            _storage.set(bytes: bytes, at: self._ringTail)
        } else {
            let secondPart = bytes.count - firstPart
            bytes.withUnsafeBytes { ptr in
                _storage.set(bytes: UnsafeRawBufferPointer(start: ptr.baseAddress!, count: firstPart), at: self._ringTail)
                _storage.set(bytes: UnsafeRawBufferPointer(start: ptr.baseAddress!.advanced(by: firstPart), count: secondPart), at: 0)
            }
        }
        
        self.moveTail(forwardBy: totalCount)
        return totalCount
    }
    
    /// Write `bytes`, a `Collection` of `UInt8` into this `StringRing`. Moves the writer index forward by the number of bytes written.
    ///
    /// - parameters:
    ///     - bytes: A `Collection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @_inlineable @_versioned
    mutating func write<C : Collection>(bytes: C) throws -> Int where C.Element == UInt8 {
        assert(!([Array<C.Element>.self, StaticString.self, ContiguousArray<C.Element>.self, UnsafeRawBufferPointer.self, UnsafeBufferPointer<UInt8>.self].contains(where: { (t: Any.Type) -> Bool in t == type(of: bytes) })),
               "called the slower set<S: Collection> function even though \(C.self) is a ContiguousCollection")
        guard bytes.count <= self.writableBytes else {
            throw RingBufferError.BufferOverrun(amount: Int(self._storage.capacity) - bytes.underestimatedCount)
        }
        
        // is this a contiguous write?
        let contiguousWriteSpace = self._contiguousWriteSpace
        guard bytes.count <= contiguousWriteSpace else {
            // multiple writes -- split and recurse
            let firstPart = bytes.prefix(contiguousWriteSpace)
            let secondPart = bytes.dropFirst(contiguousWriteSpace)
            return try self.write(bytes: firstPart) + self.write(bytes: secondPart)
        }
        
        // single write, should be straightforward
        self._storage.withVeryUnsafeBytes { ptr in
            let targetAddr = UnsafeMutableRawPointer(mutating: ptr.baseAddress!.advanced(by: self._ringTail))
            let target = UnsafeMutableRawBufferPointer(start: targetAddr, count: bytes.count)
            target.copyBytes(from: bytes)
        }
        
        self.moveTail(forwardBy: bytes.count)
        return bytes.count
    }
}

extension StringRing {
    internal var ringHead: Int {
        return self._ringHead
    }
    
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
        return try self.write(bytes: UnsafeRawBufferPointer(start: string.utf8Start, count: string.utf8CodeUnitCount))
    }
    
    // MARK: String APIs
    
    /// Write `string` into this `StringRing` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    mutating func write(string: String) throws -> Int {
        return try self.write(bytes: string.utf8)
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
    
    mutating func readString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard length <= self.readableBytes else {
            return nil
        }
        
        defer { self.moveHead(forwardBy: length) }
        return self.getString(at: self.ringHead, length: length)
    }
}
