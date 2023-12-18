//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/* private but tests */
/// Encodes an integer value into a provided memory location.
///
/// - Parameters:
///   - value: The integer value to encode.
///   - buffer: The location at which to begin encoding.
///   - prefix: The number of bits available for use in the first byte at `buffer`.
///   - prefixBits: Existing bits to place in that first byte of `buffer` before encoding `value`.
/// - Returns: Returns the number of bytes used to encode the integer.
@discardableResult
func encodeInteger(_ value: UInt64, to buffer: inout ByteBuffer,
                   prefix: Int, prefixBits: UInt8 = 0) -> Int {
    assert(prefix <= 8)
    assert(prefix >= 1)

    let start = buffer.writerIndex

    // The prefix is always hard-coded, and must fit within 8, so unchecked math here is definitely safe.
    let k = (1 &<< prefix) &- 1
    var initialByte = prefixBits

    if value < k {
        // it fits already!
        initialByte |= UInt8(truncatingIfNeeded: value)
        buffer.writeInteger(initialByte)
        return 1
    }

    // if it won't fit in this byte altogether, fill in all the remaining bits and move
    // to the next byte.
    initialByte |= UInt8(truncatingIfNeeded: k)
    buffer.writeInteger(initialByte)

    // deduct the initial [prefix] bits from the value, then encode it seven bits at a time into
    // the remaining bytes.
    // We can safely use unchecked subtraction here: we know that `k` is zero or greater, and that `value` is
    // either the same value or greater. As a result, this can be unchecked: it's always safe.
    var n = value &- UInt64(k)
    while n >= 128 {
        let nextByte = (1 << 7) | UInt8(truncatingIfNeeded: n & 0x7f)
        buffer.writeInteger(nextByte)
        n >>= 7
    }

    buffer.writeInteger(UInt8(truncatingIfNeeded: n))
    return buffer.writerIndex &- start
}

fileprivate let valueMask: UInt8 = 127
fileprivate let continuationMask: UInt8 = 128

/* private but tests */
struct DecodedInteger {
    var value: Int
    var bytesRead: Int
}

/* private but tests */
func decodeInteger(from bytes: ByteBufferView, prefix: Int) throws -> DecodedInteger {
    precondition((1...8).contains(prefix))
    if bytes.isEmpty {
        throw NIOHPACKErrors.InsufficientInput()
    }

    // See RFC 7541 § 5.1 for details of the encoding/decoding.

    var index = bytes.startIndex
    // The shifting and arithmetic operate on 'Int' and prefix is 1...8, so these unchecked operations are
    // fine and the result must fit in a UInt8.
    let prefixMask = UInt8(truncatingIfNeeded: (1 &<< prefix) &- 1)
    let prefixBits = bytes[index] & prefixMask

    if prefixBits != prefixMask {
        // The prefix bits aren't all '1', so they represent the whole value, we're done.
        return DecodedInteger(value: Int(prefixBits), bytesRead: 1)
    }

    var accumulator = Int(prefixMask)
    bytes.formIndex(after: &index)

    // for the remaining bytes, as long as the top bit is set, consume the low seven bits.
    var shift: Int = 0
    var byte: UInt8 = 0

    repeat {
        if index == bytes.endIndex {
            throw NIOHPACKErrors.InsufficientInput()
        }

        byte = bytes[index]

        let value = Int(byte & valueMask)

        // The shift cannot overflow: the value of 'shift' is strictly less than 'Int.bitWidth'.
        let (multiplicationResult, multiplicationOverflowed) = value.multipliedReportingOverflow(by: (1 &<< shift))
        if multiplicationOverflowed {
            throw NIOHPACKErrors.UnrepresentableInteger()
        }

        let (additionResult, additionOverflowed) = accumulator.addingReportingOverflow(multiplicationResult)
        if additionOverflowed {
            throw NIOHPACKErrors.UnrepresentableInteger()
        }

        accumulator = additionResult

        // Unchecked is fine, there's no chance of it overflowing given the possible values of 'Int.bitWidth'.
        shift &+= 7
        if shift >= Int.bitWidth {
            throw NIOHPACKErrors.UnrepresentableInteger()
        }

        bytes.formIndex(after: &index)
    } while byte & continuationMask == continuationMask

    return DecodedInteger(value: accumulator, bytesRead: bytes.distance(from: bytes.startIndex, to: index))
}

extension ByteBuffer {
    mutating func readEncodedInteger(withPrefix prefix: Int) throws -> Int {
        let result = try decodeInteger(from: self.readableBytesView, prefix: prefix)
        self.moveReaderIndex(forwardBy: result.bytesRead)
        return result.value
    }

    mutating func write(encodedInteger value: UInt64, prefix: Int = 0, prefixBits: UInt8 = 0) {
        encodeInteger(value, to: &self, prefix: prefix, prefixBits: prefixBits)
    }
}
