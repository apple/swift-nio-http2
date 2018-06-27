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
/// decode indexed HTTP headers, along with Huffman-encoded strings and
/// HPACK-encoded integers.
///
/// Its only shared state is its dynamic header table; each decode operation
/// will update the header table as described in RFC 7541, appending and
/// evicting items as described there.
public class HpackDecoder {
    public static let maxDynamicTableSize = DynamicHeaderTable.defaultSize
    
    // private but tests
    let headerTable: IndexedHeaderTable
    
    private let huffmanDecoder = HuffmanDecoder()
    
    var dynamicTableLength: Int {
        return headerTable.dynamicTableLength
    }
    
    /// The maximum size of the dynamic table. This is defined in RFC 7541
    /// to be the sum of [name-octet-count] + [value-octet-count] + 32 for
    /// each header it contains.
    public var maxDynamicTableLength: Int {
        get { return headerTable.maxDynamicTableLength }
        set { headerTable.maxDynamicTableLength = newValue }
    }
    
    /// Errors that can occur during header decoding.
    public enum Error : Swift.Error {
        /// The peer referenced a header index that doesn't exist here.
        case invalidIndexedHeader(Int)
        /// The peer referenced an indexed header with accompanying value,
        /// but neglected to provide the value.
        case indexedHeaderWithNoValue(Int)
        /// An encoded string's length would take us beyond the available
        /// number of bytes.
        case indexOutOfRange(Int, Int)
        /// Decoded string data was not valid UTF-8.
        case invalidUTF8Stringdata(ByteBuffer)
        /// The start byte of a header did not match any of the values
        /// laid out in the HPACK specification.
        case invalidHeaderStartByte(UInt8, Int)
        /// A new header could not be added to the dynamic table. Usually
        /// this means the header itself is larger than the maximum
        /// dynamic table size.
        case failedToAddIndexedHeader(String, String)
    }
    
    /// Creates a new decoder
    ///
    /// - Parameter maxDynamicTableSize: Maximum allowed size of the dynamic header table.
    public init(maxDynamicTableSize: Int = HpackDecoder.maxDynamicTableSize) {
        headerTable = IndexedHeaderTable(maxDynamicTableSize: maxDynamicTableSize)
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
    public func decodeHeaders(from buffer: inout ByteBuffer) throws -> [(String, String)] {
        var result = [(String, String)]()
        while buffer.readableBytes > 0 {
            if let pair = try decodeHeader(from: &buffer) {
                result.append(pair)
            }
        }
        return result
    }
    
    private func decodeHeader(from buffer: inout ByteBuffer) throws -> (String, String)? {
        // peek at the first byte to decide how many significant bits of that byte we
        // will need to include in our decoded integer. Some values use a one-bit prefix,
        // some use two, or four.
        let initial: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        switch initial {
        case let x where x & 0x80 == 0x80:
            // 0b1xxxxxxx -- one-bit prefix, seven bits of value
            // purely-indexed header field/value
            let hidx = try buffer.readEncodedInteger(withPrefix: 7)
            return try self.decodeIndexedHeader(from: Int(hidx))
            
        case let x where x & 0xc0 == 0x40:
            // 0b01xxxxxx -- two-bit prefix, six bits of value
            // literal header with possibly-indexed name
            let hidx = try buffer.readEncodedInteger(withPrefix: 6)
            return try self.decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx))
            
        case let x where x & 0xf0 == 0x00:
            // 0x0000xxxx -- four-bit prefix, four bits of value
            // literal header with possibly-indexed name, not added to dynamic table
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            return try self.decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx), addToIndex: false)
            
        case let x where x & 0xf0 == 0x10:
            // 0x0001xxxx -- four-bit prefix, four bits of value
            // literal header with possibly-indexed name, never added to dynamic table nor
            // rewritten by proxies
            let hidx = try buffer.readEncodedInteger(withPrefix: 4)
            return try self.decodeLiteralHeader(from: &buffer, headerIndex: Int(hidx), addToIndex: false)
            
        case let x where x & 0xe0 == 0x20:
            // 0x001xxxxx -- three-bit prefix, five bits of value
            // dynamic header table size update
            self.maxDynamicTableLength = try Int(buffer.readEncodedInteger(withPrefix: 5))
            return nil
            
        default:
            throw Error.invalidHeaderStartByte(initial, 0)
        }
    }
    
    private func decodeIndexedHeader(from hidx: Int) throws -> (String, String) {
        guard let (h, v) = self.headerTable.header(at: hidx) else {
            throw Error.invalidIndexedHeader(hidx)
        }
        guard !v.isEmpty else {
            throw Error.indexedHeaderWithNoValue(hidx)
        }
        
        return (h, v)
    }
    
    private func decodeLiteralHeader(from buffer: inout ByteBuffer, headerIndex: Int,
                                     addToIndex: Bool = true) throws -> (String, String) {
        if headerIndex != 0 {
            guard let (h, _) = self.headerTable.header(at: headerIndex) else {
                throw Error.invalidIndexedHeader(headerIndex)
            }
            
            let value = try self.readEncodedString(from: &buffer)
            
            // This type gets written into the dynamic table.
            if addToIndex {
                guard self.headerTable.append(headerNamed: h, value: value) else {
                    throw Error.failedToAddIndexedHeader(h, value)
                }
            }
            
            return (h, value)
        } else {
            let header = try self.readEncodedString(from: &buffer)
            let value = try self.readEncodedString(from: &buffer)
            
            if addToIndex {
                guard headerTable.append(headerNamed: header, value: value) else {
                    throw Error.failedToAddIndexedHeader(header, value)
                }
            }
            
            return (header, value)
        }
    }
    
    private func readEncodedString(from buffer: inout ByteBuffer) throws -> String {
        // peek to read the encoding bit
        let initialByte: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        let huffmanEncoded = initialByte & 0x80 == 0x80
        
        // read the length; there's a seven-bit prefix here (one-bit encoding flag)
        let len = try Int(buffer.readEncodedInteger(withPrefix: 7))
        
        if huffmanEncoded {
            guard var slice = buffer.readSlice(length: len) else {
                throw Error.indexOutOfRange(len, buffer.readableBytes)
            }
            return try self.readHuffmanString(from: &slice)
        } else {
            guard let result = buffer.readString(length: len) else {
                throw Error.indexOutOfRange(len, buffer.readableBytes)
            }
            return result
        }
    }
    
    private func readHuffmanString(from buffer: inout ByteBuffer) throws -> String {
        return try self.huffmanDecoder.decodeString(from: &buffer)
    }
}
