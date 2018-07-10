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
    
    mutating func adjust(by delta: Int, wrappingAt max: Int) {
        name.adjust(by: delta, wrappingAt: max)
        value.adjust(by: delta, wrappingAt: max)
    }
}

extension HPACKHeaderIndex : CustomStringConvertible {
    var description: String {
        return "\(self.start)..<\(self.start + self.length)"
    }
}

extension HeaderTableEntry : CustomStringConvertible {
    var description: String {
        return "(name: \(self.name), value: \(self.value))"
    }
}

struct HeaderTableStorage {
    static let defaultMaxSize = 4096
    
    private var buffer: SimpleRingBuffer
    private var headers: CircularBuffer<HeaderTableEntry>
    
    private(set) var maxSize: Int
    private(set) var length: Int = 0
    
    var count: Int {
        return self.headers.count
    }
    
    init(maxSize: Int = HeaderTableStorage.defaultMaxSize, allocator: ByteBufferAllocator = ByteBufferAllocator()) {
        self.maxSize = maxSize
        self.buffer = SimpleRingBuffer(capacity: self.maxSize)
        self.headers = CircularBuffer(initialRingCapacity: self.maxSize / 64)    // rough guess: 64 bytes per header
    }
    
    init(staticHeaderList: [(String, String)]) {
        // calculate likely total byte length we will actually need
        // the static table is all ASCII, so character count == byte count here
        let bytesNeeded = staticHeaderList.reduce(0) { $0 + $1.0.count + $1.1.count }
        // set this according to what the length algorithm would normally expect
        
        // now allocate & encode all the things
        self.buffer = SimpleRingBuffer(capacity: bytesNeeded)
        self.headers = CircularBuffer(initialRingCapacity: staticHeaderList.count)
        
        var len = 0
        
        for (name, value) in staticHeaderList {
            let nameStart = self.buffer.writerIndex
            let nameLen = try! self.buffer.write(string: name)
            let valueStart = self.buffer.writerIndex
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
    
    func findHeaders<C : Collection>(matching name: C) -> [HeaderTableEntry] where C.Element == UInt8 {
        guard !self.headers.isEmpty else {
            return []
        }
        
        var result = [HeaderTableEntry]()
        for header in self.headers {
            if self.buffer.equalCaseInsensitiveASCII(view: name, at: header.name) {
                result.append(header)
            }
        }
        
        return result
    }
    
    func indices<C : Collection>(matching name: C) -> [Int] where C.Element == UInt8 {
        guard !self.headers.isEmpty else {
            return []
        }
        
        var result = [Int]()
        
        for (idx, header) in self.headers.enumerated() {
            if self.buffer.equalCaseInsensitiveASCII(view: name, at: header.name) {
                result.append(idx)
            }
        }
        
        // no matches
        return result
    }
    
    func string(idx: HPACKHeaderIndex) -> String {
        return self.buffer.getString(at: idx.start, length: idx.length)!
    }
    
    func view(of idx: HPACKHeaderIndex) -> RingBufferView {
        return self.buffer.viewBytes(at: idx.start, length: idx.length)
    }
    
    mutating func setTableSize(to newSize: Int) {
        if newSize < self.length {
            // need to clear out some things first.
            while newSize < self.length {
                _ = purgeOne()
            }
        }
        
        // if this rebases, we will need to alter all our header indices
        let startIndex = self.buffer.readerIndex
        self.buffer.changeCapacity(to: newSize)
        self.maxSize = newSize
        
        if startIndex == self.buffer.readerIndex {
            // no index changes
            return
        }
        
        // otherwise, compute a delta and apply it to all indices
        let delta = self.buffer.readerIndex - startIndex    // if index decreased, we apply a negative delta
        for index in self.headers.indices {
            self.headers[index].adjust(by: delta, wrappingAt: self.buffer.capacity)
        }
    }
    
    mutating func add<S : Sequence>(name: S, value: S) throws where S.Element == UInt8 {
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
    
    mutating func add<C : ContiguousCollection>(nameBytes: C, valueBytes: C) throws where C.Element == UInt8 {
        var len = 0
        do {
            let (nameStart, nameLen, valueStart, valueLen) = try self.encode(name: nameBytes, value: valueBytes)
            len = nameLen + valueLen
            
            try prependHeaderEntry(nameStart: nameStart, nameLen: nameLen, valueStart: valueStart, valueLen: valueLen)
        } catch {
            // NB: moving backwards here
            self.buffer.unwrite(byteCount: len)
            throw error
        }
    }
    
    private mutating func encode<S : Sequence>(name: S, value: S) throws -> (nstart: Int, nlen: Int, vstart: Int, vlen: Int) where S.Element == UInt8 {
        let nstart = self.buffer.writerIndex
        let nlen = try self.buffer.write(bytes: name)
        let vstart = self.buffer.writerIndex
        let vlen = try self.buffer.write(bytes: value)
        return (nstart, nlen, vstart, vlen)
    }
    
    private mutating func encode<C : ContiguousCollection>(name: C, value: C) throws -> (nstart: Int, nlen: Int, vstart: Int, vlen: Int) where C.Element == UInt8 {
        let nstart = self.buffer.writerIndex
        let nlen = try self.buffer.write(bytes: name)
        let vstart = self.buffer.writerIndex
        let vlen = try self.buffer.write(bytes: value)
        return (nstart, nlen, vstart, vlen)
    }
    
    private mutating func prependHeaderEntry(nameStart: Int, nameLen: Int, valueStart: Int, valueLen: Int) throws {
        let nameIndex = HPACKHeaderIndex(start: nameStart, length: nameLen)
        let valueIndex = HPACKHeaderIndex(start: valueStart, length: valueLen)
        let entry = HeaderTableEntry(name: nameIndex, value: valueIndex)
        
        let newLength = self.length + entry.length
        if newLength > self.maxSize {
            // Danger, Will Robinson!
            throw RingBufferError.BufferOverrun(amount: newLength - maxSize)
        }
        
        self.headers.prepend(entry)
        self.length = newLength
    }
    
    mutating func purge(toRelease count: Int) {
        guard count <= self.length else {
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
    
    private mutating func purgeOne() -> Int {
        precondition(self.headers.isEmpty == false, "should not call purgeOne() unless we have something to purge")
        // Remember: we're removing from the *end* of the header list, since we *prepend* new items there, but we're
        // removing bytes from the *start* of the storage, because we *append* there.
        let entry = self.headers.removeLast()
        self.buffer.moveReaderIndex(forwardBy: entry.name.length + entry.value.length)
        self.length -= entry.length
        return entry.length
    }
    
    // internal for testing
    func dumpHeaders() -> String {
        return self.headers.enumerated().reduce("") {
            $0 + "\($1.0 + StaticHeaderTable.count) - \(self.string(idx: $1.1.name)) : \(self.string(idx: $1.1.value))\n"
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

private extension SimpleRingBuffer {
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
