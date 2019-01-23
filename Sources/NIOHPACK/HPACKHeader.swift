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
import NIOHTTP1

/// Very similar to `NIOHTTP1.HTTPHeaders`, but we have our own version to make some
/// small changes inside.
public struct HPACKHeaders {
    final private class _Storage {
        var buffer: ByteBuffer
        var headers: [HPACKHeader]
        
        init(buffer: ByteBuffer, headers: [HPACKHeader]) {
            self.buffer = buffer
            self.headers = headers
        }
        
        func copy() -> _Storage {
            return .init(buffer: self.buffer, headers: self.headers)
        }
    }
    private var _storage: _Storage
    
    fileprivate var buffer: ByteBuffer {
        return self._storage.buffer
    }
    
    fileprivate var headers: [HPACKHeader] {
        return self._storage.headers
    }
    
    /// Returns the `String` for the given `HPACKHeaderIndex`.
    ///
    /// - Parameter idx: The index into the underlying storage.
    /// - Returns: The value.
    private func string(idx: HPACKHeaderIndex) -> String {
        return self.buffer.getString(at: idx.start, length: idx.length)!
    }
    
    /// Return all names.
    private var names: [HPACKHeaderIndex] {
        return self.headers.map { $0.name }
    }
    
    /// Constructor used to create a set of contiguous headers from an encoded
    /// header buffer.
    init(buffer: ByteBuffer, headers: [HPACKHeader]) {
        self._storage = _Storage(buffer: buffer, headers: headers)
    }
    
    /// Constructor that can be used to map between `HTTPHeaders` and `HPACKHeaders` types.
    public init(httpHeaders: HTTPHeaders) {
        // TODO(jim): Once we make HTTPHeaders' internals visible to us, we can just copy the buffer
        // and map the headers.
        let store = httpHeaders.withUnsafeBufferAndIndices { (buf, headers, contiguous) -> _Storage? in
            if contiguous {
                let hpack = headers.map {
                    HPACKHeader(start: $0.name.start, nameLength: $0.name.length, valueStart: $0.value.start, valueLength: $0.value.length)
                }
                return _Storage(buffer: buf, headers: hpack)
            } else {
                return nil
            }
        }
        
        if let store = store {
            // the compiler complains if I just try to assign to self._storage here...
            //_storage = store        // compiler sez: "'self' used before 'self.init' call or assignment to 'self'"
            self.init(buffer: store.buffer, headers: store.headers)
        } else {
            self.init(Array(httpHeaders), allocator: ByteBufferAllocator())
        }
    }
    
    /// Construct a `HPACKHeaders` structure.
    ///
    /// The indexability of all headers is assumed to be the default, i.e. indexable and
    /// rewritable by proxies.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    public init(_ headers: [(String, String)] = []) {
        // Note: this initializer exists because of https://bugs.swift.org/browse/SR-7415.
        // Otherwise we'd only have the one below with a default argument for `allocator`.
        self.init(headers, allocator: ByteBufferAllocator())
    }
    
    /// Construct a `HPACKHeaders` structure.
    ///
    /// The indexability of all headers is assumed to be the default, i.e. indexable and
    /// rewritable by proxies.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    ///     - allocator: The allocator to use to allocate the underlying storage.
    public init(_ headers: [(String, String)] = [], allocator: ByteBufferAllocator) {
        // Reserve enough space in the array to hold all indices.
        var array: [HPACKHeader] = []
        array.reserveCapacity(headers.count)
        
        self.init(buffer: allocator.buffer(capacity: 256), headers: array)
        
        for (key, value) in headers {
            self.add(name: key, value: value)
        }
    }
    
    /// Internal initializer to make things easier for unit tests.
    init(fullHeaders: [(HPACKIndexing, String, String)]) {
        var array: [HPACKHeader] = []
        array.reserveCapacity(fullHeaders.count)
        
        self.init(buffer: ByteBufferAllocator().buffer(capacity: 256), headers: array)
        
        for (indexing, key, value) in fullHeaders {
            self.add(name: key, value: value, indexing: indexing)
        }
    }
    
    /// Add a header name/value pair to the block.
    ///
    /// This method is strictly additive: if there are other values for the given header name
    /// already in the block, this will add a new entry. `add` performs case-insensitive
    /// comparisons on the header field name.
    ///
    /// - Parameter name: The header field name. For maximum compatibility this should be an
    ///     ASCII string. For HTTP/2 lowercase header names are strongly encouraged.
    /// - Parameter value: The header field value to add for the given name.
    public mutating func add(name: String, value: String, indexing: HPACKIndexing = .indexable) {
        precondition(!name.utf8.contains(where: { !$0.isASCII }), "name must be ASCII")
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.copy()
        }
        
        let nameStart = self.buffer.writerIndex
        let nameLength = self._storage.buffer.write(string: name)!
        let valueLength = self._storage.buffer.write(string: value)!
        
        self._storage.headers.append(HPACKHeader(start: nameStart, nameLength: nameLength,
                                                 valueLength: valueLength, indexing: indexing))
    }
    
    /// Add a name/value pair to the block without going through the String class and the
    /// ensuing UTF8 -> UTF16 -> UTF8 conversions.
    ///
    /// This method is strictly additive: if there are other values for the given header name
    /// already in the block, this will add a new entry. `add` performs case-insensitive
    /// comparisons on the header field name.
    ///
    /// - Parameter name: The header field name. For maximum compatibility this should be an
    ///     ASCII string. For HTTP/2 lowercase header names are strongly encouraged.
    /// - Parameter value: The header field value to add for the given name.
    private mutating func add(nameBytes: ByteBufferView, valueBytes: ByteBufferView, indexing: HPACKIndexing = .indexable) {
        precondition(!nameBytes.contains(where: { !$0.isASCII }), "name must be ASCII")
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.copy()
        }
        
        let nameStart = self.buffer.writerIndex
        let nameLength = self._storage.buffer.write(bytes: nameBytes)
        let valueLength = self._storage.buffer.write(bytes: valueBytes)
        self._storage.headers.append(HPACKHeader(start: nameStart, nameLength: nameLength,
                                                 valueLength: valueLength, indexing: indexing))
    }
    
    /// Retrieve all of the values for a given header field name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name. It
    /// does not return a maximally-decomposed list of the header fields, but instead
    /// returns them in their original representation: that means that a comma-separated
    /// header field list may contain more than one entry, some of which contain commas
    /// and some do not. If you want a representation of the header fields suitable for
    /// performing computation on, consider `getCanonicalForm`.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(name: String) -> [String] {
        guard !self.headers.isEmpty else {
            return []
        }
        
        let utf8 = name.utf8
        var array: [String] = []
        for header in self.headers {
            if self.buffer.equalCaseInsensitiveASCII(view: utf8, at: header.name) {
                array.append(self.string(idx: header.value))
            }
        }
        
        return array
    }
    
    /// Checks if a header is present
    ///
    /// - parameters:
    ///     - name: The name of the header
    /// - returns: `true` if a header with the name (and value) exists, `false` otherwise.
    public func contains(name: String) -> Bool {
        guard !self.headers.isEmpty else {
            return false
        }
        
        let utf8 = name.utf8
        for header in self.headers {
            if self.buffer.equalCaseInsensitiveASCII(view: utf8, at: header.name) {
                return true
            }
        }
        return false
    }
    
    /// Retrieves the header values for the given header field in "canonical form": that is,
    /// splitting them on commas as extensively as possible such that multiple values received on the
    /// one line are returned as separate entries. Also respects the fact that Set-Cookie should not
    /// be split in this way.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(canonicalForm name: String) -> [String] {
        let result = self[name]
        guard result.count > 0 else {
            return []
        }
        
        // It's not safe to split Set-Cookie on comma.
        guard name.lowercased() != "set-cookie" else {
            return result
        }
        
        return result.flatMap { $0.split(separator: ",") }.map { String($0.trimWhitespace()) }
    }
    
    /// Special internal function for use by tests.
    internal subscript(position: Int) -> (String, String) {
        precondition(position < self.headers.endIndex, "Position \(position) is beyond bounds of \(self.headers.endIndex)")
        let header = self.headers[position]
        let name = self.string(idx: header.name)
        let value = self.string(idx: header.value)
        return (name, value)
    }
    
    /// Enables encoders to directly enumerate the header views themselves without converting via `String`.
    internal var headerIndices: [HPACKHeader] {
        return self.headers
    }
    internal func view(of index: HPACKHeaderIndex) -> ByteBufferView {
        return self.buffer.viewBytes(at: index.start, length: index.length)
    }
}

extension HPACKHeaders: Sequence {
    public typealias Element = (name: String, value: String, indexable: HPACKIndexing)
    
    /// An iterator of HTTP header fields.
    ///
    /// This iterator will return each value for a given header name separately. That
    /// means that `name` is not guaranteed to be unique in a given block of headers.
    public struct Iterator : IteratorProtocol {
        private var headerParts: Array<(String, String, HPACKIndexing)>.Iterator
        
        init(headerParts: Array<(String, String, HPACKIndexing)>.Iterator) {
            self.headerParts = headerParts
        }
        
        public mutating func next() -> Element? {
            return headerParts.next()
        }
    }
    
    public func makeIterator() -> HPACKHeaders.Iterator {
        return Iterator(headerParts: headers.map { (self.string(idx: $0.name), self.string(idx: $0.value), $0.indexing) }.makeIterator())
    }
}

extension HPACKHeaders: CustomStringConvertible {
    public var description: String {
        var headersArray: [(HPACKIndexing, String, String)] = []
        headersArray.reserveCapacity(self.headers.count)
        
        for h in self.headers {
            headersArray.append((h.indexing, self.string(idx: h.name), self.string(idx: h.value)))
        }
        return headersArray.description
    }
}

extension HPACKHeaders: Equatable {
    public static func == (lhs: HPACKHeaders, rhs: HPACKHeaders) -> Bool {
        guard lhs.headers.count == rhs.headers.count else {
            return false
        }
        
        let lhsNames = Set(lhs.names.lazy.map { lhs.string(idx: $0).lowercased() })
        let rhsNames = Set(rhs.names.lazy.map { rhs.string(idx: $0).lowercased() })
        guard lhsNames == rhsNames else {
            return false
        }
        
        for name in lhsNames {
            guard lhs[name].sorted() == rhs[name].sorted() else {
                return false
            }
        }
        
        return true
    }
}

/// Defines the types of indexing and rewriting operations a decoder may take with
/// regard to this header.
public enum HPACKIndexing: CustomStringConvertible {
    /// Header may be written into the dynamic index table or may be rewritten by
    /// proxy servers.
    case indexable
    /// Header is not written to the dynamic index table, but proxies may rewrite
    /// it en-route, as long as they preserve its non-indexable attribute.
    case nonIndexable
    /// Header may not be written to the dynamic index table, and proxies must
    /// pass it on as-is without rewriting.
    case neverIndexed
    
    public var description: String {
        switch self {
        case .indexable:
            return "[]"
        case .nonIndexable:
            return "[non-indexable]"
        case .neverIndexed:
            return "[neverIndexed]"
        }
    }
}

/// Describes the location of a single header name/value string within a buffer.
struct HPACKHeaderIndex {
    var start: Int
    var length: Int
    
    init(start: Int, length: Int) {
        assert(start >= 0, "start must not be negative")
        assert(length >= 0, "length must not be negative")
        self.start = start
        self.length = length
    }
    
    mutating func adjust(by delta: Int, wrappingAt max: Int) {
        if self.start + delta < 0 {
            self.start += max + delta
        } else {
            self.start += delta
        }
        assert(self.start >= 0, "start must not be negative")
    }
}

extension HPACKHeaderIndex: CustomStringConvertible {
    var description: String {
        return "\(self.start)..<\(self.start + self.length)"
    }
}

struct HPACKHeader {
    var indexing: HPACKIndexing
    var name: HPACKHeaderIndex
    var value: HPACKHeaderIndex
    
    init(start: Int, nameLength: Int, valueLength: Int, indexing: HPACKIndexing = .indexable) {
        self.indexing = indexing
        self.name = HPACKHeaderIndex(start: start, length: nameLength)
        self.value = HPACKHeaderIndex(start: start + nameLength, length: valueLength)
    }
    
    init(start: Int, nameLength: Int, valueStart: Int, valueLength: Int, indexing: HPACKIndexing = .indexable) {
        self.indexing = indexing
        self.name = HPACKHeaderIndex(start: start, length: nameLength)
        self.value = HPACKHeaderIndex(start: valueStart, length: valueLength)
    }
}

private extension ByteBuffer {
    func equalCaseInsensitiveASCII(view: String.UTF8View, at index: HPACKHeaderIndex) -> Bool {
        guard view.count == index.length else {
            return false
        }
        
        let bufView = self.viewBytes(at: index.start, length: index.length)
        for (idx, byte) in view.enumerated() {
            let bufIdx = bufView.index(bufView.startIndex, offsetBy: idx)
            guard byte.isASCII && bufView[bufIdx] & 0xdf == byte & 0xdf else {
                return false
            }
        }
        
        return true
    }
}


internal extension UInt8 {
    var isASCII: Bool {
        return self <= 127
    }
}

/* private but tests */
internal extension Character {
    var isASCIIWhitespace: Bool {
        return self == " " || self == "\t" || self == "\r" || self == "\n" || self == "\r\n"
    }
}

/* private but tests */
internal extension String {
    func trimASCIIWhitespace() -> Substring {
        return self.dropFirst(0).trimWhitespace()
    }
}

private extension Substring {
    func trimWhitespace() -> Substring {
        var me = self
        while me.first?.isASCIIWhitespace == .some(true) {
            me = me.dropFirst()
        }
        while me.last?.isASCIIWhitespace == .some(true) {
            me = me.dropLast()
        }
        return me
    }
}


