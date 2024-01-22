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

import XCTest
import NIOCore
@testable import NIOHPACK

class IntegerCodingTests : XCTestCase {
    
    var scratchBuffer = ByteBufferAllocator().buffer(capacity: 11)
    
    // MARK: - Array-based helpers
    
    private func encodeIntegerToArray(_ value: UInt64, prefix: Int) -> [UInt8] {
        var data = [UInt8]()
        scratchBuffer.clear()
        let len = NIOHPACK.encodeInteger(value, to: &scratchBuffer, prefix: prefix)
        data.append(contentsOf: scratchBuffer.viewBytes(at: 0, length: len)!)
        return data
    }
    
    private func decodeInteger(from array: [UInt8], prefix: Int) throws -> Int {
        scratchBuffer.clear()
        scratchBuffer.writeBytes(array)
        let result = try NIOHPACK.decodeInteger(from: scratchBuffer.readableBytesView, prefix: prefix)
        return result.value
    }
    
    // MARK: - Tests
    
    func testIntegerEncoding() {
        // values from the standard: http://httpwg.org/specs/rfc7541.html#integer.representation.examples
        var data = encodeIntegerToArray(10, prefix: 5)  // 0000 1010
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(data[0], 0b00001010)
        
        data = encodeIntegerToArray(1337, prefix: 5)    // 0000 0101 0011 1001
        XCTAssertEqual(data.count, 3)
        
        // prefix bits = 31 = 0001 1111, 1337 - 31 = 1306 = 0101 0001 1010 -> x0001010 x0011010
        XCTAssertEqual(data, [31, 154, 10])             // 00011111 , 10011010 , 00001010
        
        // prefix 8 == use the whole first octet
        data = encodeIntegerToArray(42, prefix: 8)      // 0010 1010
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(data[0], 42)
        
        data = encodeIntegerToArray(256, prefix: 8)     // 0001 0000 0000 -> 1111 1111 + 0000 0001
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data, [255, 1])
        
        // very large value, few bits set, 8-bit prefix
        data = encodeIntegerToArray(17 << 57, prefix: 8) // 00010001 << 57 or 2449958197289549824
        
        // calculations:
        //  subtract prefix:
        //      2449958197289549824 - 255 = 2449958197289549569 or 0010 0001 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 0000 0001
        //  seven bits at a time, grouping from least significant bit:
        //      0100001 1111111 1111111 1111111 1111111 1111111 1111111 1111110 0000001
        //  swap these around:
        //      0000001 1111110 1111111 1111111 1111111 1111111 1111111 1111111 0100001
        //  set the top bit of all but last part to get our remaining output bytes:
        //      10000001 11111110 11111111 11111111 11111111 11111111 11111111 11111111 00100001
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(data, [255, 129, 254, 255, 255, 255, 255, 255, 255, 33])
        
        // same value, 1-bit prefix:
        data = encodeIntegerToArray(17 << 57, prefix: 1)
        
        // calculations:
        //  subtract prefix:
        //      2449958197289549824 - 1 = 2449958197289549823 or 0010 0001 (1111 x14)
        //  seven bits at a time, grouping from least significant bit:
        //      0100001 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111
        //  swap these around:
        //      1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111 0100001
        //  set the top bit of all but last part to get our remaining output bytes:
        //      11111111 11111111 11111111 11111111 11111111 11111111 11111111 11111111 00100001
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(data, [1, 255, 255, 255, 255, 255, 255, 255, 255, 33])
        
        // encoding max 64-bit unsigned integer, 1-bit prefix
        data = encodeIntegerToArray(UInt64.max, prefix: 1)
        
        // calculations:
        //  subtract prefix:
        //      18446744073709551615 - 1 = 18446744073709551614 or (1111 x15) 1110
        //  seven bits at a time, grouping from least significant bit:
        //      0000001 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111110
        //  swap these around:
        //      1111110 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111 0000001
        //  set the top bit of all but last part to get our remaining output bytes:
        //      11111110 11111111 11111111 11111111 11111111 11111111 11111111 11111111 11111111 00000001
        XCTAssertEqual(data.count, 11)
        XCTAssertEqual(data, [1, 254, 255, 255, 255, 255, 255, 255, 255, 255, 1])
        
        // something carefully crafted to produce maximum number of output bytes with minimum number of
        // nonzero bits:
        data = encodeIntegerToArray(9223372036854775809, prefix: 1)

        // calculations:
        //  subtract prefix:
        //      9223372036854775809 - 1 = 9223372036854775808 or 1000 (0000 x15)
        //  seven bits at a time, grouping from least significant bit:
        //      (000000)1 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000
        //  swap these around:
        //      0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000001
        //  set the top bit of all but the last part to get our remaining output bytes:
        //      10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 00000001
        XCTAssertEqual(data.count, 11)
        XCTAssertEqual(data, [1, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1])
        
        // something similar, which uses an 8-bit prefix and still produces lots of zero bits:
        // for those interested: this is the previous value + 254; thus only the first byte should differ
        data = encodeIntegerToArray(9223372036854776063, prefix: 8)
        
        // calculations:
        //  subtract prefix:
        //      9223372036854776063 - 255 = 9223372036854775808 or 1000 (0000 x15)
        //  seven bits at a time, grouping from least significant bit:
        //      (000000)1 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000
        //  swap these around:
        //      0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000001
        //  set the top bit of all but the last part to get our remaining output bytes:
        //      10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 00000001
        XCTAssertEqual(data.count, 11)
        XCTAssertEqual(data, [255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1])
    }
    
    func testIntegerDecoding() throws {
        // any bits above the prefix amount shouldn't affect the outcome.
        XCTAssertEqual(try decodeInteger(from: [0b00001010], prefix: 5), 10)
        XCTAssertEqual(try decodeInteger(from: [0b11101010], prefix: 5), 10)
        
        XCTAssertEqual(try decodeInteger(from: [0b00011111, 154, 10], prefix: 5), 1337)
        XCTAssertEqual(try decodeInteger(from: [0b11111111, 154, 10], prefix: 5), 1337)

        XCTAssertEqual(try decodeInteger(from: [0b00101010], prefix: 8), 42)

        // Now some larger numbers:
        #if !os(watchOS)
        XCTAssertEqual(try decodeInteger(from: [255, 129, 254, 255, 255, 255, 255, 255, 255, 33], prefix: 8), 2449958197289549824)
        XCTAssertEqual(try decodeInteger(from: [1, 255, 255, 255, 255, 255, 255, 255, 255, 33], prefix: 1), 2449958197289549824)
        XCTAssertEqual(try decodeInteger(from: [1, 254, 255, 255, 255, 255, 255, 255, 255, 127, 1], prefix: 1), Int.max)

        // lots of zeroes: each 128 yields zero
        XCTAssertEqual(try decodeInteger(from: [1, 128, 128, 128, 128, 128, 128, 128, 128, 127, 1], prefix: 1), 9151314442816847873)

        // almost the same bytes, but a different prefix:
        XCTAssertEqual(try decodeInteger(from: [255, 128, 128, 128, 128, 128, 128, 128, 128, 127, 1], prefix: 8), 9151314442816848127)
        #endif

        // now a silly version which should never have been encoded in so many bytes
        XCTAssertEqual(try decodeInteger(from: [255, 129, 128, 128, 128, 128, 128, 128, 128, 0], prefix: 8), 256)
    }

    func testIntegerDecodingMultiplicationDoesNotOverflow() throws {
        // Zeros with continuation bits (e.g. 128) to increase the shift value (to 9 * 7 = 63), and then multiply by 127.
        for `prefix` in 1...8 {
            XCTAssertThrowsError(try decodeInteger(from: [255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 127], prefix: prefix)) { error in
                XCTAssert(error is NIOHPACKErrors.UnrepresentableInteger)
            }
        }
    }

    func testIntegerDecodingAdditionDoesNotOverflow() throws {
        // Zeros with continuation bits (e.g. 128) to increase the shift value (to 9 * 7 = 63), and then multiply by 127.
        for `prefix` in 1...8 {
            XCTAssertThrowsError(try decodeInteger(from: [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 127], prefix: prefix)) { error in
                XCTAssert(error is NIOHPACKErrors.UnrepresentableInteger)
            }
        }
    }

    func testIntegerDecodingShiftDoesNotOverflow() throws {
        // With enough iterations we expect the shift to become greater >= 64.
        for `prefix` in 1...8 {
            XCTAssertThrowsError(try decodeInteger(from: [255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128], prefix: prefix)) { error in
                XCTAssert(error is NIOHPACKErrors.UnrepresentableInteger)
            }
        }
    }

    func testIntegerDecodingEmptyInput() throws {
        for `prefix` in 1...8 {
            XCTAssertThrowsError(try decodeInteger(from: [], prefix: prefix)) { error in
                XCTAssert(error is NIOHPACKErrors.InsufficientInput)
            }
        }
    }

    func testIntegerDecodingNotEnoughBytes() throws {
        for `prefix` in 1...8 {
            XCTAssertThrowsError(try decodeInteger(from: [255, 128], prefix: prefix)) { error in
                XCTAssert(error is NIOHPACKErrors.InsufficientInput)
            }
        }
    }
}
