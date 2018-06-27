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

/// Implements a HPACK-conformant Huffman encoder. Note that this class is *not* thread safe.
/// The intended use is to be within a single HTTP2StreamChannel or similar, on a single EventLoop.
public class HuffmanEncoder {
    private static let initialBufferCount = 256
    
    private var allocator: ByteBufferAllocator
    private var buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: HuffmanEncoder.initialBufferCount)
    private var offset = 0
    private var remainingBits = 8
    
    /// Obtains a buffer containing the encoder's current output.
    public var data: ByteBuffer {
        var buffer = self.allocator.buffer(capacity: self.count)
        buffer.write(bytes: self.buffer[..<self.count])
        return buffer
    }
    
    /// The number of bytes required to hold the encoder's output.
    public var count: Int {
        return self.offset + (self.remainingBits == 0 || self.remainingBits == 8 ? 0 : 1)
    }
    
    /// Creates a new HPACK-compliant Huffman decoder.
    ///
    /// - Parameter allocator: An allocator used to create `ByteBuffer`s.
    public init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }
    
    /// Resets the encoder to its starting state, ready to begin encoding new values.
    public func reset() {
        // zero the bytes of the buffer, since all our write operations are bitwise ORs.
        buffer.assign(repeating: 0)
        offset = 0
        remainingBits = 8
    }
    
    /// Returns the number of *bits* required to encode a given string.
    private func encodedBitLength(of string: String) -> Int {
        let clen = string.utf8.reduce(0) { $0 + StaticHuffmanTable[Int($1)].nbits }
        // round up to nearest multiple of 8 for EOS prefix
        return (clen + 7) & ~7
    }
    
    /// Encodes the given string to the encoder's internal buffer.
    ///
    /// - Parameter string: The string data to encode.
    /// - Returns: The number of bytes used while encoding the string.
    public func encode(_ string: String) -> Int {
        let clen = encodedBitLength(of: string)
        ensureBitsAvailable(clen)
        let startCount = self.count
        
        for ch in string.utf8 {
            appendSym_fast(StaticHuffmanTable[Int(ch)])
        }
        
        if remainingBits > 0 && remainingBits < 8 {
            // set all remaining bits of the last byte to 1
            buffer[offset] |= UInt8(1 << remainingBits) - 1
            offset += 1
            remainingBits = (offset == buffer.count ? 0 : 8)
        }
        
        return self.count - startCount
    }
    
    private func appendSym(_ sym: HuffmanTableEntry) {
        ensureBitsAvailable(sym.nbits)
        appendSym_fast(sym)
    }
    
    private func appendSym_fast(_ sym: HuffmanTableEntry) {
        // will it fit as-is?
        if sym.nbits == self.remainingBits {
            self.buffer[self.offset] |= UInt8(sym.bits)
            self.offset += 1
            self.remainingBits = self.offset == self.buffer.count ? 0 : 8
        } else if sym.nbits < self.remainingBits {
            let diff = self.remainingBits - sym.nbits
            self.buffer[self.offset] |= UInt8(sym.bits << diff)
            self.remainingBits -= sym.nbits
        } else {
            var (code, nbits) = sym
            
            nbits -= self.remainingBits
            self.buffer[self.offset] |= UInt8(code >> nbits)
            self.offset += 1
            
            if nbits & 0x7 != 0 {
                // align code to MSB
                code <<= 8 - (nbits & 0x7)
            }
            
            // we can short-circuit if less than 8 bits are remaining
            if nbits < 8 {
                self.buffer[self.offset] = UInt8(truncatingIfNeeded: code)
                self.remainingBits = 8 - nbits
                return
            }
            
            // longer path for larger amounts
            if nbits > 24 {
                self.buffer[self.offset] = UInt8(truncatingIfNeeded: code >> 24)
                nbits -= 8
                self.offset += 1
            }
            
            if nbits > 16 {
                self.buffer[self.offset] = UInt8(truncatingIfNeeded: code >> 16)
                nbits -= 8
                self.offset += 1
            }
            
            if nbits > 8 {
                self.buffer[self.offset] = UInt8(truncatingIfNeeded: code >> 8)
                nbits -= 8
                self.offset += 1
            }
            
            if nbits == 8 {
                self.buffer[self.offset] = UInt8(truncatingIfNeeded: code)
                self.offset += 1
                self.remainingBits = self.offset == buffer.count ? 0 : 8
            } else {
                self.remainingBits = 8 - nbits
                self.buffer[self.offset] = UInt8(truncatingIfNeeded: code)
            }
        }
    }
    
    private func ensureBitsAvailable(_ bits: Int) {
        let bitsLeft = ((self.buffer.count - self.offset) * 8) + self.remainingBits
        if bitsLeft >= bits {
            return
        }
        
        // We need more space. Deduct our remaining unused bits from the amount we're looking
        // for to get a byte-rounded value.
        let nbits = bits - remainingBits
        let bytesNeeded: Int
        if (nbits & 0x7) != 0 {
            // trim to byte length and add one more
            bytesNeeded = (nbits & ~0x7) + 8
        } else {
            // just trim to byte length
            bytesNeeded = (nbits & ~0x7)
        }
        
        let bytesAvailable = (self.buffer.count - self.offset) - (self.remainingBits == 0 ? 0 : 1)
        let neededToAdd = bytesNeeded - bytesAvailable
        
        // find a nice multiple of 128 bytes
        let newLength = (self.buffer.count + neededToAdd + 127) & ~127
        
        let newBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: newLength, alignment: 1)
        newBuf.copyMemory(from: UnsafeRawBufferPointer(self.buffer))
        self.buffer = newBuf.bindMemory(to: UInt8.self)
        
        if self.remainingBits == 0 {
            self.remainingBits = 8
            if self.offset != 0 {
                self.offset += 1
            }
        }
    }
}

/// Errors that may be encountered by the Huffman decoder.
public enum HuffmanDecoderError : Error
{
    /// The decoder entered an invalid state. Usually this means invalid input.
    case invalidState
    /// The output data could not be validated as UTF-8.
    case decodeFailed
}

/// A `HuffmanDecoder` is an idempotent class that performs string decoding using
/// a static table of values. It maintains no internal state, so is thread-safe.
public class HuffmanDecoder {
    /// Initializes a new Huffman decoder.
    public init() {}
    
    /// Decodes a single string from a given buffer.
    ///
    /// - Parameter buffer: A `ByteBuffer` containing the entire set of bytes
    ///                     that comprise the encoded string.
    /// - Returns: The decoded string value.
    /// - Throws: HuffmanDecoderError if the data could not be decoded.
    public func decodeString(from buffer: inout ByteBuffer) throws -> String {
        return try buffer.readWithUnsafeReadableBytes { ptr -> (Int, String) in
            let str = try decodeString(from: ptr.baseAddress!, count: ptr.count)
            return (ptr.count, str)
        }
    }
    
    /// Decodes a string from a raw byte pointer. Used by ByteBuffer and friends.
    ///
    /// Per the nghttp2 implementation, this uses the decoding algorithm & tables described at
    /// http://graphics.ics.uci.edu/pub/Prefix.pdf (which is apparently no longer available, sigh).
    ///
    /// - Parameters:
    ///   - bytes: Raw octets of the encoded string.
    ///   - count: The number of whole octets comprising the encoded string.
    /// - Returns: The decoded string value.
    /// - Throws: HuffmanDecoderError if the decode failed or produced invalid data.
    public func decodeString(from bytes: UnsafeRawPointer, count: Int) throws -> String {
        var state = 0
        var acceptable = false
        var decoded = [UInt8]()
        decoded.reserveCapacity(256)
        
        let input = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: count)
        
        for ch in input {
            var t = HuffmanDecoderTable[state][Int(ch >> 4)]
            if t.flags.contains(.failure) {
                throw HuffmanDecoderError.invalidState
            }
            if t.flags.contains(.symbol) {
                decoded.append(t.sym)
            }
            
            t = HuffmanDecoderTable[Int(t.state)][Int(ch) & 0xf]
            if t.flags.contains(.failure) {
                throw HuffmanDecoderError.invalidState
            }
            if t.flags.contains(.symbol) {
                decoded.append(t.sym)
            }
            
            state = Int(t.state)
            acceptable = t.flags.contains(.accepted)
        }
        
        guard acceptable else {
            throw HuffmanDecoderError.invalidState
        }
        
        return decoded.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    }
}
