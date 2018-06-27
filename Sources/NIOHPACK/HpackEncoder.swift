// swift-tools-version:4.0
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

/// An `HpackDecoder` maintains its own dynamic header table and uses that to
/// encode HTTP headers to an internal byte buffer.
///
/// This encoder functions as an accumulator: each encode operation will append
/// bytes to a buffer maintained by the encoder, which must be cleared using
/// `reset()` before the encode can be re-used. It maintains a header table for
/// outbound header indexing, and will update the header table as described in
/// RFC 7541, appending and evicting items as described there.
public class HpackEncoder {
    /// The default size of the encoder's dynamic header table.
    public static let defaultDynamicTableSize = DynamicHeaderTable.defaultSize
    private static let defaultDataBufferSize = 128
    
    // private but tests
    let headerIndexTable: IndexedHeaderTable
    
    private var huffmanEncoder: HuffmanEncoder
    private var buffer: ByteBuffer
    
    /// The encoder's accumulated data.
    public var encodedData: ByteBuffer {
        return self.buffer
    }
    
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
    public func setMaxDynamicTableSize(_ size: Int, andSendUpdate sendUpdate: Bool = true) {
        self.maxDynamicTableSize = size
        guard sendUpdate else { return }
        self.buffer.write(encodedInteger: UInt(size), prefix: 5, prefixBits: 0x20)
    }
    
    /// Initializer and returns a new HPACK encoder.
    ///
    /// - Parameters:
    ///   - allocator: An allocator for `ByteBuffer`s.
    ///   - maxDynamicTableSize: An initial maximum size for the encoder's dynamic header table.
    public init(allocator: ByteBufferAllocator, maxDynamicTableSize: Int = HpackEncoder.defaultDynamicTableSize) {
        self.headerIndexTable = IndexedHeaderTable(maxDynamicTableSize: maxDynamicTableSize)
        self.buffer = allocator.buffer(capacity: HpackEncoder.defaultDataBufferSize)
        self.huffmanEncoder = HuffmanEncoder(allocator: allocator)
    }
    
    /// Reset the internal buffer, ready to begin encoding a new header block.
    public func reset() {
        buffer.clear()
    }
    
    /// Adds the provided header key/value pairs to the encoder's dynamic header
    /// table.
    ///
    /// - Parameter headers: An array of key/value pairs.
    public func updateDynamicTable(for headers: [(String, String)]) {
        for (name, value) in headers {
            _ = self.headerIndexTable.append(headerNamed: name, value: value)
        }
    }
    
    /// Appends headers in the default fashion: indexed if possible, literal+indexable if not.
    ///
    /// - Parameter headers: A sequence of key/value pairs representing HTTP headers.
    public func append<S: Sequence>(headers: S) where S.Element == (name: String, value: String) {
        for (name, value) in headers {
            if self.append(header: name, value: value) {
                _ = self.headerIndexTable.append(headerNamed: name, value: value)
            }
        }
    }
    
    /// Appends a header/value pair, using indexed names/values if possible. If no indexed pair is available,
    /// it will use an indexed header and literal value, or a literal header and value. The name/value pair
    /// will be indexed for future use.
    ///
    /// - returns: `true` if this name/value pair should be inserted into the dynamic table.
    public func append(header: String, value: String) -> Bool {
        if let (index, hasValue) = self.headerIndexTable.firstHeaderMatch(for: header, value: value) {
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
            self.appendEncodedString(header)
            self.appendEncodedString(value)
        }
        
        // add to the dynamic table
        return true
    }
    
    private func appendEncodedString(_ string: String) {
        // encode the value
        self.huffmanEncoder.reset()
        let len = self.huffmanEncoder.encode(string)
        self.buffer.write(encodedInteger: UInt(len), prefix: 7, prefixBits: 0x80)
        self.buffer.copy(from: huffmanEncoder.data)
    }
    
    /// Appends a header that is *not* to be entered into the dynamic header table, but allows that
    /// stipulation to be overriden by a proxy server/rewriter.
    public func appendNonIndexed(header: String, value: String) {
        if let (index, _) = self.headerIndexTable.firstHeaderMatch(for: header, value: "") {
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
    public func appendNeverIndexed(header: String, value: String) {
        if let (index, _) = self.headerIndexTable.firstHeaderMatch(for: header, value: "") {
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
