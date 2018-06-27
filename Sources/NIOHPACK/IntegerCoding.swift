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

/// Determines the number of bytes needed to encode a given integer.
func encodedLength<T : UnsignedInteger>(of value: T, prefix: Int) -> Int {
    precondition(prefix <= 8)
    precondition(prefix >= 0)
    
    let k = (1 << prefix) - 1
    if value < k {
        return 1
    }
    
    var len = 1
    var n = value - T(k)
    
    while n >= 128 {
        n >>= 7
        len += 1
    }
    
    return len + 1
}

/// Encodes an integer value into a provided memory location.
///
/// - Parameters:
///   - value: The integer value to encode.
///   - buffer: The location at which to begin encoding.
///   - prefix: The number of bits available for use in the first byte at `buffer`.
///   - prefixBits: Existing bits to place in that first byte of `buffer` before encoding `value`.
/// - Returns: Returns the number of bytes used to encode the integer.
@discardableResult
func encodeInteger<T : UnsignedInteger>(_ value: T, to buffer: UnsafeMutableRawPointer,
                                        prefix: Int, prefixBits: UInt8 = 0) -> Int {
    precondition(prefix <= 8)
    precondition(prefix >= 1)
    
    let k = (1 << prefix) - 1
    var buf = buffer.assumingMemoryBound(to: UInt8.self)
    let start = buf
    start.pointee = prefixBits
    
    if value < k {
        // it fits already!
        buf.pointee |= UInt8(truncatingIfNeeded: value)
        return 1
    }
    
    // if it won't fit in this byte altogether, fill in all the remaining bits and move
    // to the next byte.
    buf.pointee |= UInt8(truncatingIfNeeded: k)
    buf += 1
    
    // deduct the initial [prefix] bits from the value, then encode it seven bits at a time into
    // the remaining bytes.
    var n = value - T(k)
    while n >= 128 {
        buf.pointee = (1 << 7) | UInt8(n & 0x7f)
        buf += 1
        n >>= 7
    }
    
    buf.pointee = UInt8(n)
    buf += 1
    
    return start.distance(to: buf)
}

enum IntegerDecodeError : Error
{
    case insufficientInput
}

func decodeInteger(from buffer: UnsafeRawBufferPointer, prefix: Int, initial: UInt = 0) throws -> (UInt, Int) {
    precondition(prefix <= 8)
    precondition(prefix >= 0)
    
    let k = (1 << prefix) - 1
    var n = initial
    let bytes = buffer.bindMemory(to: UInt8.self)
    var buf = bytes.baseAddress!
    let end = buf + buffer.count
    
    if n == 0 {
        // if the available bits aren't all set, the entire value consists of those bits
        if buf.pointee & UInt8(k) != k {
            return (UInt(buf.pointee & UInt8(k)), 1)
        }
        
        n = UInt(k)
        buf += 1
        if buf == end {
            return (n, buffer.baseAddress!.distance(to: buf))
        }
    }
    
    // for the remaining bytes, as long as the top bit is set, consume the low seven bits.
    var m: UInt = 0
    var b: UInt8 = 0
    repeat {
        if buf == end {
            throw IntegerDecodeError.insufficientInput
        }
        
        b = buf.pointee
        n += UInt(b & 127) * (1 << m)
        m += 7
        buf += 1
    } while b & 128 == 128
    
    return (n, bytes.baseAddress!.distance(to: buf))
}

extension ByteBuffer {
    mutating func readEncodedInteger(withPrefix prefix: Int = 0, initial: UInt = 0) throws -> UInt {
        return try self.readWithUnsafeReadableBytes { ptr -> (Int, UInt) in
            let (result, nread) = try decodeInteger(from: ptr, prefix: prefix, initial: initial)
            return (nread, result)
        }
    }
    
    mutating func write<T : UnsignedInteger>(encodedInteger value: T, prefix: Int = 0, prefixBits: UInt8 = 0) {
        let len = encodedLength(of: value, prefix: prefix)
        if self.writableBytes < len {
            // realloc so we have enough room
            self.changeCapacity(to: self.writerIndex + len)
        }
        self.writeWithUnsafeMutableBytes {
            encodeInteger(value, to: $0.baseAddress!, prefix: prefix, prefixBits: prefixBits)
        }
    }
}
