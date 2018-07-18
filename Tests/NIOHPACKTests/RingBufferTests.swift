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

import XCTest
import NIO
@testable import NIOHPACK

class RingBufferTests : XCTestCase {
    var ring: SimpleRingBuffer = SimpleRingBuffer(allocator: ByteBufferAllocator(), capacity: 32)
    
    override func setUp() {
        ring.clear()
    }
    
    private func assertRingState(_ head: Int, _ tail: Int, _ readable: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(ring.ringHead, head, file: file, line: line)
        XCTAssertEqual(ring.ringTail, tail, file: file, line: line)
        XCTAssertEqual(ring.readableBytes, readable, file: file, line: line)
    }
    
    func testReadAndWriteBytes() throws {
        assertRingState(0, 0, 0)
        
        let bytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        try ring.write(bytes: bytes)
        assertRingState(0, 10, 10)
        
        ring.unwrite(byteCount: 5)
        assertRingState(0, 5, 5)
        
        let peekedBytes = ring.peekBytes(length: 5)
        XCTAssertNotNil(peekedBytes)
        XCTAssertEqual(peekedBytes!.count, 5)
        assertRingState(0, 5, 5)
        
        let readBytes = ring.readBytes(length: 5)
        XCTAssertNotNil(readBytes)
        XCTAssertEqual(readBytes!.count, 5)
        assertRingState(5, 5, 0)
        
        ring.unread(byteCount: 5)
        assertRingState(0, 5, 5)
        
        XCTAssertEqual(ring.readBytes(length: 5), readBytes)
        assertRingState(5, 5, 0)
    }
    
    func testReadAndWriteStrings() throws {
        // Plain strings (Sequence path)
        
        let string = "This is a test string"
        try ring.write(string: string)
        assertRingState(0, 21, 21)
        
        ring.unwrite(byteCount: 7)      // " string"
        assertRingState(0, 14, 14)      // "This is a test"
        
        let peekedString = ring.peekString(length: 7)     // "This is"
        XCTAssertNotNil(peekedString)
        XCTAssertEqual(peekedString, "This is")
        assertRingState(0, 14, 14)
        
        let readString = ring.readString(length: 14)    // "This is a test"
        XCTAssertNotNil(readString)
        XCTAssertEqual(readString, "This is a test")
        assertRingState(14, 14, 0)
        
        ring.unread(byteCount: 4)       // un-read "test"
        assertRingState(10, 14, 4)
        
        XCTAssertEqual(ring.readString(length: 4), "test")
        assertRingState(14, 14, 0)
        
        ring.unread(byteCount: 14)
        ring.unwrite(byteCount: 14)
        assertRingState(0, 0, 0)
        
        // Static strings (ContiguousCollection path)
        
        try ring.write(staticString: "This is a test string")
        assertRingState(0, 21, 21)
        
        ring.unwrite(byteCount: 7)      // " string"
        assertRingState(0, 14, 14)      // "This is a test"
        
        let peekedStaticString = ring.peekString(length: 7)     // "This is"
        XCTAssertNotNil(peekedStaticString)
        XCTAssertEqual(peekedString, "This is")
        assertRingState(0, 14, 14)
        
        let readStaticString = ring.readString(length: 14)    // "This is a test"
        XCTAssertNotNil(readStaticString)
        XCTAssertEqual(readStaticString, "This is a test")
        assertRingState(14, 14, 0)
        
        ring.unread(byteCount: 4)       // un-read "test"
        assertRingState(10, 14, 4)
        
        XCTAssertEqual(ring.readString(length: 4), "test")
        assertRingState(14, 14, 0)
    }
    
    func testWrappingBoundary() throws {
        ring.moveTail(forwardBy: 28)
        ring.moveHead(forwardBy: 28)
        assertRingState(28, 28, 0)
        
        // write eight bytes -- should split right down the middle
        let bytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        try ring.write(bytes: bytes)
        assertRingState(28, 4, 8)
        
        let readBytes = ring.readBytes(length: 8)
        XCTAssertEqual(readBytes, bytes)
        assertRingState(4, 4, 0)
        
        ring.unread(byteCount: 8)
        assertRingState(28, 4, 8)
        
        let peeked = ring.peekBytes(length: 8)
        XCTAssertEqual(peeked, bytes)
        assertRingState(28, 4, 8)
        
        let readHalf = ring.readBytes(length: 4)
        XCTAssertNotNil(readHalf)
        XCTAssertEqual(readHalf!.count, 4)
        assertRingState(0, 4, 4)
        
        ring.unread(byteCount: 4)
        assertRingState(28, 4, 8)
        
        ring.unwrite(byteCount: 8)
        assertRingState(28, 28, 0)
        
        // string data, same as before
        let string = "This is a test string"
        try ring.write(string: string)
        assertRingState(28, 17, 21)
        
        ring.unwrite(byteCount: 7)      // " string"
        assertRingState(28, 10, 14)      // "This is a test"
        
        let peekedString = ring.peekString(length: 7)     // "This is"
        XCTAssertNotNil(peekedString)
        XCTAssertEqual(peekedString, "This is")
        assertRingState(28, 10, 14)
        
        let readString = ring.readString(length: 14)    // "This is a test"
        XCTAssertNotNil(readString)
        XCTAssertEqual(readString, "This is a test")
        assertRingState(10, 10, 0)
        
        ring.unread(byteCount: 4)       // un-read "test"
        assertRingState(6, 10, 4)
        
        XCTAssertEqual(ring.readString(length: 4), "test")
        assertRingState(10, 10, 0)
        
        ring.unread(byteCount: 14)
        assertRingState(28, 10, 14)
        
        ring.unwrite(byteCount: 14)
        assertRingState(28, 28, 0)
        
        // Static string API, this time:
        try ring.write(staticString: "This is a test string")
        assertRingState(28, 17, 21)
        
        ring.unwrite(byteCount: 7)      // " string"
        assertRingState(28, 10, 14)      // "This is a test"
        
        let peekedStaticString = ring.peekString(length: 7)     // "This is"
        XCTAssertNotNil(peekedStaticString)
        XCTAssertEqual(peekedStaticString, "This is")
        assertRingState(28, 10, 14)
        
        let readStaticString = ring.readString(length: 14)    // "This is a test"
        XCTAssertNotNil(readStaticString)
        XCTAssertEqual(readStaticString, "This is a test")
        assertRingState(10, 10, 0)
        
        ring.unread(byteCount: 4)       // un-read "test"
        assertRingState(6, 10, 4)
        
        XCTAssertEqual(ring.readString(length: 4), "test")
        assertRingState(10, 10, 0)
        
        ring.unread(byteCount: 14)
        assertRingState(28, 10, 14)
    }
    
    func testRebasing() throws {
        // case 1: already contiguous, head at zero.
        try ring.write(staticString: "This is a test string")
        assertRingState(0, 21, 21)
        
        ring.makeContiguous()
        assertRingState(0, 21, 21)
        
        // case 2: buffer is empty, head not at zero
        ring.moveHead(forwardBy: 21)
        assertRingState(21, 21, 0)
        
        ring.makeContiguous()
        assertRingState(0, 0, 0)
        
        // case 3: already contiguous, head not at zero
        try ring.write(staticString: "This is a test string")
        assertRingState(0, 21, 21)
        ring.moveHead(forwardBy: 5)     // "is a test string"
        assertRingState(5, 21, 16)
        
        ring.makeContiguous()
        assertRingState(0, 16, 16)
        
        // case 4: non-contiguous, room in the middle to shuffle
        ring.unwrite(byteCount: 16)
        assertRingState(0, 0, 0)
        
        try ring.write(staticString: "This is a test string")
        assertRingState(0, 21, 21)
        
        ring.moveHead(forwardBy: 21)
        assertRingState(21, 21, 0)
        
        try ring.write(staticString: "Wraps Buffer")
        assertRingState(21, 1, 12)
        
        ring.makeContiguous()
        assertRingState(0, 12, 12)
        
        // case 5: non-contiguous, not enough room to make two copies
        ring.moveHead(forwardBy: 12)
        assertRingState(12, 12, 0)
        
        try ring.write(staticString: "This is a test string again")
        assertRingState(12, 7, 27)
        
        ring.makeContiguous()
        assertRingState(0, 27, 27)
    }
}
