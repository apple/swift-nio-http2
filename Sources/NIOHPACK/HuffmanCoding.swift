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
public struct HuffmanEncoder {
    private static let initialBufferCount = 256
    
    private struct _EncoderState {
        var offset = 0
        var remainingBits = 8
        let buffer: UnsafeMutableRawBufferPointer
        
        init(bytes: UnsafeMutableRawBufferPointer) {
            self.buffer = bytes
        }
    }
    
    /// Returns the number of *bits* required to encode a given string.
    private func encodedBitLength<C : Collection>(of bytes: C) -> Int where C.Element == UInt8 {
        let clen = bytes.reduce(0) { $0 + StaticHuffmanTable[Int($1)].nbits }
        // round up to nearest multiple of 8 for EOS prefix
        return (clen + 7) & ~7
    }
    
    /// Returns the number of bytes required to encode a given string.
    func encodedLength<C : Collection>(of bytes: C) -> Int where C.Element == UInt8 {
        return self.encodedBitLength(of: bytes) / 8
    }
    
    /// Encodes the given string to the encoder's internal buffer.
    ///
    /// - Parameter string: The string data to encode.
    /// - Returns: The number of bytes used while encoding the string.
    @discardableResult
    public mutating func encode<C : Collection>(_ stringBytes: C, toBuffer target: inout ByteBuffer) -> Int where C.Element == UInt8 {
        let clen = encodedBitLength(of: stringBytes)
        ensureBitsAvailable(clen, &target)
        
        return target.writeWithUnsafeMutableBytes { buf in
            var state = _EncoderState(bytes: buf)
            
            for ch in stringBytes {
                appendSym_fast(StaticHuffmanTable[Int(ch)], &state)
            }
            
            if state.remainingBits > 0 && state.remainingBits < 8 {
                // set all remaining bits of the last byte to 1
                buf[state.offset] |= UInt8(1 << state.remainingBits) - 1
                state.offset += 1
                state.remainingBits = (state.offset == buf.count ? 0 : 8)
            }
            
            return state.offset
        }
    }
    
    private mutating func appendSym_fast(_ sym: HuffmanTableEntry, _ state: inout _EncoderState) {
        // will it fit as-is?
        if sym.nbits == state.remainingBits {
            state.buffer[state.offset] |= UInt8(sym.bits)
            state.offset += 1
            state.remainingBits = state.offset == state.buffer.count ? 0 : 8
        } else if sym.nbits < state.remainingBits {
            let diff = state.remainingBits - sym.nbits
            state.buffer[state.offset] |= UInt8(sym.bits << diff)
            state.remainingBits -= sym.nbits
        } else {
            var (code, nbits) = sym
            
            nbits -= state.remainingBits
            state.buffer[state.offset] |= UInt8(code >> nbits)
            state.offset += 1
            
            if nbits & 0x7 != 0 {
                // align code to MSB
                code <<= 8 - (nbits & 0x7)
            }
            
            // we can short-circuit if less than 8 bits are remaining
            if nbits < 8 {
                state.buffer[state.offset] = UInt8(truncatingIfNeeded: code)
                state.remainingBits = 8 - nbits
                return
            }
            
            // longer path for larger amounts
            if nbits > 24 {
                state.buffer[state.offset] = UInt8(truncatingIfNeeded: code >> 24)
                nbits -= 8
                state.offset += 1
            }
            
            if nbits > 16 {
                state.buffer[state.offset] = UInt8(truncatingIfNeeded: code >> 16)
                nbits -= 8
                state.offset += 1
            }
            
            if nbits > 8 {
                state.buffer[state.offset] = UInt8(truncatingIfNeeded: code >> 8)
                nbits -= 8
                state.offset += 1
            }
            
            if nbits == 8 {
                state.buffer[state.offset] = UInt8(truncatingIfNeeded: code)
                state.offset += 1
                state.remainingBits = state.offset == state.buffer.count ? 0 : 8
            } else {
                state.remainingBits = 8 - nbits
                state.buffer[state.offset] = UInt8(truncatingIfNeeded: code)
            }
        }
    }
    
    private mutating func ensureBitsAvailable(_ bits: Int, _ buffer: inout ByteBuffer) {
        let bytesNeeded = bits / 8
        if bytesNeeded <= buffer.writableBytes {
            // just zero the requested number of bytes before we start OR-ing in our values
            buffer.withUnsafeMutableWritableBytes { ptr in
                ptr.baseAddress!.assumingMemoryBound(to: UInt8.self).assign(repeating: 0, count: bytesNeeded)
            }
            return
        }
        
        // one extra byte to ensure we have space to fill at the end of the encoded string, if we need it
        let neededToAdd = bytesNeeded - buffer.writableBytes
        let newLength = buffer.capacity + neededToAdd
        
        // reallocate the buffer to ensure we have the room we need
        buffer.changeCapacity(to: newLength)
        
        // now zero all writable bytes that we expect to use
        buffer.withUnsafeMutableWritableBytes { ptr in
            ptr.baseAddress!.assumingMemoryBound(to: UInt8.self).assign(repeating: 0, count: bytesNeeded)
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
public struct HuffmanDecoder {
    /// The decoder table. This structure doesn't actually take up any space, I think?
    let decoderTable = HuffmanDecoderTable()
    
    /// Initializes a new Huffman decoder.
    public init() {}
    
    /// Decodes a single string from a view into a `ByteBuffer`.
    ///
    /// - Parameter input: A `ByteBufferView` over the entire set of bytes
    ///                     that comprise the encoded string.
    /// - Parameter output: A `ByteBuffer` into which decoded UTF-8 octets will be
    ///                     written.
    /// - Returns: The number of UTF-8 characters written into the output `ByteBuffer`.
    /// - Throws: HuffmanDecoderError if the data could not be decoded.
    @discardableResult
    public func decodeString(from input: ByteBufferView, into output: inout ByteBuffer) throws -> Int {
        if input.count == 0 {
            return 0
        }
        
        var state: UInt8 = 0
        var acceptable = false
        
        // we write to an intermediate contiguous array, because write(integer:) goes through
        // all sorts even when writing individual bytes.
        var buf: ContiguousArray<UInt8> = []
        buf.reserveCapacity(max(128, input.count.nextPowerOf2()))
        
        for ch in input {
            var t = decoderTable[state: state, nybble: ch >> 4]
            if t.flags.contains(.failure) {
                throw HuffmanDecoderError.invalidState
            }
            if t.flags.contains(.symbol) {
                buf.append(t.sym)
            }
            
            t = decoderTable[state: t.state, nybble: ch & 0xf]
            if t.flags.contains(.failure) {
                throw HuffmanDecoderError.invalidState
            }
            if t.flags.contains(.symbol) {
                buf.append(t.sym)
            }
            
            state = t.state
            acceptable = t.flags.contains(.accepted)
        }
        
        guard acceptable else {
            throw HuffmanDecoderError.invalidState
        }
        
        return output.write(bytes: buf)
    }
}
