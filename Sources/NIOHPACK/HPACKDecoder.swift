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
/// There are two pieces of shared state: the dynamic header table and an
/// internal `ByteBuffer` used for decode operations. Each decode operation
/// will update the header table as described in RFC 7541, appending and
/// evicting items as described there.
///
/// - note: This type is not thread-safe. It is designed to be owned and operated
/// by a single HTTP/2 stream, operating on a single NIO `EventLoop`.
public struct HPACKDecoder {
    public static var maxDynamicTableSize: Int {
        return DynamicHeaderTable.defaultSize
    }
    
    // private but tests
    var headerTable: IndexedHeaderTable
    
    private var decodeBuffer: ByteBuffer
    
    var dynamicTableLength: Int {
        return headerTable.dynamicTableLength
    }

    /// The current allowed length of the dynamic portion of the header table. May be
    /// less than the current protocol-assigned maximum supplied by a SETTINGS frame.
    public private(set) var allowedDynamicTableLength: Int {
        get { return self.headerTable.dynamicTableAllowedLength }
        set { self.headerTable.dynamicTableAllowedLength = newValue }
    }
    
    /// A string value discovered in a HPACK buffer. The value can either indicate an entry
    /// in the header table index or the start of an inline literal string.
    enum HPACKString {
        case indexed(index: Int)
        case literal
        
        init(fromEncodedInteger value: Int) {
            switch value {
            case 0:
                self = .literal
            default:
                self = .indexed(index: value)
            }
        }
    }
    
    /// The maximum size of the dynamic table as set by the enclosing protocol. This is defined in RFC 7541
    /// to be the sum of [name-octet-count] + [value-octet-count] + 32 for
    /// each header it contains.
    public var maxDynamicTableLength: Int {
        get { return headerTable.maxDynamicTableLength }
        /* private but tests */
        set { headerTable.maxDynamicTableLength = newValue }
    }
    
    /// Creates a new decoder
    ///
    /// - Parameter maxDynamicTableSize: Maximum allowed size of the dynamic header table.
    public init(allocator: ByteBufferAllocator, maxDynamicTableSize: Int = HPACKDecoder.maxDynamicTableSize) {
        self.headerTable = IndexedHeaderTable(allocator: allocator, maxDynamicTableSize: maxDynamicTableSize)
        
        // start the decode buffer at the requested size of the dynamic header list table, or the default
        // size, whichever is larger.
        self.decodeBuffer = allocator.buffer(capacity: max(maxDynamicTableSize, DynamicHeaderTable.defaultSize))
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
        self.decodeBuffer.clear()
        
        var headers: [HPACKHeader] = []
        while bufCopy.readableBytes > 0 {
            // this will update our own `decodeBuffer` property.
            if let header = try self.decodeHeader(from: &bufCopy) {
                headers.append(header)
            }
        }
        
        buffer = bufCopy
        return HPACKHeaders(buffer: self.decodeBuffer, headers: headers)
    }
    
    private mutating func decodeHeader(from buffer: inout ByteBuffer) throws -> HPACKHeader? {
        // peek at the first byte to decide how many significant bits of that byte we
        // will need to include in our decoded integer. Some values use a one-bit prefix,
        // some use two, or four.
        // This one-byte read is guaranteed safe because `decodeHeaders(from:)` only calls into
        // this function if at least one byte is available to read.
        let initial: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        switch initial {
        case let x where x & 0b1000_0000 == 0b1000_0000:
            // 0b1xxxxxxx -- one-bit prefix, seven bits of value
            // purely-indexed header field/value
            let hidx = try buffer.readEncodedInteger(withPrefix: 7)
            return try self.decodeIndexedHeader(from: Int(hidx))
            
        case let x where x & 0b1100_0000 == 0b0100_0000:
            // 0b01xxxxxx -- two-bit prefix, six bits of value
            // literal header with possibly-indexed name
            let hidx = try buffer.readEncodedInteger(withPrefix: 6)
            return try self.decodeLiteralHeader(from: &buffer, headerName: HPACKString(fromEncodedInteger: hidx), addToIndex: true)
            
        case let x where x & 0b1111_0000 == 0b0000_0000:
            // 0b0000xxxx -- four-bit prefix, four bits of value
            // literal header with possibly-indexed name, not added to dynamic table
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            var header = try self.decodeLiteralHeader(from: &buffer, headerName: HPACKString(fromEncodedInteger: hidx), addToIndex: false)
            header.indexing = .nonIndexable
            return header
            
        case let x where x & 0b1111_0000 == 0b0001_0000:
            // 0b0001xxxx -- four-bit prefix, four bits of value
            // literal header with possibly-indexed name, never added to dynamic table nor
            // rewritten by proxies
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            var header = try self.decodeLiteralHeader(from: &buffer, headerName: HPACKString(fromEncodedInteger: hidx), addToIndex: false)
            header.indexing = .neverIndexed
            return header
            
        case let x where x & 0b1110_0000 == 0b0010_0000:
            // 0b001xxxxx -- three-bit prefix, five bits of value
            // dynamic header table size update
            let newMaxLength = try Int(buffer.readEncodedInteger(withPrefix: 5))
            
            // RFC 7541 § 4.2 <https://httpwg.org/specs/rfc7541.html#maximum.table.size> gives us two conditions:
            //
            // 1. "the chosen size MUST stay lower than or equal to the maximum set by the protocol."
            guard newMaxLength <= self.headerTable.maxDynamicTableLength else {
                throw NIOHPACKErrors.InvalidDynamicTableSize(requestedSize: newMaxLength, allowedSize: self.headerTable.maxDynamicTableLength)
            }
            
            // 2. "This dynamic table size update MUST occur at the beginning of the first header block
            //    following the change to the dynamic table size."
            guard self.decodeBuffer.readableBytes == 0 else {
                // If our decode buffer has any data in it, then this is out of place.
                // Treat it as an invalid input
                throw NIOHPACKErrors.IllegalDynamicTableSizeChange()
            }
            
            self.allowedDynamicTableLength = newMaxLength
            return nil
            
        default:
            throw NIOHPACKErrors.InvalidHeaderStartByte(byte: initial)
        }
    }
    
    private mutating func decodeIndexedHeader(from hidx: Int) throws -> HPACKHeader {
        let (h, v) = try self.headerTable.headerViews(at: hidx)
        
        let start = self.decodeBuffer.writerIndex
        let nlen = self.decodeBuffer.writeBytes(h)
        let vlen = self.decodeBuffer.writeBytes(v)
        
        return HPACKHeader(start: start, nameLength: nlen, valueLength: vlen)
    }
    
    private mutating func decodeLiteralHeader(from buffer: inout ByteBuffer, headerName: HPACKString,
                                              addToIndex: Bool) throws -> HPACKHeader {
        let nameStart = self.decodeBuffer.writerIndex
        let nameLen: Int
        let valueLen: Int
        
        switch headerName {
        case .indexed(let idx):
            let (name, _) = try self.headerTable.headerViews(at: idx)
            nameLen = self.decodeBuffer.writeBytes(name)
        case .literal:
            nameLen = try self.readEncodedString(from: &buffer)
        }
        
        valueLen = try self.readEncodedString(from: &buffer)
        
        if addToIndex {
            // These views are safe to force-unwrap as we have just written these bytes into the decode buffer.
            let nameView = self.decodeBuffer.viewBytes(at: nameStart, length: nameLen)!
            let valueView = self.decodeBuffer.viewBytes(at: nameStart + nameLen, length: valueLen)!
            
            try headerTable.add(headerNamed: nameView, value: valueView)
        }
        
        return HPACKHeader(start: nameStart, nameLength: nameLen, valueLength: valueLen)
    }
    
    private mutating func readEncodedString(from buffer: inout ByteBuffer) throws -> Int {
        // peek to read the encoding bit
        guard let initialByte: UInt8 = buffer.getInteger(at: buffer.readerIndex) else {
            throw NIOHPACKErrors.InsufficientInput()
        }
        let huffmanEncoded = initialByte & 0x80 == 0x80
        
        // read the length; there's a seven-bit prefix here (one-bit encoding flag)
        let len = try Int(buffer.readEncodedInteger(withPrefix: 7))
        guard len <= buffer.readableBytes else {
            throw NIOHPACKErrors.StringLengthBeyondPayloadSize(length: len, available: buffer.readableBytes)
        }
        
        let outputLength: Int
        if huffmanEncoded {
            outputLength = try buffer.getHuffmanEncodedString(at: buffer.readerIndex, length: len, into: &self.decodeBuffer)
        } else {
            // This force-unwrap is safe as we have checked above that len is less than or equal to the buffer readable bytes.
            outputLength = self.decodeBuffer.writeBytes(buffer.viewBytes(at: buffer.readerIndex, length: len)!)
        }
        
        buffer.moveReaderIndex(forwardBy: len)
        return outputLength
    }
}
