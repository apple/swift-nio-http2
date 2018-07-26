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

/// Stores offsets into a contiguous buffer locating the name and value bytes
/// for a header name and value pair.
struct HeaderTableEntry {
    var name: HPACKHeaderIndex
    var value: HPACKHeaderIndex
    
    init(name: HPACKHeaderIndex, value: HPACKHeaderIndex) {
        self.name = name
        self.value = value
    }
    
    // RFC 7541 § 4.1:
    //
    //      The size of an entry is the sum of its name's length in octets (as defined in
    //      Section 5.2), its value's length in octets, and 32.
    //
    //      The size of an entry is calculated using the length of its name and value
    //      without any Huffman encoding applied.
    var length: Int {
        return self.name.length + self.value.length + 32
    }
    
    fileprivate mutating func adjust(by delta: Int, wrappingAt max: Int) {
        name.adjust(by: delta, wrappingAt: max)
        value.adjust(by: delta, wrappingAt: max)
    }
}

extension HeaderTableEntry : CustomStringConvertible {
    var description: String {
        return "(name: \(self.name), value: \(self.value))"
    }
}

/// Raw bytes storage for the header tables, both static and dynamic. Similar in spirit to
/// `HPACKHeaders` and `NIOHTTP1.HTTPHeaders`, but uses a ring buffer to hold the bytes to
/// avoid allocation churn while evicting and replacing entries.
struct HeaderTableStorage {
    static let defaultMaxSize = 4096
    
    private var buffer: StringRing
    private var headers: CircularBuffer<HeaderTableEntry>
    
    private(set) var maxSize: Int
    private(set) var length: Int = 0
    
    var count: Int {
        return self.headers.count
    }
    
    init(allocator: ByteBufferAllocator, maxSize: Int = HeaderTableStorage.defaultMaxSize) {
        self.maxSize = maxSize
        self.buffer = StringRing(allocator: allocator, capacity: self.maxSize)
        self.headers = CircularBuffer(initialRingCapacity: self.maxSize / 64)    // rough guess: 64 bytes per header
    }
    
    init(allocator: ByteBufferAllocator, staticHeaderList: [(String, String)]) {
        // calculate likely total byte length we will actually need
        // the static table is all ASCII, so character count == byte count here,
        // so we don't need to convert to UTF-8 bytes just to get byte length.
        let bytesNeeded = staticHeaderList.reduce(0) { $0 + $1.0.count + $1.1.count }
        
        // now allocate & encode all the things
        self.buffer = StringRing(allocator: allocator, capacity: bytesNeeded)
        self.headers = CircularBuffer(initialRingCapacity: staticHeaderList.count)
        
        var len = 0
        
        for (name, value) in staticHeaderList {
            let nameStart = self.buffer.ringTail
            let nameLen = try! self.buffer.write(string: name)
            let valueStart = self.buffer.ringTail
            let valueLen = try! self.buffer.write(string: value)
            
            let entry = HeaderTableEntry(name: HPACKHeaderIndex(start: nameStart, length: nameLen),
                                         value: HPACKHeaderIndex(start: valueStart, length: valueLen))
            
            // the input list is already in order, so we push at the end of our internal list
            self.headers.append(entry)
            len += entry.length
        }
        
        self.length = len
        self.maxSize = len
    }
    
    subscript(index: Int) -> HeaderTableEntry {
        return self.headers[index]
    }
    
    subscript(name: String) -> [String] {
        return self.findHeaders(matching: name.utf8).map { self.string(idx: $0.value) }
    }
    
    @_specialize(where C == String.UTF8View)
    func findHeaders<C: Collection>(matching name: C) -> [HeaderTableEntry] where C.Element == UInt8 {
        return self.headers.lazy.filter {
            self.buffer.equalCaseInsensitiveASCII(view: name, at: $0.name)
        }
    }
    
    @_specialize(where C == String.UTF8View)   // from String-based API
    @_specialize(where C == ByteBufferView)    // from HPACKHeaders-based API
    func indices<C: Collection>(matching name: C) -> [Int] where C.Element == UInt8 {
        // Returns a LazyFilterCollection
        return self.headers.enumerated().lazy.filter {
            self.buffer.equalCaseInsensitiveASCII(view: name, at: $1.name)
        }.map { (idx, header) in idx }
    }
    
    func string(idx: HPACKHeaderIndex) -> String {
        return self.buffer.getString(at: idx.start, length: idx.length)!
    }
    
    func view(of idx: HPACKHeaderIndex) -> ByteBufferView {
        return self.buffer.viewBytes(at: idx.start, length: idx.length)
    }
    
    mutating func setTableSize(to newSize: Int) {
        precondition(newSize >= 0)
        if newSize < self.length {
            // need to clear out some things first.
            while newSize < self.length {
                purgeOne()
            }
        }
        
        // if this rebases, we will need to alter all our header indices
        let startIndex = self.buffer.ringHead
        self.buffer.changeCapacity(to: newSize)
        self.maxSize = newSize
        
        if startIndex == self.buffer.ringHead {
            // no index changes
            return
        }
        
        // otherwise, compute a delta and apply it to all indices
        let delta = self.buffer.ringHead - startIndex    // if index decreased, we apply a negative delta
        for index in self.headers.indices {
            self.headers[index].adjust(by: delta, wrappingAt: self.buffer.capacity)
        }
    }
    
    mutating func add<Name: Collection, Value: Collection>(name: Name, value: Value) throws where Name.Element == UInt8, Value.Element == UInt8 {
        var len = 0
        do {
            let (nameStart, nameLen, valueStart, valueLen) = try self.encode(name: name, value: value)
            len = nameLen + valueLen
            
            try prependHeaderEntry(nameStart: nameStart, nameLen: nameLen, valueStart: valueStart, valueLen: valueLen)
        } catch {
            // NB: moving backwards here
            self.buffer.unwrite(byteCount: len)
            throw error
        }
    }
    
    mutating func add<Name: ContiguousCollection, Value: ContiguousCollection>(nameBytes: Name, valueBytes: Value) throws where Name.Element == UInt8, Value.Element == UInt8 {
        let (nameStart, nameLen, valueStart, valueLen) = try self.encode(name: nameBytes, value: valueBytes)
        
        do {
            try prependHeaderEntry(nameStart: nameStart, nameLen: nameLen, valueStart: valueStart, valueLen: valueLen)
        } catch {
            // remove everything written by the `encode(name:value:)` call above
            self.buffer.unwrite(byteCount: nameLen + valueLen)
            throw error
        }
    }
    
    private mutating func ensureSpaceAvailable(_ amount: Int) throws {
        if self.buffer.writableBytes >= amount {
            // all is good in the world
            return
        }
        
        let extraNeeded = amount - self.buffer.writableBytes
        self.purge(toRelease: extraNeeded)
        
        if self.buffer.writableBytes >= amount {
            // still not enough actual room:
            throw RingBufferError.BufferOverrun(amount: amount - self.buffer.writableBytes)
        }
    }
    
    private mutating func encode<Name: Collection, Value: Collection>(name: Name, value: Value) throws -> (nstart: Int, nlen: Int, vstart: Int, vlen: Int) where Name.Element == UInt8, Value.Element == UInt8 {
        try ensureSpaceAvailable(name.count + value.count)
        
        let nstart = self.buffer.ringTail
        let nlen = try self.buffer.write(bytes: name)
        let vstart = self.buffer.ringTail
        let vlen = try self.buffer.write(bytes: value)
        
        return (nstart, nlen, vstart, vlen)
    }
    
    private mutating func encode<Name: ContiguousCollection, Value: ContiguousCollection>(name: Name, value: Value) throws -> (nstart: Int, nlen: Int, vstart: Int, vlen: Int) where Name.Element == UInt8, Value.Element == UInt8 {
        try ensureSpaceAvailable(name.count + value.count)
        
        let nstart = self.buffer.ringTail
        let nlen = try self.buffer.write(bytes: name)
        let vstart = self.buffer.ringTail
        let vlen = try self.buffer.write(bytes: value)
        
        return (nstart, nlen, vstart, vlen)
    }
    
    private mutating func prependHeaderEntry(nameStart: Int, nameLen: Int, valueStart: Int, valueLen: Int) throws {
        let nameIndex = HPACKHeaderIndex(start: nameStart, length: nameLen)
        let valueIndex = HPACKHeaderIndex(start: valueStart, length: valueLen)
        let entry = HeaderTableEntry(name: nameIndex, value: valueIndex)
        
        var newLength = self.length + entry.length
        if newLength > self.maxSize {
            self.purge(toRelease: newLength - maxSize)
            newLength = self.length + entry.length
            
            if newLength > self.maxSize {
                // Danger, Will Robinson! We can't free up enough space!
                throw RingBufferError.BufferOverrun(amount: newLength - self.maxSize)
            }
        }
        
        self.headers.prepend(entry)
        self.length = newLength
    }
    
    /// Purges `toRelease` bytes from the table, where 'bytes' refers to the byte-count
    /// of a table entry specified in RFC 7541: [name octets] + [value octets] + 32.
    ///
    /// - parameter toRelease: The table entry length of bytes to remove from the table.
    mutating func purge(toRelease count: Int) {
        guard count < self.length else {
            // clear all the things
            self.headers.removeAll()
            self.buffer.clear()
            self.length = 0
            return
        }
        
        var available = self.maxSize - self.length
        let needed = available + count
        while available < needed && !self.headers.isEmpty {
            available += self.purgeOne()
        }
    }
    
    @discardableResult
    private mutating func purgeOne() -> Int {
        precondition(self.headers.isEmpty == false, "should not call purgeOne() unless we have something to purge")
        // Remember: we're removing from the *end* of the header list, since we *prepend* new items there, but we're
        // removing bytes from the *start* of the storage, because we *append* there.
        let entry = self.headers.removeLast()
        self.buffer.moveHead(forwardBy: entry.name.length + entry.value.length)
        self.length -= entry.length
        return entry.length
    }
    
    // internal for testing
    func dumpHeaders(offsetBy amount: Int = 0) -> String {
        return self.headers.enumerated().reduce("") {
            $0 + "\($1.0 + amount) - \(self.string(idx: $1.1.name)) : \(self.string(idx: $1.1.value))\n"
        }
    }
}

extension HeaderTableStorage : CustomStringConvertible {
    var description: String {
        var array: [(String, String)] = []
        for header in self.headers {
            array.append((self.string(idx: header.name), self.string(idx: header.value)))
        }
        return array.description
    }
}

private extension StringRing {
    func equalCaseInsensitiveASCII<C : Collection>(view: C, at index: HPACKHeaderIndex) -> Bool where C.Element == UInt8 {
        guard view.count == index.length else {
            return false
        }
        return withVeryUnsafeBytes { buffer in
            // This should never happens as we control when this is called. Adding an assert to ensure this.
            let address = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for (idx, byte) in view.enumerated() {
                // TODO(jim): Not a big fan of the modulo operation here.
                guard byte.isASCII && address.advanced(by: ((index.start + idx) % self.capacity)).pointee & 0xdf == byte & 0xdf else {
                    return false
                }
            }
            return true
        }
    }
}
