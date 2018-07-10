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

/// An `HPACKDecoder` maintains its own dynamic header table and uses that to
/// encode HTTP headers to an internal byte buffer.
///
/// This encoder functions as an accumulator: each encode operation will append
/// bytes to a buffer maintained by the encoder, which must be cleared using
/// `reset()` before the encode can be re-used. It maintains a header table for
/// outbound header indexing, and will update the header table as described in
/// RFC 7541, appending and evicting items as described there.
public struct HPACKEncoder {
    /// The default size of the encoder's dynamic header table.
    public static let defaultDynamicTableSize = DynamicHeaderTable.defaultSize
    private static let defaultDataBufferSize = 128
    
    // private but tests
    var headerIndexTable: IndexedHeaderTable
    
    private var huffmanEncoder: HuffmanEncoder
    private var buffer: ByteBuffer
    
    /// The encoder's accumulated data.
    public var encodedData: ByteBuffer {
        return self.buffer
    }
    
    /// Whether to use Huffman encoding.
    public var useHuffmanEncoding: Bool = true
    
    /// The current size of the dynamic table.
    ///
    /// This is defined as the sum of [name] + [value] + 32 for each header.
    public var dynamicTableSize: Int {
        return self.headerIndexTable.dynamicTableLength
    }
    
    /// The maximum allowed size to which the dynamic header table may grow.
    public var maxDynamicTableSize: Int {
        get { return self.headerIndexTable.maxDynamicTableLength }
        set { self.headerIndexTable.maxDynamicTableLength = newValue }
    }
    
    /// Sets the maximum size for the dynamic table and optionally encodes the new value
    /// into the current packed header block to send to the peer.
    ///
    /// - Parameter size: The new maximum size for the dynamic header table.
    /// - Parameter sendUpdate: If `true`, sends the new maximum table size to the peer
    ///                         by encoding the value inline with the current header set.
    ///                         Default = `true`.
    public mutating func setMaxDynamicTableSize(_ size: Int, andSendUpdate sendUpdate: Bool = true) {
        self.maxDynamicTableSize = size
        guard sendUpdate else { return }
        self.buffer.write(encodedInteger: UInt(size), prefix: 5, prefixBits: 0x20)
    }
    
    /// Initializer and returns a new HPACK encoder.
    ///
    /// - Parameters:
    ///   - allocator: An allocator for `ByteBuffer`s.
    ///   - maxDynamicTableSize: An initial maximum size for the encoder's dynamic header table.
    public init(allocator: ByteBufferAllocator, maxDynamicTableSize: Int = HPACKEncoder.defaultDynamicTableSize) {
        self.headerIndexTable = IndexedHeaderTable(maxDynamicTableSize: maxDynamicTableSize)
        self.buffer = allocator.buffer(capacity: HPACKEncoder.defaultDataBufferSize)
        self.huffmanEncoder = HuffmanEncoder()
    }
    
    /// Reset the internal buffer, ready to begin encoding a new header block.
    public mutating func reset() {
        buffer.clear()
    }
    
    /// Appends headers in the default fashion: indexed if possible, literal+indexable if not.
    ///
    /// - Parameter headers: A sequence of key/value pairs representing HTTP headers.
    public mutating func append<S: Sequence>(headers: S) throws where S.Element == (name: String, value: String) {
        for (name, value) in headers {
            if try self._append(header: name.utf8, value: value.utf8) {
                try self.headerIndexTable.add(headerNamed: name, value: value)
            }
        }
    }
    
    /// Appends headers with their specified indexability.
    ///
    /// - Parameter headers: A sequence of key/value/indexability tuples representing HTTP headers.
    public mutating func append<S : Sequence>(headers: S) throws where S.Element == (name: String, value: String, indexing: HPACKIndexing) {
        for (name, value, indexing) in headers {
            switch indexing {
            case .indexable:
                if try self._append(header: name.utf8, value: value.utf8) {
                    try self.headerIndexTable.add(headerNamed: name, value: value)
                }
            case .nonIndexable:
                self._appendNonIndexed(header: name.utf8, value: value.utf8)
            case .immutable:
                self._appendNeverIndexed(header: name.utf8, value: value.utf8)
            }
        }
    }
    
    public mutating func append(headers: HPACKHeaders) throws {
        for header in headers.headerIndices {
            let nameView = headers.view(of: header.name)
            let valueView = headers.view(of: header.value)
            
            switch header.indexing {
            case .indexable:
                if try self._append(header: nameView, value: valueView) {
                    try self.headerIndexTable.add(headerNameBytes: nameView, valueBytes: valueView)
                }
            case .nonIndexable:
                self._appendNonIndexed(header: nameView, value: valueView)
            case .immutable:
                self._appendNeverIndexed(header: nameView, value: valueView)
            }
        }
    }
    
    /// Appends a header/value pair, using indexed names/values if possible. If no indexed pair is available,
    /// it will use an indexed header and literal value, or a literal header and value. The name/value pair
    /// will be indexed for future use.
    public mutating func append(header name: String, value: String) throws {
        if try self._append(header: name.utf8, value: value.utf8) {
            try self.headerIndexTable.add(headerNamed: name, value: value)
        }
    }
    
    /// Returns `true` if the item needs to be added to the header table
    private mutating func _append<C : Collection>(header name: C, value: C) throws -> Bool where C.Element == UInt8 {
        if let (index, hasValue) = self.headerIndexTable.firstHeaderMatch(for: name, value: value) {
            if hasValue {
                // purely indexed. Nice & simple.
                self.buffer.write(encodedInteger: UInt(index), prefix: 7, prefixBits: 0x80)
                // everything is indexed-- nothing more to do!
                return false
            } else {
                // no value, so append the index to represent the name, followed by the value's
                // length
                self.buffer.write(encodedInteger: UInt(index), prefix: 6, prefixBits: 0x40)
                // now encode and append the value string
                self.appendEncodedString(value)
            }
        } else {
            // no indexed name or value. Have to add them both, with a zero index.
            self.buffer.write(integer: UInt8(0x40))
            self.appendEncodedString(name)
            self.appendEncodedString(value)
        }
        
        return true
    }
    
    private mutating func appendEncodedString<C : Collection>(_ utf8: C) where C.Element == UInt8 {
        // encode the value
        if useHuffmanEncoding {
            // problem: we need to encode the length before the encoded bytes, so we can't just receive the length
            // after encoding to the target buffer itself. So we have to determine the length first.
            self.buffer.write(encodedInteger: UInt(self.huffmanEncoder.encodedLength(of: utf8)), prefix: 7, prefixBits: 0x80)
            self.huffmanEncoder.encode(utf8, toBuffer: &self.buffer)
        } else {
            self.buffer.write(encodedInteger: UInt(utf8.count), prefix: 7)  // prefix bits are clear
            self.buffer.write(bytes: utf8)
        }
    }
    
    /// Appends a header that is *not* to be entered into the dynamic header table, but allows that
    /// stipulation to be overriden by a proxy server/rewriter.
    public mutating func appendNonIndexed(header: String, value: String) {
        self._appendNonIndexed(header: header.utf8, value: value.utf8)
    }
    
    private mutating func _appendNonIndexed<C : Collection>(header: C, value: C) where C.Element == UInt8 {
        if let (index, _) = self.headerIndexTable.firstHeaderMatch(for: header, value: nil) {
            // we actually don't care if it has a value in this instance; we're only indexing the
            // name.
            self.buffer.write(encodedInteger: UInt(index), prefix: 4)    // top 4 bits are all zero
            // now append the value
            self.appendEncodedString(value)
        } else {
            self.buffer.write(integer: UInt8(0))    // top 4 bits are zero, and index is zero (no index)
            self.appendEncodedString(header)
            self.appendEncodedString(value)
        }
    }
    
    /// Appends a header that is *never* indexed, preventing even rewriting proxies from doing so.
    public mutating func appendNeverIndexed(header: String, value: String) {
        self._appendNeverIndexed(header: header.utf8, value: value.utf8)
    }
    
    private mutating func _appendNeverIndexed<C : Collection>(header: C, value: C) where C.Element == UInt8 {
        if let (index, _) = self.headerIndexTable.firstHeaderMatch(for: header, value: nil) {
            // we only use the index in this instance
            self.buffer.write(encodedInteger: UInt(index), prefix: 4, prefixBits: 0x10)
            // now append the value
            self.appendEncodedString(value)
        } else {
            self.buffer.write(integer: UInt8(0x10))     // prefix bits + zero index
            self.appendEncodedString(header)
            self.appendEncodedString(value)
        }
    }
}

extension ByteBuffer {
    /// Shorthand for taking a copy of a ByteBuffer and passing it into a mutating write() method.
    mutating func copy(from buffer: ByteBuffer) {
        var buf = buffer
        self.write(buffer: &buf)
    }
}

extension ByteBufferView : CustomDebugStringConvertible {
    public var debugDescription: String {
        var desc = "\(self.count) bytes: ["
        for byte in self {
            let hexByte = String(byte, radix: 16)
            desc += " \(hexByte.count == 1 ? "0" : "")\(hexByte)"
        }
        desc += " ]"
        return desc
    }
}
