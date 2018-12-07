//
//  HTTP2FrameParserTests.swift
//  NIOHTTP2Tests
//
//  Created by Jim Dovey on 12/6/18.
//

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
    
    let continuationHeaders = HPACKHeaders([
        (":method", "GET"),
        (":scheme", "http"),
        (":path", "/"),
        (":authority", "www.example.com"),
        ("date", "Mon, 21 Oct 2013 20:13:21 GMT")
    ])
    let continuationHeadersEncoded: [UInt8] = [0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x31, 0x20, 0x47, 0x4d, 0x54]
    
    override func tearDown() {
        HTTP2StreamData.reset()
    }
    
    // MARK: - Utilities
    
    private func byteBuffer<C : ContiguousCollection>(withBytes bytes: C, extraCapacity: Int = 0) -> ByteBuffer where C.Element == UInt8 {
        var buf = allocator.buffer(capacity: bytes.count + extraCapacity)
        buf.write(bytes: bytes)
        return buf
    }
    
    private func byteBuffer(withStaticString string: StaticString) -> ByteBuffer {
        var buf = allocator.buffer(capacity: string.utf8CodeUnitCount)
        buf.write(staticString: string)
        return buf
    }
    
    private func assertEqualFrames(_ frame1: HTTP2Frame, _ frame2: HTTP2Frame,
                                   file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(frame1.streamID, frame2.streamID, "StreamID mismatch: \(frame1.streamID) != \(frame2.streamID)",
            file: file, line: line)
        XCTAssertEqual(frame1.flags, frame2.flags, "Flags mismatch: \(frame1.flags) != \(frame2.flags)",
            file: file, line: line)
        
        switch (frame1.payload, frame2.payload) {
        case let (.data(l), .data(r)):
            switch (l, r) {
            case let (.byteBuffer(lb), .byteBuffer(rb)):
                XCTAssertEqual(lb, rb, "Data bytes mismatch: \(lb) != \(rb)", file: file, line: line)
            default:
                XCTFail("We're not testing with file regions!", file: file, line: line)
            }
            
        case let (.headers(lh, lp), .headers(rh, rp)):
            XCTAssertEqual(lh, rh, "Headers mismatch: \(lh) != \(rh)", file: file, line: line)
            XCTAssertEqual(lp, rp, "Priority mismatch: \(String(describing: lp)) != \(String(describing: rp))",
                file: file, line: line)
            
        case let (.priority(lp), .priority(rp)):
            XCTAssertEqual(lp, rp, "Priority mismatch: \(lp) != \(rp)", file: file, line: line)
            
        case let (.rstStream(le), .rstStream(re)):
            XCTAssertEqual(le, re, "Error mismatch: \(le) != \(re)", file: file, line: line)
            
        case let (.settings(ls), .settings(rs)):
            XCTAssertEqual(ls, rs, "Settings mismatch: \(ls) != \(rs)", file: file, line: line)
            
        case let (.pushPromise(ls, lh), .pushPromise(rs, rh)):
            XCTAssertEqual(ls, rs, "Stream ID mismatch: \(ls) != \(rs)", file: file, line: line)
            XCTAssertEqual(lh, rh, "Headers mismatch: \(lh) != \(rh)", file: file, line: line)
            
        case let (.ping(lp), .ping(rp)):
            XCTAssertEqual(lp, rp, "Ping data mismatch: \(lp) != \(rp)", file: file, line: line)
            
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
                                  file: StaticString = #file, line: UInt = #line) throws {
        let initialByteIndex = bytes.readerIndex
        let totalFrameSize = bytes.readableBytes
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        let frame: HTTP2Frame! = try decoder.decode(bytes: &bytes)
        
        // should return a frame
        XCTAssertNotNil(frame)
        
        // should consume all the bytes
        XCTAssertEqual(bytes.readableBytes, 0)
        
        self.assertEqualFrames(frame, expectedFrame, file: file, line: line)
        
        if totalFrameSize > 9 {
            // Now try again with the frame arriving in two separate chunks.
            bytes.moveReaderIndex(to: initialByteIndex)
            bytes.moveReaderIndex(to: initialByteIndex)
            var first = bytes.readSlice(length: 9)!
            var second = bytes
            
            let nilFrame = try decoder.decode(bytes: &first)
            XCTAssertNil(nilFrame)
            let realFrame: HTTP2Frame! = try decoder.decode(bytes: &second)
            XCTAssertNotNil(realFrame)
            
            self.assertEqualFrames(realFrame, expectedFrame, file: file, line: line)
        }
    }
    
    // MARK: - DATA frames

    func testDataFrameDecodingNoPadding() throws {
        let payload = byteBuffer(withStaticString: "Hello, World!")
        let expectedFrame = HTTP2Frame(payload: .data(.byteBuffer(payload)),
                                       flags: [.endStream],
                                       streamID: HTTP2StreamID(knownID: 1))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0d,           // 3-byte payload length (13 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: payload.readableBytes)
        buf.write(bytes: payload.readableBytesView)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testDataFrameDecodingWithPadding() throws {
        let payload = byteBuffer(withStaticString: "Hello, World!")
        let expectedFrame = HTTP2Frame(payload: .data(.byteBuffer(payload)),
                                       flags: [.endStream, .padded],
                                       streamID: HTTP2StreamID(knownID: 1))
        
        // Unpadded frame is 22 bytes. When we add padding, we get +1 byte for pad length, +1 byte of padding, for 24 bytes total
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0f,           // 3-byte payload length (15 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x09,                       // 1-byte flags (PADDED, END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x01,                       // 1-byte padding length
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: payload.readableBytes + 1)
        buf.write(bytes: payload.readableBytesView)
        buf.write(integer: UInt8(0))
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testDataFrameEncoding() throws {
        let payload = "Hello, World!"
        let streamID = HTTP2StreamID(knownID: 1)
        var payloadBytes = allocator.buffer(capacity: payload.count)
        payloadBytes.write(string: payload)
        
        let frame = HTTP2Frame(payload: .data(.byteBuffer(payloadBytes)), flags: [.endStream], streamID: streamID)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x0d,           // 3-byte payload length (13 bytes)
            0x00,                       // 1-byte frame type (DATA)
            0x01,                       // 1-byte flags (END_STREAM)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertEqual(extraBufs.count, 1, "Should have returned a single extra buf")
        XCTAssertEqual(buf, expectedBufContent)
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
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        XCTAssertThrowsError(try decoder.decode(bytes: &badFrameBuf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
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
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
    }
    
    // MARK: - HEADERS frames
    
    func testHeadersFrameDecodingNoPriorityNoPadding() throws {
        let expectedFrame = HTTP2Frame(payload: .headers(self.simpleHeaders, nil),
                                       flags: [.endHeaders],
                                       streamID: HTTP2StreamID(knownID: 1))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x11,           // 3-byte payload length (17 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.write(bytes: self.simpleHeadersEncoded)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testHeadersFrameDecodingNoPriorityWithPadding() throws {
        let expectedFrame = HTTP2Frame(payload: .headers(self.simpleHeaders, nil),
                                       flags: [.endHeaders, .padded],
                                       streamID: HTTP2StreamID(knownID: 1))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x0c,                       // 1-byte flags (PADDED, END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x03,                       // 1-byte pad length
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count + 4)
        buf.write(bytes: self.simpleHeadersEncoded)
        buf.write(bytes: [UInt8](repeating: 0, count: 3))
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testHeadersFrameDecodingWithPriorityNoPadding() throws {
        let priority = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(knownID: 1), weight: 139)
        let expectedFrame = HTTP2Frame(payload: .headers(self.simpleHeaders, priority),
                                       flags: [.endHeaders, .priority],
                                       streamID: HTTP2StreamID(knownID: 3))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x16,           // 3-byte payload length (22 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x24,                       // 1-byte flags (END_HEADERS, PRIORITY)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.write(bytes: self.simpleHeadersEncoded)
        
        try assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testHeadersFrameDecodingWithPriorityWithPadding() throws {
        let priority = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(knownID: 1), weight: 139)
        let expectedFrame = HTTP2Frame(payload: .headers(self.simpleHeaders, priority),
                                       flags: [.endHeaders, .priority, .padded],
                                       streamID: HTTP2StreamID(knownID: 3))
        
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
        buf.write(bytes: self.simpleHeadersEncoded)
        buf.write(bytes: [UInt8](repeating: 0, count: 8))
        
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
        buf.write(bytes: self.simpleHeadersEncoded)
        buf.write(bytes: [UInt8](repeating: 0, count: 3))
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // should fail if the stream is zero
        buf.set(integer: UInt8(0), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
        
        buf.moveReaderIndex(to: 0)
        buf.set(integer: UInt8(1), at: 8)
        
        // pad size that exceeds payload size is illegal
        buf.set(integer: UInt8(200), at: 9)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
    }
    
    func testHeadersFrameEncodingNoPriority() throws {
        let streamID = HTTP2StreamID(knownID: 1)
        let encodedHeaders = self.byteBuffer(withBytes: simpleHeadersEncoded)
        
        let frame = HTTP2Frame(payload: .headers(self.simpleHeaders, nil), flags: [.endHeaders], streamID: streamID)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x11,           // 3-byte payload length (17 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertEqual(extraBufs.count, 1, "Should have returned a single extra buf")
        XCTAssertEqual(extraBufs.first!, .byteBuffer(encodedHeaders), "Encoded headers did not match expectation.")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    func testHeadersFrameEncodingWithPriority() throws {
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(knownID: 1), weight: 139)
        let streamID = HTTP2StreamID(knownID: 3)
        let encodedHeaders = self.byteBuffer(withBytes: simpleHeadersEncoded)
        
        let frame = HTTP2Frame(payload: .headers(self.simpleHeaders, priorityData), flags: [.endHeaders, .priority], streamID: streamID)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x16,           // 3-byte payload length (22 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x24,                       // 1-byte flags (END_HEADERS, PRIORITY)
            0x00, 0x00, 0x00, 0x03,     // 4-byte stream identifier
            0x80, 0x00, 0x00, 0x01,     // 4-byte stream dependency (top bit = exclusive)
            0x8b,                       // 1-byte weight (139)
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertEqual(extraBufs.count, 1, "Should have returned a single extra buf")
        XCTAssertEqual(extraBufs.first!, .byteBuffer(encodedHeaders), "Encoded headers did not match expectation.")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - PRIORITY frames
    
    func testPriorityFrameDecoding() throws {
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(knownID: 1), weight: 139)
        let expectedFrame = HTTP2Frame(payload: .priority(priorityData), flags: [], streamID: HTTP2StreamID(knownID: 3))
        
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
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // cannot be on root stream
        buf.set(integer: UInt8(0), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.set(integer: UInt8(3), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // must have a size of 5 octets
        buf.set(integer: UInt8(6), at: 2)
        buf.write(integer: UInt8(0))        // append an extra byte so we read it all
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a frame size error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .frameSizeError else {
                XCTFail("Should have thrown a connection error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testPriorityFrameEncoding() throws {
        let streamID = HTTP2StreamID(knownID: 3)
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: true, dependency: HTTP2StreamID(knownID: 1), weight: 139)
        let frame = HTTP2Frame(payload: .priority(priorityData), flags: [], streamID: streamID)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
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
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should not have returned extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - RST_STREAM frames
    
    func testResetStreamFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(payload: .rstStream(.protocolError), flags: [], streamID: HTTP2StreamID(knownID: 1))
        
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
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // cannot be on root stream
        buf.set(integer: UInt8(0), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.set(integer: UInt8(1), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // must have a size of 4 octets
        buf.set(integer: UInt8(5), at: 2)
        buf.write(integer: UInt8(0))        // append an extra byte so we read it all
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a frame size error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .frameSizeError else {
                XCTFail("Should have thrown a connection error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testResetStreamFrameEncoding() throws {
        let streamID = HTTP2StreamID(knownID: 1)
        let frame = HTTP2Frame(payload: .rstStream(.protocolError), flags: [], streamID: streamID)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x03,                       // 1-byte frame type (RST_STREAM)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x01,     // 4-byte error (PROTOCOL_ERROR = 0x1)
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should not have returned extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - SETTINGS frames
    
    func testSettingsFrameDecoding() throws {
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .headerTableSize, value: 256),
            HTTP2Setting(parameter: .initialWindowSize, value: 32_768),
            HTTP2Setting(parameter: .maxHeaderListSize, value: 2_048)
        ]
        let expectedFrame = HTTP2Frame(payload: .settings(settings), flags: [], streamID: .rootStream)
        
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
    
    func testSettingsFrameDecodingWithUnknownItems() throws {
        let settings: [HTTP2Setting] = [
            HTTP2Setting(parameter: .headerTableSize, value: 256),
            HTTP2Setting(parameter: .initialWindowSize, value: 32_768),
            HTTP2Setting(parameter: HTTP2SettingsParameter(fromNetwork: 0x99), value: 32_768),
            HTTP2Setting(parameter: .maxHeaderListSize, value: 2_048)
        ]
        let expectedFrame = HTTP2Frame(payload: .settings(settings), flags: [], streamID: .rootStream)
        
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
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // MUST be sent on the root stream
        buf.set(integer: UInt8(1), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.set(integer: UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // size must be a multiple of 6 octets
        buf.set(integer: UInt8(19), at: 2)
        buf.write(integer: UInt8(0))        // append an extra byte so we read it all
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a frame size error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .frameSizeError else {
                XCTFail("Should have thrown a connection error of type FRAME_SIZE_ERROR")
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
        let frame = HTTP2Frame(payload: .settings(settings), flags: [], streamID: .rootStream)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
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
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should not have returned extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    func testSettingsAckFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(payload: .settings([]), flags: [.ack], streamID: .rootStream)
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
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // MUST be sent on the root stream
        buf.set(integer: UInt8(1), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.set(integer: UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // size must be 0 for ACKs
        buf.set(integer: UInt8(1), at: 2)
        buf.write(integer: UInt8(0))        // append an extra byte so we read it all
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a frame size error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .frameSizeError else {
                XCTFail("Should have thrown a connection error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testSettingsAckFrameEncoding() throws {
        let frame = HTTP2Frame(payload: .settings([]), flags: [.ack], streamID: .rootStream)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x00,           // 3-byte payload length (0 bytes)
            0x04,                       // 1-byte frame type (SETTINGS)
            0x01,                       // 1-byte flags (ACK)
            0x00, 0x00, 0x00, 0x00,     // 4-byte stream identifier
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should not have returned extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - PUSH_PROMISE frames
    
    func testPushPromiseFrameDecodingNoPadding() throws {
        let streamID = HTTP2StreamID(knownID: 3)
        let expectedFrame = HTTP2Frame(payload: .pushPromise(streamID, self.simpleHeaders),
                                       flags: [.endHeaders],
                                       streamID: HTTP2StreamID(knownID: 1))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.write(bytes: self.simpleHeadersEncoded)
        
        try self.assertReadsFrame(from: &buf, matching: expectedFrame)
    }
    
    func testPushPromiseFrameDecodingWithPadding() throws {
        let streamID = HTTP2StreamID(knownID: 3)
        let expectedFrame = HTTP2Frame(payload: .pushPromise(streamID, self.simpleHeaders),
                                       flags: [.endHeaders, .padded],
                                       streamID: HTTP2StreamID(knownID: 1))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x17,           // 3-byte payload length (23 bytes) (32 total)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x0c,                       // 1-byte flags (END_HEADERS, PADDED)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x01,                       // 1-byte pad size
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.write(bytes: self.simpleHeadersEncoded)
        buf.write(integer: UInt8(0))
        
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
        buf.write(bytes: self.simpleHeadersEncoded)
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // MUST NOT be sent on the root stream
        buf.set(integer: UInt8(0), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.set(integer: UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
    }
    
    func testPushPromiseFrameEncoding() throws {
        let streamID = HTTP2StreamID(knownID: 3)
        let frame = HTTP2Frame(payload: .pushPromise(streamID, self.simpleHeaders),
                               flags: [.endHeaders], streamID: HTTP2StreamID(knownID: 1))
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x15,           // 3-byte payload length (21 bytes)
            0x05,                       // 1-byte frame type (PUSH_PROMISE)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x03,     // 4-byte promised stream identifier
        ]
        let expectedBufContent = self.byteBuffer(withBytes: frameBytes)
        let encodedHeaders = self.byteBuffer(withBytes: self.simpleHeadersEncoded)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertEqual(extraBufs.count, 1, "Should return 1 extra buf")
        XCTAssertEqual(buf, expectedBufContent)
        XCTAssertEqual(extraBufs.first!, .byteBuffer(encodedHeaders), "Encoded headers did not match expectation.")
    }
    
    // MARK: - PING frames
    
    func testPingFrameDecoding() throws {
        let pingData = HTTP2PingData(withTuple: (0,1,2,3,4,5,6,7))
        let expectedFrame = HTTP2Frame(payload: .ping(pingData), flags: [], streamID: .rootStream)
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
        let expectedFrame = HTTP2Frame(payload: .ping(pingData), flags: [.ack], streamID: .rootStream)
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
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // MUST NOT be associated with a stream.
        buf.set(integer: UInt8(1), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
        buf.set(integer: UInt8(0), at: 8)
        buf.moveReaderIndex(to: 0)
        
        // length MUST be 8 octets
        buf.set(integer: UInt8(7), at: 2)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a frame size error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .frameSizeError else {
                XCTFail("Should have thrown a connection error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testPingFrameEncoding() throws {
        let pingData = HTTP2PingData(withTuple: (0,1,2,3,4,5,6,7))
        let frame = HTTP2Frame(payload: .ping(pingData), flags: [], streamID: .rootStream)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
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
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should not return any extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    func testPingAckFrameEncoding() throws {
        let pingData = HTTP2PingData(withTuple: (0,1,2,3,4,5,6,7))
        let frame = HTTP2Frame(payload: .ping(pingData), flags: [.ack], streamID: .rootStream)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
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
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should not return any extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - GOAWAY frame
    
    func testGoAwayFrameDecoding() throws {
        let dataBytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let lastStreamID = HTTP2StreamID(knownID: 1)
        let opaqueData = self.byteBuffer(withBytes: dataBytes)
        let expectedFrame = HTTP2Frame(payload: .goAway(lastStreamID: lastStreamID, errorCode: .frameSizeError, opaqueData: opaqueData),
                                       flags: [], streamID: .rootStream)
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
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // MUST NOT be associated with a stream.
        buf.set(integer: UInt8(1), at: 8)
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a protocol error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .protocolError else {
                XCTFail("Should have thrown a connection error of type PROTOCOL_ERROR")
                return
            }
        })
    }
    
    func testGoAwayFrameEncodingWithOpaqueData() throws {
        let dataBytes: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let lastStreamID = HTTP2StreamID(knownID: 1)
        let opaqueData = self.byteBuffer(withBytes: dataBytes)
        let frame = HTTP2Frame(payload: .goAway(lastStreamID: lastStreamID, errorCode: .frameSizeError, opaqueData: opaqueData),
                               flags: [], streamID: .rootStream)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
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
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertEqual(extraBufs.count, 1, "Should return 1 extra buf containing extra data")
        XCTAssertEqual(buf, expectedBufContent)
        XCTAssertEqual(extraBufs.first!, .byteBuffer(opaqueData))
    }
    
    func testGoAwayFrameEncodingWithNoOpaqueData() throws {
        let lastStreamID = HTTP2StreamID(knownID: 1)
        let frame = HTTP2Frame(payload: .goAway(lastStreamID: lastStreamID, errorCode: .frameSizeError, opaqueData: nil),
                               flags: [], streamID: .rootStream)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
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
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should return no extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - WINDOW_UPDATE frame
    
    func testWindowUpdateFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(payload: .windowUpdate(windowSizeIncrement: 5), flags: [], streamID: HTTP2StreamID(knownID: 1))
        
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
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // must have a size of 4 octets
        buf.set(integer: UInt8(5), at: 2)
        buf.write(integer: UInt8(0))        // append an extra byte so we read it all
        XCTAssertThrowsError(try decoder.decode(bytes: &buf), "Should throw a frame size error", { err in
            guard let connErr = err as? NIOHTTP2Errors.ConnectionError, connErr.code == .frameSizeError else {
                XCTFail("Should have thrown a connection error of type FRAME_SIZE_ERROR")
                return
            }
        })
    }
    
    func testWindowUpdateFrameEncoding() throws {
        let streamID = HTTP2StreamID(knownID: 1)
        let frame = HTTP2Frame(payload: .windowUpdate(windowSizeIncrement: 5), flags: [], streamID: streamID)
        let encoder = HTTP2FrameEncoder(allocator: self.allocator)
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x04,           // 3-byte payload length (4 bytes)
            0x08,                       // 1-byte frame type (WINDOW_UPDATE)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
            0x00, 0x00, 0x00, 0x05,     // window size adjustment
        ]
        let expectedBufContent = byteBuffer(withBytes: frameBytes)
        var buf = self.allocator.buffer(capacity: expectedBufContent.readableBytes)
        
        let extraBufs = try encoder.encode(frame: frame, to: &buf)
        XCTAssertTrue(extraBufs.isEmpty, "Should not have returned extra bufs")
        XCTAssertEqual(buf, expectedBufContent)
    }
    
    // MARK: - CONTINUATION frames
    
    func testContinuationFrameDecoding() throws {
        let expectedFrame = HTTP2Frame(payload: .headers(self.continuationHeaders, nil),
                                       flags: [.endHeaders],
                                       streamID: HTTP2StreamID(knownID: 1))
        
        let frameBytes: [UInt8] = [
            0x00, 0x00, 0x11,           // 3-byte payload length (17 bytes)
            0x01,                       // 1-byte frame type (HEADERS)
            0x00,                       // 1-byte flags (none)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        var buf = byteBuffer(withBytes: frameBytes, extraCapacity: self.simpleHeadersEncoded.count)
        buf.write(bytes: self.simpleHeadersEncoded)
        
        let decoder = HTTP2FrameDecoder(allocator: self.allocator)
        
        // should return nothing thus far and wait for CONTINUATION frames and an END_HEADERS flag
        XCTAssertNil(try decoder.decode(bytes: &buf))
        
        // should consume all the bytes
        XCTAssertEqual(buf.readableBytes, 0)
        buf.clear()
        
        let continuationFrameBytes: [UInt8] = [
            0x00, 0x00, 0x1f,           // 3-byte payload length (31 bytes)
            0x09,                       // 1-byte frame type (CONTINUATION)
            0x04,                       // 1-byte flags (END_HEADERS)
            0x00, 0x00, 0x00, 0x01,     // 4-byte stream identifier
        ]
        buf.write(bytes: continuationFrameBytes)
        buf.write(bytes: self.continuationHeadersEncoded)
        
        // This should now yield a HEADERS frame containing the complete set of headers
        let frame: HTTP2Frame! = try decoder.decode(bytes: &buf)
        XCTAssertNotNil(frame)
        
        self.assertEqualFrames(frame, expectedFrame)
    }

}
