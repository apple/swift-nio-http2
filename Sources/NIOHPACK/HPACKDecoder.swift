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
/// decode indexed HTTP headers, along with Huffman-encoded strings and
/// HPACK-encoded integers.
///
/// Its only shared state is its dynamic header table; each decode operation
/// will update the header table as described in RFC 7541, appending and
/// evicting items as described there.
public struct HPACKDecoder {
    public static let maxDynamicTableSize = DynamicHeaderTable.defaultSize
    
    // private but tests
    var headerTable: IndexedHeaderTable
    
    private let allocator: ByteBufferAllocator
    
    private let huffmanDecoder = HuffmanDecoder()
    
    var dynamicTableLength: Int {
        return headerTable.dynamicTableLength
    }
    
    /// The maximum size of the dynamic table. This is defined in RFC 7541
    /// to be the sum of [name-octet-count] + [value-octet-count] + 32 for
    /// each header it contains.
    public internal(set) var maxDynamicTableLength: Int {
        get { return headerTable.maxDynamicTableLength }
        /* private but tests */
        set { headerTable.maxDynamicTableLength = newValue }
    }
    
    /// Creates a new decoder
    ///
    /// - Parameter maxDynamicTableSize: Maximum allowed size of the dynamic header table.
    public init(maxDynamicTableSize: Int = HPACKDecoder.maxDynamicTableSize, allocator: ByteBufferAllocator = ByteBufferAllocator()) {
        self.headerTable = IndexedHeaderTable(maxDynamicTableSize: maxDynamicTableSize)
        self.allocator = allocator
    }
    
    /// Reads HPACK encoded header data from a `ByteBuffer`.
    ///
    /// It is expected that the buffer cover only the bytes of the header list, i.e.
    /// that this is in fact a slice containing only the payload bytes of a
    /// `HEADERS` or `CONTINUATION` frame.
    ///
    /// - Parameter buffer: A byte buffer containing the encoded header bytes.
    /// - Returns: An array of (name, value) pairs.
    /// - Throws: HpackDecoder.Error in the event of a decode failure.
    public mutating func decodeHeaders(from buffer: inout ByteBuffer) throws -> HPACKHeaders {
        // take a local copy to mutate
        var bufCopy = buffer
        
        var decodedBuffer = allocator.buffer(capacity: buffer.capacity)
        var headers: [HPACKHeader] = []
        while bufCopy.readableBytes > 0 {
            if let header = try decodeHeader(from: &bufCopy, into: &decodedBuffer) {
                headers.append(header)
            }
        }
        
        buffer = bufCopy
        return HPACKHeaders(buffer: decodedBuffer, headers: headers)
    }
    
    private mutating func decodeHeader(from buffer: inout ByteBuffer, into target: inout ByteBuffer) throws -> HPACKHeader? {
        // peek at the first byte to decide how many significant bits of that byte we
        // will need to include in our decoded integer. Some values use a one-bit prefix,
        // some use two, or four.
        let initial: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        switch initial {
        case let x where x & 0x80 == 0x80:
            // 0b1xxxxxxx -- one-bit prefix, seven bits of value
            // purely-indexed header field/value
            let hidx = try buffer.readEncodedInteger(withPrefix: 7)
            return try self.decodeIndexedHeader(from: Int(hidx), into: &target)
            
        case let x where x & 0xc0 == 0x40:
            // 0b01xxxxxx -- two-bit prefix, six bits of value
            // literal header with possibly-indexed name
            let hidx = try buffer.readEncodedInteger(withPrefix: 6)
            return try self.decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx), into: &target)
            
        case let x where x & 0xf0 == 0x00:
            // 0x0000xxxx -- four-bit prefix, four bits of value
            // literal header with possibly-indexed name, not added to dynamic table
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            var header = try self.decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx), into: &target, addToIndex: false)
            header.indexing = .nonIndexable
            return header
            
        case let x where x & 0xf0 == 0x10:
            // 0x0001xxxx -- four-bit prefix, four bits of value
            // literal header with possibly-indexed name, never added to dynamic table nor
            // rewritten by proxies
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            var header = try self.decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx), into: &target, addToIndex: false)
            header.indexing = .immutable
            return header
            
        case let x where x & 0xe0 == 0x20:
            // 0x001xxxxx -- three-bit prefix, five bits of value
            // dynamic header table size update
            self.headerTable.maxDynamicTableLength = try Int(buffer.readEncodedInteger(withPrefix: 5))
            return nil
            
        default:
            throw NIOHPACKErrors.InvalidHeaderStartByte(byte: initial)
        }
    }
    
    private func decodeIndexedHeader(from hidx: Int, into target: inout ByteBuffer) throws -> HPACKHeader {
        let (h, v) = try self.headerTable.headerViews(at: hidx)
        
        let start = target.writerIndex
        let nlen = target.write(bytes: h)
        let vlen = target.write(bytes: v)
        
        return HPACKHeader(start: start, nameLength: nlen, valueLength: vlen)
    }
    
    private mutating func decodeLiteralHeader(from buffer: inout ByteBuffer, headerIndex: Int, into target: inout ByteBuffer,
                                     addToIndex: Bool = true) throws -> HPACKHeader {
        let nameStart = target.writerIndex
        let nameLen: Int
        let valueLen: Int
        
        if headerIndex != 0 {
            let (name, _) = try self.headerTable.headerViews(at: headerIndex)
            nameLen = target.write(bytes: name)
        } else {
            nameLen = try self.readEncodedString(from: &buffer, into: &target)
        }
        
        valueLen = try self.readEncodedString(from: &buffer, into: &target)
        
        if addToIndex {
            let nameView = target.viewBytes(at: nameStart, length: nameLen)
            let valueView = target.viewBytes(at: nameStart + nameLen, length: valueLen)
            
            try headerTable.add(headerNameBytes: nameView, valueBytes: valueView)
        }
        
        return HPACKHeader(start: nameStart, nameLength: nameLen, valueLength: valueLen)
    }
    
    private func readEncodedString(from buffer: inout ByteBuffer, into target: inout ByteBuffer) throws -> Int {
        // peek to read the encoding bit
        let initialByte: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        let huffmanEncoded = initialByte & 0x80 == 0x80
        
        // read the length; there's a seven-bit prefix here (one-bit encoding flag)
        let len = try Int(buffer.readEncodedInteger(withPrefix: 7))
        guard len <= buffer.readableBytes else {
            throw NIOHPACKErrors.StringLengthBeyondPayloadSize(length: len, available: buffer.readableBytes)
        }
        let view = buffer.viewBytes(at: buffer.readerIndex, length: len)
        
        let outputLength: Int
        if huffmanEncoded {
            outputLength = try self.readHuffmanString(from: view, into: &target)
        } else {
            outputLength = target.write(bytes: view)
        }
        
        buffer.moveReaderIndex(forwardBy: view.count)
        return outputLength
    }
    
    private func readHuffmanString(from buffer: ByteBufferView, into target: inout ByteBuffer) throws -> Int {
        return try self.huffmanDecoder.decodeString(from: buffer, into: &target)
    }
}
