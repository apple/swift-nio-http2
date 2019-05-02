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
import NIOHPACK
@testable import NIOHTTP2

class HTTP2FrameParserTests: XCTestCase {
    
    let allocator = ByteBufferAllocator()
    
    let simpleHeaders = HPACKHeaders([
        (":method", "GET"),
        (":scheme", "http"),
        (":path", "/"),
        (":authority", "www.example.com")
    ])
    let simpleHeadersEncoded: [UInt8] = [0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
    
    // MARK: - Utilities
    
    private func byteBuffer<C: Collection>(withBytes bytes: C, extraCapacity: Int = 0) -> ByteBuffer where C.Element == UInt8 {
        var buf = allocator.buffer(capacity: bytes.count + extraCapacity)
        buf.writeBytes(bytes)
        return buf
    }
    
    private func byteBuffer(withStaticString string: StaticString) -> ByteBuffer {
        var buf = allocator.buffer(capacity: string.utf8CodeUnitCount)
        buf.writeStaticString(string)
        return buf
    }
    
    private func assertEqualFrames(_ frame1: HTTP2Frame, _ frame2: HTTP2Frame,
                                   file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(frame1.streamID, frame2.streamID, "StreamID mismatch: \(frame1.streamID) != \(frame2.streamID)",
            file: file, line: line)
        
        switch (frame1.payload, frame2.payload) {
        case let (.data(l), .data(r)):
            switch (l.data, r.data) {
            case let (.byteBuffer(lb), .byteBuffer(rb)):
                XCTAssertEqual(lb, rb, "Data bytes mismatch: \(lb) != \(rb)", file: file, line: line)
            default:
                XCTFail("We're not testing with file regions!", file: file, line: line)
            }
            XCTAssertEqual(l.endStream, r.endStream, "endStream mismatch: \(l.endStream) != \(r.endStream)", file: file, line: line)
            XCTAssertEqual(l.paddingBytes, r.paddingBytes, "paddingBytes mismatch: \(String(describing: l.paddingBytes)) != \(String(describing: r.paddingBytes))", file: file, line: line)
            
        case let (.headers(l), .headers(r)):
            XCTAssertEqual(l.headers, r.headers, "Headers mismatch: \(l.headers) != \(r.headers)", file: file, line: line)
            XCTAssertEqual(l.priorityData, r.priorityData, "Priority mismatch: \(String(describing: l.priorityData)) != \(String(describing: r.priorityData))",
                file: file, line: line)
            XCTAssertEqual(l.endStream, r.endStream, "endStream mismatch: \(l.endStream) != \(r.endStream)", file: file, line: line)
            XCTAssertEqual(l.paddingBytes, r.paddingBytes, "paddingBytes mismatch: \(String(describing: l.paddingBytes)) != \(String(describing: r.paddingBytes))", file: file, line: line)
            
        case let (.priority(lp), .priority(rp)):
            XCTAssertEqual(lp, rp, "Priority mismatch: \(lp) != \(rp)", file: file, line: line)
            
        case let (.rstStream(le), .rstStream(re)):
            XCTAssertEqual(le, re, "Error mismatch: \(le) != \(re)", file: file, line: line)
            
        case let (.settings(.settings(ls)), .settings(.settings(rs))):
            XCTAssertEqual(ls, rs, "Settings mismatch: \(ls) != \(rs)", file: file, line: line)

        case (.settings(.ack), .settings(.ack)):
            // Nothing specific to compare here.
            break
            
        case let (.pushPromise(l), .pushPromise(r)):
            XCTAssertEqual(l.pushedStreamID, r.pushedStreamID, "Stream ID mismatch: \(l.pushedStreamID) != \(r.pushedStreamID)", file: file, line: line)
            XCTAssertEqual(l.headers, r.headers, "Headers mismatch: \(l.headers) != \(r.headers)", file: file, line: line)
            XCTAssertEqual(l.paddingBytes, r.paddingBytes, "paddingBytes mismatch: \(String(describing: l.paddingBytes)) != \(String(describing: r.paddingBytes))", file: file, line: line)
            
        case let (.ping(lp, la), .ping(rp, ra)):
            XCTAssertEqual(lp, rp, "Ping data mismatch: \(lp) != \(rp)", file: file, line: line)
            XCTAssertEqual(la, ra, "Ping ack flag mismatch: \(la) != \(ra)", file: file, line: line)
            
        case let (.goAway(ls, le, lo), .goAway(rs, re, ro)):
            XCTAssertEqual(ls, rs, "Stream ID mismatch: \(ls) != \(rs)", file: file, line: line)
            XCTAssertEqual(le, re, "Error mismatch: \(le) != \(re)", file: file, line: line)
            XCTAssertEqual(lo, ro, "Opaque data mismatch: \(String(describing: lo)) != \(String(describing: ro))",
                file: file, line: line)
            
        case let (.windowUpdate(ls), .windowUpdate(rs)):
            XCTAssertEqual(ls, rs, "Window size mismatch: \(ls) != \(rs)", file: file, line: line)
            
        case let (.alternativeService(lo, lf), .alternativeService(ro, rf)):
            XCTAssertEqual(lo, ro, "Origin mismatch: \(String(describing: lo)), \(String(describing: ro))",
                file: file, line: line)
            XCTAssertEqual(lf, rf, "ALTSVC field mismatch: \(String(describing: lf)), \(String(describing: rf))",
                file: file, line: line)
            
        case let (.origin(lo), .origin(ro)):
            XCTAssertEqual(lo, ro, "Origins mismatch: \(lo) != \(ro)", file: file, line: line)
            
        default:
            XCTFail("Payload mismatch: \(frame1.payload) / \(frame2.payload)", file: file, line: line)
        }
    }
    
    private func assertReadsFrame(from bytes: inout ByteBuffer, matching expectedFrame: HTTP2Frame,
                                  expectedFlowControlledLength: Int = 0,
                                  file: StaticString = #file, line: UInt = #line) throws {
        let initialByteIndex = bytes.readerIndex
        let totalFrameSize = bytes.readableBytes
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        decoder.append(bytes: &bytes)
        XCTAssertEqual(bytes.readableBytes, 0)

        let (frame, actualLength) = try decoder.nextFrame()!

        // should consume all the bytes
        XCTAssertEqual(bytes.readableBytes, 0)

        self.assertEqualFrames(frame, expectedFrame, file: file, line: line)
        XCTAssertEqual(actualLength, expectedFlowControlledLength, "Non-matching flow controlled length", file: file, line: line)

        if totalFrameSize > 9 {
            // Now try again with the frame arriving in two separate chunks.
            bytes.moveReaderIndex(to: initialByteIndex)
            var first = bytes.readSlice(length: 9)!
            var second = bytes
            
            decoder.append(bytes: &first)
            XCTAssertEqual(first.readableBytes, 0)
            XCTAssertNil(try decoder.nextFrame())

            decoder.append(bytes: &second)
            XCTAssertEqual(second.readableBytes, 0)
            let (realFrame, length) = try decoder.nextFrame()!
            XCTAssertNotNil(realFrame)

            self.assertEqualFrames(realFrame, expectedFrame, file: file, line: line)
            XCTAssertEqual(length, expectedFlowControlledLength, "Non-matching flow controlled length in parts",
                           file: file, line: line)
        }
    }
    
    // MARK: - General functionality
    
    func testPaddingIsNotAllowedByEncoder() {
        let bytes = self.byteBuffer(withBytes: [0x00, 0x01, 0x02, 0x03])
        let frame = HTTP2Frame(streamID: HTTP2StreamID(1), payload: .data(.init(data: .byteBuffer(bytes), paddingBytes: 0)))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        var target = self.allocator.buffer(capacity: 48)
        
        XCTAssertThrowsError(try encoder.encode(frame: frame, to: &target), "Should throw an Unsupported error", { err in
            guard let unsupported = err as? NIOHTTP2Errors.Unsupported, unsupported.info.contains("Padding") else {
                XCTFail("Should have thrown an error due to unsupported PADDING flag")
                return
            }
        })
    }
    
    // MARK: - DATA frames

    func testDataFrameDecodingNoPadding() throws {
        let payload = byteBuffer(withStaticString: "Hello, World!")
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .data(.init(data: .byteBuffer(payload), endStream: true)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0d,           // 3-byte payload length (13 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: payload.readableBytes)
        buf.writeBytes(payload.readableBytesView)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame, expectedFlowControlledLength: 13)
    }
    
    func testDataFrameDecodingWithPadding() throws {
        let payload = byteBuffer(withStaticString: "Hello, World!")
        // We remove the PADDED flag when eliding padding bytes.
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .data(.init(data: .byteBuffer(payload), endStream: true)))
        
        // Unpadded frame is 22 bytes. When we add padding, we get +1 byte for pad length, +1 byte of padding, for 24 bytes total
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0f,           // 3-byte payload length (15 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x09,                       // 1-byte flags (PADDED, END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x01,                       // 1-byte padding length
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: payload.readableBytes + 1)
        buf.writeBytes(payload.readableBytesView)
        buf.writeInteger(UInt8(0))
        
        try assertReadsFrame(from: &buf, matching: expectedFrame, expectedFlowControlledLength: 15)
    }

    func testDataFrameDecodingWithPaddingSplitOverBuffers() throws {
        // Unpadded frame is 22 bytes. When we add padding, we get +1 byte for pad length, +2 byte of padding, for 25 bytes total.
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x10,           // 3-byte payload length (16 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x09,                       // 1-byte flags (PADDED, END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x02,                       // 1-byte padding length (2 bytes)
        ]

        let expectedPayload = byteBuffer(withStaticString: "Hello, World!")
        // We remove the PADDED flag when eliding padding bytes.
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .data(.init(data: .byteBuffer(expectedPayload), endStream: true)))

        var frameBuffer = byteBuffer(withBytes: frameBytes, extraCapacity: expectedPayload.readableBytes)
        frameBuffer.writeBytes(expectedPayload.readableBytesView)

        var firstPaddingBuffer = byteBuffer(withBytes: [UInt8(0)])
        var secondPaddingBuffer = byteBuffer(withBytes: [UInt8(0)])

        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)

        decoder.append(bytes: &frameBuffer)
        XCTAssertEqual(frameBuffer.readableBytes, 0)
        let (frame, actualLength) = try decoder.nextFrame()!
        self.assertEqualFrames(frame, expectedFrame)
        XCTAssertEqual(actualLength, 16)

        decoder.append(bytes: &firstPaddingBuffer)
        XCTAssertEqual(firstPaddingBuffer.readableBytes, 0)
        XCTAssertNil(try decoder.nextFrame())

        decoder.append(bytes: &secondPaddingBuffer)
        XCTAssertEqual(secondPaddingBuffer.readableBytes, 0)
        XCTAssertNil(try decoder.nextFrame())
    }
    
    func testSyntheticMultipleDataFrames() throws {
        let payload = byteBuffer(withStaticString: "Hello, World!Hello, World!")
        let payloadHalf = byteBuffer(withStaticString: "Hello, World!")
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x01a,           // 3-byte payload length (26 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: payload.readableBytes)
        buf.writeBytes(payload.readableBytesView)
        
        // two separate pieces
        let expectedFrame1 = HTTP2Frame(streamID: HTTP2StreamID(1),
                                        payload: .data(.init(data: .byteBuffer(payloadHalf))))
        let expectedFrame2 = HTTP2Frame(streamID: HTTP2StreamID(1),
                                        payload: .data(.init(data: .byteBuffer(payloadHalf), endStream: true)))
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        var slice = buf.readSlice(length: buf.readableBytes - payloadHalf.readableBytes)!
        decoder.append(bytes: &slice)
        XCTAssertEqual(slice.readableBytes, 0)
        let frame: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)
        self.assertEqualFrames(frame, expectedFrame1)
        
        decoder.append(bytes: &buf)
        XCTAssertEqual(buf.readableBytes, 0)
        let frame2: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)
        self.assertEqualFrames(frame2, expectedFrame2)
    }
    
    func testComplexPaddedSyntheticMultiDataFrames() throws {
        let payload = byteBuffer(withStaticString: "Hello, World!Hello, World!")
        let payloadHalf = byteBuffer(withStaticString: "Hello, World!")
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x1f,           // 3-byte payload length (31 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x09,                       // 1-byte flags (END_STREAM, PADDED)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x04,                       // 1-byte padding length
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: payload.readableBytes)
        buf.writeBytes(payload.readableBytesView)
        buf.writeBytes(Array(repeating: UInt8(0), count: 4))
        XCTAssertEqual(buf.readableBytes, 40)
        
        // two separate pieces, padded flag removed along with padding bytes
        let expectedFrame1 = HTTP2Frame(streamID: HTTP2StreamID(1),
                                        payload: .data(.init(data: .byteBuffer(payloadHalf))))
        let expectedFrame2 = HTTP2Frame(streamID: HTTP2StreamID(1),
                                        payload: .data(.init(data: .byteBuffer(payloadHalf), endStream: true)))
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        var slice = buf.readSlice(length: 9)!
        decoder.append(bytes: &slice)
        XCTAssertEqual(slice.readableBytes, 0)
        let noFrame: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNil(noFrame)       // no frame produced
        
        // append the next slice to the remaining bytes
        var next = buf.readSlice(length: payloadHalf.readableBytes + 1)!
        decoder.append(bytes: &next)
        XCTAssertEqual(next.readableBytes, 0)
        let frame: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)  // produces a frame
        self.assertEqualFrames(frame, expectedFrame1)
        
        decoder.append(bytes: &buf)
        XCTAssertEqual(buf.readableBytes, 0)
        let frame2: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)      // produces frame
        self.assertEqualFrames(frame2, expectedFrame2)
    }

    func testDataFrameDecodingMultibyteLength() throws {
        var payload = allocator.buffer(capacity: 16384)
        payload.writeBytes(repeatElement(0, count: 16384))
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .data(.init(data: .byteBuffer(payload), endStream: true)))

        let frameBytes: [UInt8] = [
            0x00, 0x40, 0x00,           // 3-byte payload length (16384 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: payload.readableBytes)
        buf.writeBytes(payload.readableBytesView)

        try assertReadsFrame(from: &buf, matching: expectedFrame, expectedFlowControlledLength: 16384)
    }

    func testDataFrameDecodingZeroLengthPayload() throws {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x00,           // 3-byte payload length (0 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]

        let payload = allocator.buffer(capacity: 0)
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .data(.init(data: .byteBuffer(payload), endStream: true)))

        var buf = byteBuffer(withBytes: frameBytes)
        try assertReadsFrame(from: &buf, matching: expectedFrame, expectedFlowControlledLength: 0)
    }

    func testDataFrameDecodingPaddingOnlyPayload() throws {
        // Unpadded frame is 9 bytes. When we add padding, we get +1 byte for pad length, +1 byte of padding, for 11 bytes total.
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x02,           // 3-byte payload length (2 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x09,                       // 1-byte flags (PADDED, END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x01,                       // 1-byte padding length
        ]

        let expectedPayload = allocator.buffer(capacity: 0)
        // We remove the PADDED flag when eliding padding bytes.
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .data(.init(data: .byteBuffer(expectedPayload), endStream: true)))

        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 1)
        buf.writeInteger(UInt8(0))

        try assertReadsFrame(from: &buf, matching: expectedFrame, expectedFlowControlledLength: 2)
    }

    func testDataFrameDecodingWithOnlyPaddingSplitOverBuffers() throws {
        // Unpadded frame is 9 bytes. When we add padding, we get +1 byte for pad length, +2 byte of padding, for 12 bytes total.
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x03,           // 3-byte payload length (3 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x09,                       // 1-byte flags (PADDED, END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x02,                       // 1-byte padding length
        ]

        let expectedPayload = allocator.buffer(capacity: 0)
        // We remove the PADDED flag when eliding padding bytes.
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .data(.init(data: .byteBuffer(expectedPayload), endStream: true)))

        var frameBuffer = byteBuffer(withBytes: frameBytes)
        var firstPaddingBuffer = byteBuffer(withBytes: [UInt8(0)])
        var secondPaddingBuffer = byteBuffer(withBytes: [UInt8(0)])

        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)

        decoder.append(bytes: &frameBuffer)
        XCTAssertEqual(frameBuffer.readableBytes, 0)
        let (frame, actualLength) = try decoder.nextFrame()!
        self.assertEqualFrames(frame, expectedFrame)
        XCTAssertEqual(actualLength, 3)

        decoder.append(bytes: &firstPaddingBuffer)
        XCTAssertEqual(firstPaddingBuffer.readableBytes, 0)
        XCTAssertNil(try decoder.nextFrame())

        decoder.append(bytes: &secondPaddingBuffer)
        XCTAssertEqual(secondPaddingBuffer.readableBytes, 0)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testDataFrameEncoding() throws {
        let payload = "Hello, World!"
        let streamID = HTTP2StreamID(1)
        var payloadBytes = allocator.buffer(capacity: payload.count)
        payloadBytes.writeString(payload)

        let frame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(payloadBytes), endStream: true)))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)

        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0d,           // 3-byte payload length (13 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)

        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNotNil(extraBuf, "Should have returned an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }

    func testDataFrameEncodingMultibyteLength() throws {
        let streamID = HTTP2StreamID(1)
        var payloadBytes = allocator.buffer(capacity: 16384)
        payloadBytes.writeBytes(repeatElement(0, count: 16384))

        let frame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(payloadBytes), endStream: true)))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)

        let frameBytes: [UInt8] = [
            0x00, 0x40, 0x00,           // 3-byte payload length (16384 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)

        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNotNil(extraBuf, "Should have returned an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }


    func testDataFrameEncodingViolatingMaxFrameSize() throws {
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        XCTAssertEqual(encoder.maxFrameSize, 16384)

        var content = self.allocator.buffer(capacity: 16385)
        content.writeBytes(repeatElement(UInt8(0), count: 16385))

        let frame = HTTP2Frame(streamID: 1, payload: .data(.init(data: .byteBuffer(content))))
        var target = self.allocator.buffer(capacity: 1024)

        XCTAssertThrowsError(try encoder.encode(frame: frame, to: &target)) { error in
            XCTAssertEqual(error as? InternalError, .codecError(code: .frameSizeError))
        }
    }

    func testDataFrameDecodeFailureRootStream() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x01,           // 3-byte payload length (1 byte)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier (INVALID)
            0x00,                       // payload
        ]
        var badFrameBuf = byteBuffer(withBytes: frameBytes)
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        decoder.append(bytes: &badFrameBuf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
    }
    
    func testDataFrameDecodeFailureExcessPadding() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x01,           // 3-byte payload length (1 byte)
            0x00,                       // 1-byte frame type (DATA)
            0x09,                       // 1-byte flags (PADDED, END_STREAM)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier (INVALID)
            0x01,                       // 1-byte padding
                                        // no payload!
        ]
        var buf = self.byteBuffer(withBytes: frameBytes)
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
    }

    func testDataFrameDecodingViolatingMaxFrameSize() throws {
        let frameBytes: [UInt8] = [
            0x00, 0x40, 0x01,           // 3-byte payload length (16385 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var badFrameBuf = byteBuffer(withBytes: frameBytes)
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        XCTAssertEqual(decoder.maxFrameSize, 16384)

        decoder.append(bytes: &badFrameBuf)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? InternalError, .codecError(code: .frameSizeError))
        }
    }
    
    // MARK: - HEADERS frames
    
    func testHeadersFrameDecodingNoPriorityNoPadding() throws {
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .headers(.init(headers: self.simpleHeaders)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x11,           // 3-byte payload length (17 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.writeBytes(self.simpleHeadersEncoded)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testHeadersFrameDecodingNoPriorityWithPadding() throws {
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .headers(.init(headers: self.simpleHeaders, paddingBytes: 3)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x0c,                       // 1-byte flags (PADDED, END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x03,                       // 1-byte pad length
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count + 4)
        buf.writeBytes(self.simpleHeadersEncoded)
        buf.writeBytes([UInt8](repeating: 0, count: 3))
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testHeadersFrameDecodingWithPriorityNoPadding() throws {
        let priority = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(1), weight: 139)
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(3),
                                       payload: .headers(.init(headers: self.simpleHeaders, priorityData: priority)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x16,           // 3-byte payload length (22 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x24,                       // 1-byte flags (END_HEADERS, PRIORITY)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.writeBytes(self.simpleHeadersEncoded)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testHeadersFrameDecodingWithPriorityWithPadding() throws {
        let priority = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(1), weight: 139)
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(3),
                                       payload: .headers(.init(headers: self.simpleHeaders, priorityData: priority, paddingBytes: 8)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x1F,           // 3-byte payload length (31 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x2c,                       // 1-byte flags (PADDED, END_HEADERS, PRIORITY)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x08,                       // 1-byte pad length
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count + 8)
        buf.writeBytes(self.simpleHeadersEncoded)
        buf.writeBytes([UInt8](repeating: 0, count: 8))
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testHeadersFrameDecodeFailures() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x0c,                       // 1-byte flags (PADDED, END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x03,                       // 1-byte pad length
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.writeBytes(self.simpleHeadersEncoded)
        buf.writeBytes([UInt8](repeating: 0, count: 3))
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // should fail if the stream is zero
        buf.setInteger(UInt8(0), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
        
        buf.moveReaderIndex(to: 0)
        buf.setInteger(UInt8(1), at: 8)
        
        // pad size that exceeds payload size is illegal
        buf.setInteger(UInt8(200), at: 9)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
    }
    
    func testHeadersFrameEncodingNoPriority() throws {
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: self.simpleHeaders)))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x11,           // 3-byte payload length (17 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var expectedBufContent = byteBuffer(withBytes: frameBytes)
        expectedBufContent.writeBytes(self.simpleHeadersEncoded)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not return an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    func testHeadersFrameEncodingWithPriority() throws {
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(1), weight: 139)
        let streamID = HTTP2StreamID(3)
        
        let frame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: self.simpleHeaders, priorityData: priorityData)))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x16,           // 3-byte payload length (22 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x24,                       // 1-byte flags (END_HEADERS, PRIORITY)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        var expectedBufContent = byteBuffer(withBytes: frameBytes)
        expectedBufContent.writeBytes(self.simpleHeadersEncoded)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not return an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - PRIORITY frames
    
    func testPriorityFrameDecoding() throws {
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(1), weight: 139)
        let expectedFrame = HTTP2Frame(streamID: 3, payload: .priority(priorityData))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x05,           // 3-byte payload length (5 bytes)
            0x02,                       // 1-byte frame type (PRIORITY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testPriorityFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x05,           // 3-byte payload length (5 bytes)
            0x02,                       // 1-byte frame type (PRIORITY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // cannot be on root stream
        buf.setInteger(UInt8(0), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.setInteger(UInt8(3), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // must have a size of 5 octets
        buf.setInteger(UInt8(6), at: 2)
        buf.writeInteger(UInt8(0))        // append an extra byte so we read it all
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a frame size error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .frameSizeError) = connErr else {
                XCTFail("Should have thrown a codec error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testPriorityFrameEncoding() throws {
        let streamID = HTTP2StreamID(3)
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(1), weight: 139)
        let frame = HTTP2Frame(streamID: streamID, payload: .priority(priorityData))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x05,           // 3-byte payload length (5 bytes)
            0x02,                       // 1-byte frame type (PRIORITY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not have returned extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - RST_STREAM frames
    
    func testResetStreamFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(streamID: 1, payload: .rstStream(.protocolError))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x03,                       // 1-byte frame type (RST_STREAM)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x01,     // 4-byte error (PROTOCOL_ERROR = 0x1)
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testResetStreamFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x03,                       // 1-byte frame type (RST_STREAM)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x01,     // 4-byte error (PROTOCOL_ERROR = 0x1)
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // cannot be on root stream
        buf.setInteger(UInt8(0), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.setInteger(UInt8(1), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // must have a size of 4 octets
        buf.setInteger(UInt8(5), at: 2)
        buf.writeInteger(UInt8(0))        // append an extra byte so we read it all
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a frame size error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .frameSizeError) = connErr else {
                XCTFail("Should have thrown a codec error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testResetStreamFrameEncoding() throws {
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .rstStream(.protocolError))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x03,                       // 1-byte frame type (RST_STREAM)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x01,     // 4-byte error (PROTOCOL_ERROR = 0x1)
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not have returned extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - SETTINGS frames
    
    func testSettingsFrameDecoding() throws {
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .headerTableSize, value: 256),
            HTTP2Setting(parameter: .initialWindowSize, value: 32_768),
            HTTP2Setting(parameter: .maxHeaderListSize, value: 2_048)
        ]
        let expectedFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x12,           // 3-byte payload length (18 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x01,                 // SETTINGS_HEADER_TABLE_SIZE
            0x00, 0x00, 0x01, 0x00,     //      = 256 bytes
            0x00, 0x04,                 // SETTINGS_INITIAL_WINDOW_SIZE
            0x00, 0x00, 0x80, 0x00,     //      = 32 KiB
            0x00, 0x06,                 // SETTINGS_MAX_HEADER_LIST_SIZE
            0x00, 0x00, 0x08, 0x00,     //      = 2 KiB
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }

  func testSettingsFrameDecodingWithNoSettings() throws {
    let settings: [HTTP2Setting] = []
    let expectedFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))

    let frameBytes: [UInt8] = [
      0x00, 0x00, 0x00,           // 3-byte payload length (0 bytes)
      0x04,                       // 1-byte frame type (SETTINGS)
      0x00,                       // 1-byte flags (none)
      0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
    ]
    var buf = byteBuffer(withBytes: frameBytes)

    try assertReadsFrame(from: &buf, matching: expectedFrame)
  }
    
    func testSettingsFrameDecodingWithUnknownItems() throws {
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .headerTableSize, value: 256),
            HTTP2Setting(parameter: .initialWindowSize, value: 32_768),
            HTTP2Setting(parameter: HTTP2SettingsParameter(fromNetwork: 0x99), value: 32_768),
            HTTP2Setting(parameter: .maxHeaderListSize, value: 2_048)
        ]
        let expectedFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x18,           // 3-byte payload length (18 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x01,                 // SETTINGS_HEADER_TABLE_SIZE
            0x00, 0x00, 0x01, 0x00,     //      = 256 bytes
            0x00, 0x04,                 // SETTINGS_INITIAL_WINDOW_SIZE
            0x00, 0x00, 0x80, 0x00,     //      = 32 KiB
            0x00, 0x99,                 // <<UNKNOWN SETTING ID>>
            0x00, 0x00, 0x80, 0x00,     //      = 32768 somethings
            0x00, 0x06,                 // SETTINGS_MAX_HEADER_LIST_SIZE
            0x00, 0x00, 0x08, 0x00,     //      = 2 KiB
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testSettingsFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x12,           // 3-byte payload length (18 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x01,                 // SETTINGS_HEADER_TABLE_SIZE
            0x00, 0x00, 0x01, 0x00,     //      = 256 bytes
            0x00, 0x04,                 // SETTINGS_INITIAL_WINDOW_SIZE
            0x00, 0x00, 0x80, 0x00,     //      = 32 KiB
            0x00, 0x06,                 // SETTINGS_MAX_HEADER_LIST_SIZE
            0x00, 0x00, 0x08, 0x00,     //      = 2 KiB
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // MUST be sent on the root stream
        buf.setInteger(UInt8(1), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.setInteger(UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // size must be a multiple of 6 octets
        buf.setInteger(UInt8(19), at: 2)
        buf.writeInteger(UInt8(0))        // append an extra byte so we read it all
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a frame size error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .frameSizeError) = connErr else {
                XCTFail("Should have thrown a codec error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testSettingsFrameEncoding() throws {
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .headerTableSize, value: 256),
            HTTP2Setting(parameter: .initialWindowSize, value: 32_768),
            HTTP2Setting(parameter: .maxHeaderListSize, value: 2_048)
        ]
        let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(settings)))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x12,           // 3-byte payload length (18 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x01,                 // SETTINGS_HEADER_TABLE_SIZE
            0x00, 0x00, 0x01, 0x00,     //      = 256 bytes
            0x00, 0x04,                 // SETTINGS_INITIAL_WINDOW_SIZE
            0x00, 0x00, 0x80, 0x00,     //      = 32 KiB
            0x00, 0x06,                 // SETTINGS_MAX_HEADER_LIST_SIZE
            0x00, 0x00, 0x08, 0x00,     //      = 2 KiB
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not have returned extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    func testSettingsAckFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.ack))
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x00,           // 3-byte payload length (0 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try self.assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testSettingsAckFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x00,           // 3-byte payload length (0 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // MUST be sent on the root stream
        buf.setInteger(UInt8(1), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.setInteger(UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // size must be 0 for ACKs
        buf.setInteger(UInt8(1), at: 2)
        buf.writeInteger(UInt8(0))        // append an extra byte so we read it all
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a frame size error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .frameSizeError) = connErr else {
                XCTFail("Should have thrown a codec error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testSettingsAckFrameEncoding() throws {
        let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(.ack))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x00,           // 3-byte payload length (0 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not have returned extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - PUSH_PROMISE frames
    
    func testPushPromiseFrameDecodingNoPadding() throws {
        let streamID = HTTP2StreamID(3)
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .pushPromise(.init(pushedStreamID: streamID, headers: self.simpleHeaders)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.writeBytes(self.simpleHeadersEncoded)
        
        try self.assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testPushPromiseFrameDecodingWithPadding() throws {
        let streamID = HTTP2StreamID(3)
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .pushPromise(.init(pushedStreamID: streamID, headers: self.simpleHeaders, paddingBytes: 1)))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x17,           // 3-byte payload length (23 bytes) (32 total)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x0c,                       // 1-byte flags (END_HEADERS, PADDED)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x01,                       // 1-byte pad size
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.writeBytes(self.simpleHeadersEncoded)
        buf.writeInteger(UInt8(0))
        
        try self.assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testPushPromiseFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        buf.writeBytes(self.simpleHeadersEncoded)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // MUST NOT be sent on the root stream
        buf.setInteger(UInt8(0), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.setInteger(UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
    }
    
    func testPushPromiseFrameEncoding() throws {
        let streamID = HTTP2StreamID(3)
        let frame = HTTP2Frame(streamID: HTTP2StreamID(1),
                               payload: .pushPromise(.init(pushedStreamID: streamID, headers: self.simpleHeaders)))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        var expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        expectedBufContent.writeBytes(self.simpleHeadersEncoded)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not return an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - PING frames
    
    func testPingFrameDecoding() throws {
        let pingData = HTTP2PingData(withTuple: (0,1,2,3,4,5,6,7))
        let expectedFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: false))
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (8 bytes)
            0x06,                       // 1-byte frame type (PING)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            
            // PING payload, 8 bytes
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try self.assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testPingAckFrameDecoding() throws {
        let pingData = HTTP2PingData(withTuple: (0,1,2,3,4,5,6,7))
        let expectedFrame = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: true))
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (8 bytes)
            0x06,                       // 1-byte frame type (PING)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            
            // PING payload, 8 bytes
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
            ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try self.assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testPingFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (8 bytes)
            0x06,                       // 1-byte frame type (PING)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            
            // PING payload, 8 bytes
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // MUST NOT be associated with a stream.
        buf.setInteger(UInt8(1), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.setInteger(UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // length MUST be 8 octets
        buf.setInteger(UInt8(7), at: 2)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a frame size error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .frameSizeError) = connErr else {
                XCTFail("Should have thrown a codec error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testPingFrameEncoding() throws {
        let pingData = HTTP2PingData(withTuple: (0,1,2,3,4,5,6,7))
        let frame = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: false))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (8 bytes)
            0x06,                       // 1-byte frame type (PING)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            
            // PING payload, 8 bytes
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
        ]
        let expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not return an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    func testPingAckFrameEncoding() throws {
        let pingData = HTTP2PingData(withTuple: (0,1,2,3,4,5,6,7))
        let frame = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: true))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (8 bytes)
            0x06,                       // 1-byte frame type (PING)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            
            // PING payload, 8 bytes
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
        ]
        let expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not return an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - GOAWAY frame
    
    func testGoAwayFrameDecoding() throws {
        let dataBytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let lastStreamID = HTTP2StreamID(1)
        let opaqueData = self.byteBuffer(withBytes: dataBytes)
        let expectedFrame = HTTP2Frame(streamID: .rootStream,
                                       payload: .goAway(lastStreamID: lastStreamID, errorCode: .frameSizeError, opaqueData: opaqueData))
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x10,           // 3-byte payload length (16 bytes)
            0x07,                       // 1-byte frame type (GOAWAY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            0x00, 0x00, 0x00, 0x01,     // 4-byte last stream identifier,
            0x00, 0x00, 0x00, 0x06,     // 4-byte error code
            
            // opaque data (8 bytes)
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try self.assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testGoAwayFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x10,           // 3-byte payload length (16 bytes)
            0x07,                       // 1-byte frame type (GOAWAY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            0x00, 0x00, 0x00, 0x01,     // 4-byte last stream identifier,
            0x00, 0x00, 0x00, 0x06,     // 4-byte error code
            
            // opaque data (8 bytes)
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // MUST NOT be associated with a stream.
        buf.setInteger(UInt8(1), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a protocol error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .protocolError) = connErr else {
                XCTFail("Should have thrown a codec error of type PROTOCOL_ERROR")
                return
            }
        })
    }
    
    func testGoAwayFrameEncodingWithOpaqueData() throws {
        let dataBytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let lastStreamID = HTTP2StreamID(1)
        let opaqueData = self.byteBuffer(withBytes: dataBytes)
        let frame = HTTP2Frame(streamID: .rootStream,
                               payload: .goAway(lastStreamID: lastStreamID, errorCode: .frameSizeError, opaqueData: opaqueData))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x10,           // 3-byte payload length (16 bytes)
            0x07,                       // 1-byte frame type (GOAWAY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            0x00, 0x00, 0x00, 0x01,     // 4-byte last stream identifier,
            0x00, 0x00, 0x00, 0x06,     // 4-byte error code
        ]
        let expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNotNil(extraBuf, "Should return an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
        XCTAssertEqual(extraBuf!, .byteBuffer(opaqueData))
    }
    
    func testGoAwayFrameEncodingWithNoOpaqueData() throws {
        let lastStreamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: .rootStream,
                               payload: .goAway(lastStreamID: lastStreamID, errorCode: .frameSizeError, opaqueData: nil))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (8 bytes)
            0x07,                       // 1-byte frame type (GOAWAY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            0x00, 0x00, 0x00, 0x01,     // 4-byte last stream identifier,
            0x00, 0x00, 0x00, 0x06,     // 4-byte error code
        ]
        let expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not return an extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - WINDOW_UPDATE frame
    
    func testWindowUpdateFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(streamID: 1, payload: .windowUpdate(windowSizeIncrement: 5))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x08,                       // 1-byte frame type (WINDOW_UPDATE)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x05,     // window size adjustment
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testWindowUpdateFrameDecodingFailure() {
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x08,                       // 1-byte frame type (WINDOW_UPDATE)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x05,     // window size adjustment
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // must have a size of 4 octets
        buf.setInteger(UInt8(5), at: 2)
        buf.writeInteger(UInt8(0))        // append an extra byte so we read it all
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a frame size error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .frameSizeError) = connErr else {
                XCTFail("Should have thrown a codec error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testWindowUpdateFrameEncoding() throws {
        let streamID = HTTP2StreamID(1)
        let frame = HTTP2Frame(streamID: streamID, payload: .windowUpdate(windowSizeIncrement: 5))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x08,                       // 1-byte frame type (WINDOW_UPDATE)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x05,     // window size adjustment
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should not have returned extra buf")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - CONTINUATION frames
    
    func testHeadersContinuationFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .headers(.init(headers: self.simpleHeaders)))
        
        var headers2 = self.byteBuffer(withBytes: self.simpleHeadersEncoded)
        var headers1 = headers2.readSlice(length: 10)!
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0a,           // 3-byte payload length (10 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 10)
        buf.writeBuffer(&headers1)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // should return nothing thus far and wait for CONTINUATION frames and an END_HEADERS flag
        decoder.append(bytes: &buf)
        XCTAssertNil(try decoder.nextFrame())
        
        // should consume all the bytes
        XCTAssertEqual(buf.readableBytes, 0)
        buf.clear()
        
        let continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x07,           // 3-byte payload length (7 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers2)
        
        // This should now yield a HEADERS frame containing the complete set of headers
        decoder.append(bytes: &buf)
        let frame: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)
        
        self.assertEqualFrames(frame, expectedFrame)
    }
    
    func testPushPromiseContinuationFrameDecoding() throws {
        let streamID = HTTP2StreamID(3)
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .pushPromise(.init(pushedStreamID: streamID, headers: self.simpleHeaders)))
        
        var headers2 = self.byteBuffer(withBytes: self.simpleHeadersEncoded)
        var headers1 = headers2.readSlice(length: 10)!
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0e,           // 3-byte payload length (14 bytes)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream id
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 10)
        buf.writeBuffer(&headers1)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // should return nothing thus far and wait for CONTINUATION frames and an END_HEADERS flag
        decoder.append(bytes: &buf)
        XCTAssertNil(try decoder.nextFrame())
        
        // should consume all the bytes
        XCTAssertEqual(buf.readableBytes, 0)
        buf.clear()
        
        let continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x07,           // 3-byte payload length (7 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers2)
        
        // This should now yield a HEADERS frame containing the complete set of headers
        decoder.append(bytes: &buf)
        let frame: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)
        
        self.assertEqualFrames(frame, expectedFrame)
    }

    func testUnsolicitedContinuationFrame() throws {
        var headers = self.byteBuffer(withBytes: self.simpleHeadersEncoded)

        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0a,           // 3-byte payload length (17 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 10)
        buf.writeBuffer(&headers)

        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)

        // should throw
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? InternalError, .codecError(code: .protocolError))
        }
    }

    func testContinuationFrameStreamZero() throws {
        var headers2 = self.byteBuffer(withBytes: self.simpleHeadersEncoded)
        var headers1 = headers2.readSlice(length: 10)!

        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0a,           // 3-byte payload length (10 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 10)
        buf.writeBuffer(&headers1)

        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)

        // should return nothing thus far and wait for CONTINUATION frames and an END_HEADERS flag
        decoder.append(bytes: &buf)
        XCTAssertNil(try decoder.nextFrame())

        // should consume all the bytes
        XCTAssertEqual(buf.readableBytes, 0)
        buf.clear()

        let continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x07,           // 3-byte payload length (7 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier, stream 0
        ]
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers2)

        // This should fail
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? InternalError, .codecError(code: .protocolError))
        }
    }

    func testContinuationFrameWrongStream() throws {
        var headers2 = self.byteBuffer(withBytes: self.simpleHeadersEncoded)
        var headers1 = headers2.readSlice(length: 10)!

        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0a,           // 3-byte payload length (10 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 10)
        buf.writeBuffer(&headers1)

        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)

        // should return nothing thus far and wait for CONTINUATION frames and an END_HEADERS flag
        decoder.append(bytes: &buf)
        XCTAssertNil(try decoder.nextFrame())

        // should consume all the bytes
        XCTAssertEqual(buf.readableBytes, 0)
        buf.clear()

        let continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x07,           // 3-byte payload length (7 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier, stream 3
        ]
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers2)

        // This should fail
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? InternalError, .codecError(code: .protocolError))
        }
    }
    
    // MARK: - ALTSVC frames
    
    func testAltServiceFrameDecoding() throws {
        let origin = "apple.com"
        var field = self.allocator.buffer(capacity: 10)
        field.writeStaticString("h2=\":8000\"")
        let expectedFrame = HTTP2Frame(streamID: .rootStream,
                                       payload: .alternativeService(origin: origin, field: field))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x0a,                       // 1-byte frame type (ALTSVC)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x09,                 // 2-byte origin size
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        buf.writeString(origin)
        buf.writeBytes(field.readableBytesView)
        XCTAssertEqual(buf.readableBytes, 30)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testAltServiceFrameDecodingFailure() {
        let origin = "apple.com"
        var field = self.allocator.buffer(capacity: 10)
        field.writeStaticString("h2=\":8000\"")
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x0a,                       // 1-byte frame type (ALTSVC)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
            0x00, 0x09,                 // 2-byte origin size
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        buf.writeString(origin)
        buf.writeBytes(field.readableBytesView)
        XCTAssertEqual(buf.readableBytes, 30)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // cannot have origin on a non-root stream
        buf.setInteger(UInt8(1), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertNil(try decoder.nextFrame())
        XCTAssertEqual(buf.readableBytes, 0)
        
        buf.moveReaderIndex(to: 0)
        buf.setInteger(UInt8(0), at: 8)
        
        // must have origin on non-root stream
        buf.moveWriterIndex(to: 9)
        buf.writeInteger(UInt16(0))
        buf.writeBytes(field.readableBytesView)
        
        decoder.append(bytes: &buf)
        XCTAssertNil(try decoder.nextFrame())
        XCTAssertEqual(buf.readableBytes, 0)
    }
    
    func testAltServiceFrameEncoding() throws {
        let origin = "apple.com"
        var field = self.allocator.buffer(capacity: 10)
        field.writeStaticString("h2=\":8000\"")
        let frame = HTTP2Frame(streamID: .rootStream, payload: .alternativeService(origin: origin, field: field))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x0a,                       // 1-byte frame type (ALTSVC)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            0x00, 0x09,                 // 2-byte origin length
        ]
        var expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        expectedBufContent.writeString(origin)
        
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNotNil(extraBuf, "Should return encoded field as separate buffer")
        XCTAssertEqual(buf, expectedBufContent)
        XCTAssertEqual(extraBuf!, .byteBuffer(field))
    }
    
    // MARK: - ORIGIN frame
    
    func testOriginFrameDecoding() throws {
        let origins = ["apple.com", "www.apple.com", "www2.apple.com"]
        let expectedFrame = HTTP2Frame(streamID: .rootStream, payload: .origin(origins))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x2a,           // 3-byte payload length (42 bytes)
            0x0c,                       // 1-byte frame type (ORIGIN)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        for origin in origins {
            let u = origin.utf8
            buf.writeInteger(UInt16(u.count))
            buf.writeBytes(u)
        }
        XCTAssertEqual(buf.readableBytes, 51)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testOriginFrameDecodingFailure() {
        let origins = ["apple.com", "www.apple.com", "www2.apple.com"]
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x2a,           // 3-byte payload length (42 bytes)
            0x0c,                       // 1-byte frame type (ORIGIN)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes)
        for origin in origins {
            let u = origin.utf8
            buf.writeInteger(UInt16(u.count))
            buf.writeBytes(u)
        }
        XCTAssertEqual(buf.readableBytes, 51)
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        
        // MUST be sent on root stream (else ignored)
        buf.setInteger(UInt8(1), at: 8)
        decoder.append(bytes: &buf)
        XCTAssertNil(try decoder.nextFrame())
        XCTAssertEqual(buf.readableBytes, 0)
        
        buf.moveReaderIndex(to: 0)
        buf.setInteger(UInt8(0), at: 8)
        
        // should throw frame size error if string length exceeds payload size
        buf.setInteger(UInt8(255), at: 9)     // really big string length!
        decoder.append(bytes: &buf)
        XCTAssertThrowsError(try decoder.nextFrame(), "Should throw a frame size error", { err in
            guard let connErr = err as? InternalError, case .codecError(code: .frameSizeError) = connErr else {
                XCTFail("Should have thrown a codec error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testOriginFrameEncoding() throws {
        let origins = ["apple.com", "www.apple.com", "www2.apple.com"]
        let frame = HTTP2Frame(streamID: .rootStream, payload: .origin(origins))
        var encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x2a,           // 3-byte payload length (42 bytes)
            0x0c,                       // 1-byte frame type (ALTSVC)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
        ]
        var expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        for origin in origins {
            let u = origin.utf8
            expectedBufContent.writeInteger(UInt16(u.count))
            expectedBufContent.writeBytes(u)
        }
        
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBuf = try encoder.encode(frame: frame, to: &buf)
        XCTAssertNil(extraBuf, "Should return no extra buffer")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - Multi-Frame Buffers
    
    func testHeaderAndContinuationsInOneBuffer() throws {
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .headers(.init(headers: self.simpleHeaders)))
        
        // Break into four chunks
        var allHeaderBytes = self.byteBuffer(withBytes: self.simpleHeadersEncoded)
        var headers1 = allHeaderBytes.readSlice(length: 4)!
        var headers2 = allHeaderBytes.readSlice(length: 4)!
        var headers3 = allHeaderBytes.readSlice(length: 4)!
        var headers4 = allHeaderBytes       // any remaining bytes
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 10)
        buf.writeBuffer(&headers1)
        
        var continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (7 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers2)
        
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers3)
        
        continuationFrameBytes[2] = UInt8(headers4.readableBytes)
        continuationFrameBytes[4] = 0x04  // END_HEADERS
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers4)
        
        // This should now yield a HEADERS frame containing the complete set of headers
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        decoder.append(bytes: &buf)
        let frame: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)
        
        self.assertEqualFrames(frame, expectedFrame)
    }
    
    func testPushPromiseAndContinuationsInOneBuffer() throws {
        let expectedFrame = HTTP2Frame(streamID: HTTP2StreamID(1),
                                       payload: .pushPromise(.init(pushedStreamID: HTTP2StreamID(3), headers: self.simpleHeaders)))
        
        // Break into four chunks
        var allHeaderBytes = self.byteBuffer(withBytes: self.simpleHeadersEncoded)
        var headers1 = allHeaderBytes.readSlice(length: 4)!
        var headers2 = allHeaderBytes.readSlice(length: 4)!
        var headers3 = allHeaderBytes.readSlice(length: 4)!
        var headers4 = allHeaderBytes       // any remaining bytes
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (4 bytes)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: 17 + 9*3)
        buf.writeBuffer(&headers1)
        
        var continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (7 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers2)
        
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers3)
        
        continuationFrameBytes[2] = UInt8(headers4.readableBytes)
        continuationFrameBytes[4] = 0x04  // END_HEADERS
        buf.writeBytes(continuationFrameBytes)
        buf.writeBuffer(&headers4)
        
        // This should now yield a HEADERS frame containing the complete set of headers
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        decoder.append(bytes: &buf)
        let frame: HTTP2Frame! = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame)
        
        self.assertEqualFrames(frame, expectedFrame)
    }
    
    func testMultipleFramesInOneBuffer() throws {
        // We are going to encode a single buffer containing a bunch of different frames.
        // We'll pretend to be the result of a server with a bad temper responding to a request.
        // It will send out a SETTINGS ACK, then HEADERS, CONTINUATION, DATA, and finally
        // (because it has a bad temper) GOAWAY.
        let settingsAckBytes: [UInt8] = [
            0x00, 0x00, 0x00,           // 3-byte payload length (0 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
        ]
        let headerFrameBytes: [UInt8] = [
            0x00, 0x00, 0x0a,           // 3-byte payload length (10 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ] + self.simpleHeadersEncoded[0..<10]
        let continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x07,           // 3-byte payload length (7 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ] + self.simpleHeadersEncoded[10...]
        let dataFrameBytes: [UInt8] = [
            0x00, 0x00, 0x08,           // 3-byte payload length (8 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            // DATA payload
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07
        ]
        let goawayFrameBytes: [UInt8] = [
            0x00, 0x00, 0x10,           // 3-byte payload length (16 bytes)
            0x07,                       // 1-byte frame type (GOAWAY)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier,
            0x00, 0x00, 0x00, 0x01,     // 4-byte last stream identifier,
            0x00, 0x00, 0x00, 0x00,     // 4-byte error code (NO_ERROR)
            
            // opaque data (8 bytes)
            0x00, 0x01, 0x02, 0x03,
            0x04, 0x05, 0x06, 0x07,
        ]
        
        var buf = self.allocator.buffer(capacity: 128)
        buf.writeBytes(settingsAckBytes)
        buf.writeBytes(headerFrameBytes)
        buf.writeBytes(continuationFrameBytes)
        buf.writeBytes(dataFrameBytes)
        buf.writeBytes(goawayFrameBytes)
        
        var dataBuf = self.allocator.buffer(capacity: 8)
        dataBuf.writeBytes(dataFrameBytes[9...])
        
        let streamID = HTTP2StreamID(1)
        let settingsAckFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.ack))
        let headersFrame = HTTP2Frame(streamID: streamID, payload: .headers(.init(headers: self.simpleHeaders)))
        let dataFrame = HTTP2Frame(streamID: streamID, payload: .data(.init(data: .byteBuffer(dataBuf), endStream: true)))
        let goawayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: streamID, errorCode: .noError, opaqueData: dataBuf))
        
        var decoder = HTTP2FrameDecoder(allocator: self.allocator, expectClientMagic: false)
        decoder.append(bytes: &buf)
        XCTAssertEqual(buf.readableBytes, 0)
        
        let frame1 = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame1)
        self.assertEqualFrames(frame1!, settingsAckFrame)
        
        let frame2 = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame2)
        self.assertEqualFrames(frame2!, headersFrame)
        
        let frame3 = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame3)
        self.assertEqualFrames(frame3!, dataFrame)
        
        let frame4 = try decoder.nextFrame()?.0
        XCTAssertNotNil(frame4)
        self.assertEqualFrames(frame4!, goawayFrame)
        
        let noFrame = try decoder.nextFrame()?.0
        XCTAssertNil(noFrame)
    }

}
