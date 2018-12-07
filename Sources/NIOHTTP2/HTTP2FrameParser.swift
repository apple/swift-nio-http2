//
//  HTTP2NativeParser.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 11/14/18.
//

import NIO
import NIOHPACK

/// A temporary item used to hold onto the HPACK encoder/decoder. Something in the real stream state engine will
/// take its place soon.
class HTTP2StreamData {
    static private var lookup: Dictionary<HTTP2StreamID, HTTP2StreamData> = [:]
    
    static func getStream(for streamID: HTTP2StreamID, allocator: ByteBufferAllocator) -> HTTP2StreamData {
        if let stream = lookup[streamID] {
            return stream
        }
        
        let stream = HTTP2StreamData(streamID: streamID, allocator: allocator)
        lookup[streamID] = stream
        return stream
    }
    
    var encoder: HPACKEncoder
    var decoder: HPACKDecoder
    
    let streamID: HTTP2StreamID
    
    init(streamID: HTTP2StreamID, allocator: ByteBufferAllocator) {
        // TODO: let's pass through a decent value for table sizes here.
        self.encoder = HPACKEncoder(allocator: allocator)
        self.decoder = HPACKDecoder(allocator: allocator)
        self.streamID = streamID
    }
    
    // internal so tests can see it.
    class func reset() {
        lookup.removeAll()
    }
}

/// Ingests HTTP/2 data and produces frames. You feed data in, and sometimes you'll get a complete frame out.
class HTTP2FrameDecoder {
    private var streamDecoders: Dictionary<HTTP2StreamID, HPACKDecoder> = [:]
    
    private enum ParserState {
        case idle
        case accumulatingData(FrameHeader, ByteBuffer)
    }
    
    private var state: ParserState = .idle
    private var allocator: ByteBufferAllocator
    private var currentHeaderFrame: HTTP2Frame? = nil
    
    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }
    
    func decode(bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        switch self.state {
        case .idle:
            return try readPotentialFrame(from: &bytes)
        case .accumulatingData(let header, var currentBytes):
            let required = header.length - currentBytes.readableBytes
            if bytes.readableBytes >= required {
                let view = bytes.viewBytes(at: bytes.readerIndex, length: required)
                currentBytes.write(bytes: view)
                bytes.moveReaderIndex(forwardBy: required)
                return try readFrame(withHeader: header, from: &currentBytes)
            } else {
                currentBytes.write(buffer: &bytes)  // consume entire input buffer
                return nil  // no frame (yet)
            }
        }
    }
    
    private func readPotentialFrame(from bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        guard let header = bytes.readFrameHeader() else {
            return nil
        }
        
        if bytes.readableBytes >= header.length {
            // we can read the entire thing already
            return try self.readFrame(withHeader: header, from: &bytes)
        } else {
            // start accumulating bytes and update our state
            var buffer = allocator.buffer(capacity: header.length)
            buffer.write(buffer: &bytes)    // consumes the bytes from the input buffer
            self.state = .accumulatingData(header, buffer)
            return nil
        }
    }
    
    private func readFrame(withHeader header: FrameHeader, from bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        assert(bytes.readableBytes >= header.length, "Buffer should contain at least \(header.length) bytes.")
        
        let flags = HTTP2Frame.FrameFlags(rawValue: header.flags)
        let streamID = HTTP2StreamID(knownID: Int32(header.rawStreamID & ~0x8000_0000))
        
        // Whatever else happens (e.g. errors, padding), we want to ensure that the input buffer
        // has had all this frame's bytes consumed when we exit. This also allows us to ignore
        // trailing padding bytes in the per-frame decoders below, and to ignore the status of
        // the input buffer if we pull out a slice on which to operate: this will ensure the right
        // output state of the input buffer.
        let frameEndIndex = bytes.readerIndex + header.length
        defer {
            bytes.moveReaderIndex(to: frameEndIndex)
        }
        
        let payload: HTTP2Frame.FramePayload
        switch header.type {
        case 0:
            // DATA frame : RFC 7540 § 6.1
            guard streamID != .rootStream else {
                // DATA frames MUST be associated with a stream. If a DATA frame is received whose
                // stream identifier field is 0x0, the recipient MUST respond with a connection error
                // (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            
            let padding: UInt8
            let dataLen: Int
            if flags.contains(.padded) {
                padding = bytes.readInteger()!
                dataLen = header.length - 1 - Int(padding)
                if dataLen <= 0 {
                    // If the length of the padding is the length of the frame payload or greater,
                    // the recipient MUST treat this as a connection error (Section 5.4.1) of type
                    // PROTOCOL_ERROR.
                    throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
                }
            } else {
                padding = 0
                dataLen = header.length
            }
            
            let buf: ByteBuffer
            if bytes.readableBytes == dataLen {
                buf = bytes
            } else {
                buf = bytes.readSlice(length: dataLen)!
            }
            
            payload = .data(.byteBuffer(buf))
            
        case 1:
            // HEADERS frame : RFC 7540 § 6.2
            guard streamID != .rootStream else {
                // HEADERS frames MUST be associated with a stream. If a HEADERS frame is received whose
                // stream identifier field is 0x0, the recipient MUST respond with a connection error
                // (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            
            let stream = HTTP2StreamData.getStream(for: streamID, allocator: self.allocator)
            var bytesToRead = header.length
            
            let padding: UInt8
            if flags.contains(.padded) {
                padding = bytes.readInteger()!
                bytesToRead -= 1
                if bytesToRead <= Int(padding) {
                    // Padding that exceeds the size remaining for the header block fragment
                    // MUST be treated as a PROTOCOL_ERROR.
                    throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
                }
            } else {
                padding = 0
            }
            
            let priorityData: HTTP2Frame.StreamPriorityData?
            if flags.contains(.priority) {
                let raw: UInt32 = bytes.readInteger()!
                priorityData = HTTP2Frame.StreamPriorityData(exclusive: (raw & 0x8000_0000 != 0),
                                                             dependency: HTTP2StreamID(knownID: Int32(raw & ~0x8000_0000)),
                                                             weight: bytes.readInteger()!)
                bytesToRead -= 5
            } else {
                priorityData = nil
            }
            
            // slice the input buffer if necessary
            let headerByteSize = bytesToRead - Int(padding)
            let headers: HPACKHeaders
            if bytes.readableBytes == headerByteSize {
                headers = try stream.decoder.decodeHeaders(from: &bytes)
            } else {
                // slice out the relevant chunk of data
                var slice = bytes.readSlice(length: headerByteSize)!
                headers = try stream.decoder.decodeHeaders(from: &slice)
            }
            
            payload = .headers(headers, priorityData)
            
        case 2:
            // PRIORITY frame : RFC 7540 § 6.3
            guard streamID != .rootStream else {
                // The PRIORITY frame always identifies a stream. If a PRIORITY frame is received
                // with a stream identifier of 0x0, the recipient MUST respond with a connection error
                // (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            guard header.length == 5 else {
                // A PRIORITY frame with a length other than 5 octets MUST be treated as a stream
                // error (Section 5.4.2) of type FRAME_SIZE_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
            
            let raw: UInt32 = bytes.readInteger()!
            let priorityData = HTTP2Frame.StreamPriorityData(exclusive: raw & 0x8000_0000 != 0,
                                                             dependency: HTTP2StreamID(knownID: Int32(raw & ~0x8000_0000)),
                                                             weight: bytes.readInteger()!)
            payload = .priority(priorityData)
            
        case 3:
            // RST_STREAM frame : RFC 7540 § 6.4
            guard streamID != .rootStream else {
                // RST_STREAM frames MUST be associated with a stream. If a RST_STREAM frame is
                // received with a stream identifier of 0x0, the recipient MUST treat this as a
                // connection error (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            guard header.length == 4 else {
                // A RST_STREAM frame with a length other than 4 octets MUST be treated as a
                // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
            
            let errcode: UInt32 = bytes.readInteger()!
            payload = .rstStream(HTTP2ErrorCode(errcode))
            
        case 4:
            // SETTINGS frame : RFC 7540 § 6.5
            guard streamID == .rootStream else {
                // SETTINGS frames always apply to a connection, never a single stream. The stream
                // identifier for a SETTINGS frame MUST be zero (0x0). If an endpoint receives a
                // SETTINGS frame whose stream identifier field is anything other than 0x0, the
                // endpoint MUST respond with a connection error (Section 5.4.1) of type
                // PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            if flags.contains(.ack) {
                guard header.length == 0 else {
                    // When [the ACK flag] is set, the payload of the SETTINGS frame MUST be empty.
                    // Receipt of a SETTINGS frame with the ACK flag set and a length field value
                    // other than 0 MUST be treated as a connection error (Section 5.4.1) of type
                    // FRAME_SIZE_ERROR.
                    throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
                }
            } else if header.length == 0 || header.length % 6 != 0 {
                // A SETTINGS frame with a length other than a multiple of 6 octets MUST be treated
                // as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
            
            var settings: [HTTP2Setting] = []
            settings.reserveCapacity(header.length / 6)
            
            var consumed = 0
            while consumed < header.length {
                // TODO: name here should be HTTP2SettingsParameter(fromNetwork:), but that's currently defined for NGHTTP2's Int32 value
                let identifier = HTTP2SettingsParameter(fromPayload: bytes.readInteger()!)
                let value: UInt32 = bytes.readInteger()!
                
                settings.append(HTTP2Setting(parameter: identifier, value: Int(value)))
                consumed += 6
            }
            
            payload = .settings(settings)
            
        case 5:
            // PUSH_PROMISE frame : RFC 7540 § 6.6
            guard streamID != .rootStream else {
                // The stream identifier of a PUSH_PROMISE frame indicates the stream it is associated with.
                // If the stream identifier field specifies the value 0x0, a recipient MUST respond with a
                // connection error (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            
            let stream = HTTP2StreamData.getStream(for: streamID, allocator: self.allocator)
            var bytesToRead = header.length
            
            let padding: UInt8
            if flags.contains(.padded) {
                padding = bytes.readInteger()!
                bytesToRead -= 1
            } else {
                padding = 0
            }
            
            let raw: UInt32 = bytes.readInteger()!
            let promisedStreamID = HTTP2StreamID(knownID: Int32(raw & ~0x8000_0000))
            bytesToRead -= 4
            
            let headerByteLen = bytesToRead - Int(padding)
            let headers: HPACKHeaders
            if bytes.readableBytes == headerByteLen {
                headers = try stream.decoder.decodeHeaders(from: &bytes)
            } else {
                // slice out the relevant chunk of data
                var slice = bytes.readSlice(length: headerByteLen)!
                headers = try stream.decoder.decodeHeaders(from: &slice)
            }
            
            payload = .pushPromise(promisedStreamID, headers)
            
        case 6:
            // PING frame : RFC 7540 § 6.7
            guard header.length == 8 else {
                // Receipt of a PING frame with a length field value other than 8 MUST be treated
                // as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
            guard streamID == .rootStream else {
                // PING frames are not associated with any individual stream. If a PING frame is
                // received with a stream identifier field value other than 0x0, the recipient MUST
                // respond with a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            
            var tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0)
            withUnsafeMutableBytes(of: &tuple) { ptr -> Void in
                bytes.readWithUnsafeReadableBytes { bytesPtr -> Int in
                    ptr.copyBytes(from: bytesPtr[0..<8])
                    return 8
                }
            }
            
            payload = .ping(HTTP2PingData(withTuple: tuple))
            
        case 7:
            // GOAWAY frame : RFC 7540 § 6.8
            guard streamID == .rootStream else {
                // The GOAWAY frame applies to the connection, not a specific stream. An endpoint
                // MUST treat a GOAWAY frame with a stream identifier other than 0x0 as a connection
                // error (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            
            guard header.length >= 8 else {
                // Must have at least 8 bytes of data (last-stream-id plus error-code).
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
            
            let raw: UInt32 = bytes.readInteger()!
            let errcode: UInt32 = bytes.readInteger()!
            
            let debugData: ByteBuffer?
            let extraLen = header.length - 8
            if extraLen > 0 {
                debugData = bytes.readSlice(length: extraLen)
            } else {
                debugData = nil
            }
            
            payload = .goAway(lastStreamID: HTTP2StreamID(knownID: Int32(raw & ~0x8000_000)),
                              errorCode: HTTP2ErrorCode(errcode), opaqueData: debugData)
            
        case 8:
            // WINDOW_UPDATE frame : RFC 7540 § 6.9
            guard header.length == 4 else {
                // A WINDOW_UPDATE frame with a length other than 4 octets MUST be treated as a
                // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
            
            let raw: UInt32 = bytes.readInteger()!
            payload = .windowUpdate(windowSizeIncrement: Int(raw & ~0x8000_0000))
            
        case 9:
            // special case, in another function
            return try self.parseContinuation(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
            
        case 10:
            // ALTSVC frame : RFC 7838 § 4
            guard header.length >= 2 else {
                // Must be at least two bytes, to contain the length of the optional 'Origin' field.
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
            
            let originLen: UInt16 = bytes.readInteger()!
            let origin: String?
            if originLen > 0 {
                origin = bytes.readString(length: Int(originLen))!
            } else {
                origin = nil
            }
            
            let fieldLen = header.length - 2 - Int(originLen)
            let value: ByteBuffer?
            if fieldLen != 0 {
                value = bytes.readSlice(length: fieldLen)!
            } else {
                value = nil
            }
            
            payload = .alternativeService(origin: origin, field: value)
            
        case 11:
            // ORIGIN frame : RFC 8336 § 2
            guard streamID == .rootStream else {
                // The ORIGIN frame MUST be sent on stream 0; an ORIGIN frame on any
                // other stream is invalid and MUST be ignored.
                return nil
            }
            
            var origins: [String] = []
            var remaining = header.length
            while remaining > 0 {
                guard remaining >= 2 else {
                    // If less than two bytes remain, this is a malformed frame.
                    throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
                }
                let originLen: UInt16 = bytes.readInteger()!
                remaining -= 2
                
                guard remaining >= Int(originLen) else {
                    // Malformed frame.
                    throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
                }
                let origin = bytes.readString(length: Int(originLen))!
                remaining -= Int(originLen)
                
                origins.append(origin)
            }
            
            payload = .origin(origins)
            
        default:
            // RFC 7540 § 4.1 https://httpwg.org/specs/rfc7540.html#FrameHeader
            //    "Implementations MUST ignore and discard any frame that has a type that is unknown."
            self.state = .idle
            bytes.moveReaderIndex(forwardBy: header.length)
            return nil
        }
        
        self.state = .idle
        let frame = HTTP2Frame(streamID: streamID, flags: flags, payload: payload)
        
        switch payload {
        case .headers where !flags.contains(.endHeaders), .pushPromise where !flags.contains(.endHeaders):
            // don't emit the frame, store it and wait for CONTINUATION frames to arrive
            self.currentHeaderFrame = frame
            return nil
        default:
            return frame
        }
    }
    
    private func parseContinuation(length: Int, streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        // CONTINUATION frame : RFC 7540 § 6.10
        guard var frame = self.currentHeaderFrame else {
            // A CONTINUATION frame MUST be preceded by a HEADERS, PUSH_PROMISE or
            // CONTINUATION frame without the END_HEADERS flag set. A recipient that
            // observes violation of this rule MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
        }
        
        let stream = HTTP2StreamData.getStream(for: streamID, allocator: self.allocator)
        
        // this just contains a header block fragment and flags
        let headers: HPACKHeaders
        if bytes.readableBytes == length {
            headers = try stream.decoder.decodeHeaders(from: &bytes)
        } else {
            var slice = bytes.readSlice(length: length)!
            headers = try stream.decoder.decodeHeaders(from: &slice)
        }
        
        switch frame.payload {
        case .headers(var currentHeaders, let priority):
            currentHeaders.addContinuation(headers)
            frame.payload = .headers(currentHeaders, priority)
            
        case .pushPromise(let streamID, var currentHeaders):
            currentHeaders.addContinuation(headers)
            frame.payload = .pushPromise(streamID, currentHeaders)
            
        default:
            // A CONTINUATION frame MUST be preceded by a HEADERS, PUSH_PROMISE or
            // CONTINUATION frame without the END_HEADERS flag set. A recipient that
            // observes violation of this rule MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
        }
        
        if flags.contains(.endHeaders) {
            // no continuations following, so emit a full frame
            frame.flags.formUnion(.endHeaders)
            self.currentHeaderFrame = nil
            return frame
        } else {
            self.currentHeaderFrame = frame
            return nil
        }
    }
}

class HTTP2FrameEncoder {
    private let allocator: ByteBufferAllocator
    
    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
    }
    
    /// Encodes the frame and optionally returns one or more blobs of data
    /// ready for the system. These would include anything of potentially flexible
    /// length, such as DATA payloads, header fragments in HEADERS or PUSH_PROMISE
    /// frames, and so on. This is to avoid manually copying chunks of data which
    /// we could just enqueue separately in sequence on the channel.
    func encode(frame: HTTP2Frame, to buf: inout ByteBuffer) throws -> [IOData] {
        // note our starting point
        let start = buf.writerIndex
        
//      +-----------------------------------------------+
//      |                 Length (24)                   |
//      +---------------+---------------+---------------+
//      |   Type (8)    |   Flags (8)   |
//      +-+-------------+---------------+-------------------------------+
//      |R|                 Stream Identifier (31)                      |
//      +=+=============================================================+
//      |                   Frame Payload (0...)                      ...
//      +---------------------------------------------------------------+
        
        // skip 24-bit length for now, we'll fill that in later
        buf.moveWriterIndex(forwardBy: 3)
        
        // 8-bit type
        buf.write(integer: frame.payload.code)
        // 8-bit flags -- we don't use padding when encoding in NIO, though
        buf.write(integer: frame.flags.subtracting(.padded).rawValue)
        // 32-bit stream identifier -- ensuring the top bit is empty
        buf.write(integer: frame.streamID.safeNetworkStreamID ?? 0)
        
        func writePayloadSize(_ size: Int) {
            var bytes: (UInt8, UInt8, UInt8)
            bytes.0 = UInt8((size & 0xff_00_00) >> 16)
            bytes.1 = UInt8((size & 0x00_ff_00) >>  8)
            bytes.2 = UInt8( size & 0x00_00_ff)
            withUnsafeBytes(of: bytes) { ptr in
                _ = buf.set(bytes: ptr, at: start)
            }
        }
        
        // frame payload follows, which depends on the frame type itself
        switch frame.payload {
        case .data(let data):
            writePayloadSize(data.readableBytes)
            return [data]
            
        case .headers(let headers, let priority):
            var payloadSize = 0
            if let priority = priority {
                // TODO: throw the proper error here, or determine if we can assume it's valid
                var dependencyRaw = UInt32(priority.dependency.networkStreamID ?? 0)
                if priority.exclusive {
                    dependencyRaw |= 0x8000_0000
                }
                buf.write(integer: dependencyRaw)
                buf.write(integer: priority.weight)
                payloadSize += 5
            }
            
            // HPACK-encoded data. Find the stream and its associated encoder/decoder
            let stream = HTTP2StreamData.getStream(for: frame.streamID, allocator: self.allocator)
            try stream.encoder.beginEncoding(allocator: self.allocator)
            try stream.encoder.append(headers: headers)
            let encoded = try stream.encoder.endEncoding()
            
            payloadSize += encoded.readableBytes
            writePayloadSize(payloadSize)
            return [.byteBuffer(encoded)]
            
        case .priority(let priorityData):
            writePayloadSize(5)
            
            var raw = UInt32(priorityData.dependency.networkStreamID ?? 0)
            if priorityData.exclusive {
                raw |= 0x8000_0000
            }
            buf.write(integer: raw)
            buf.write(integer: priorityData.weight)
            
        case .rstStream(let errcode):
            writePayloadSize(4)
            buf.write(integer: UInt32(errcode.networkCode))
            
        case .settings(let settings):
            writePayloadSize(settings.count * 6)
            for setting in settings {
                buf.write(integer: setting.parameter.networkRepresentation)
                buf.write(integer: setting._value)
            }
            
        case .pushPromise(let streamID, let headers):
            let streamVal: UInt32 = UInt32(streamID.networkStreamID ?? 0) & ~0x8000_0000
            buf.write(integer: streamVal)
            
            let stream = HTTP2StreamData.getStream(for: streamID, allocator: self.allocator)
            try stream.encoder.beginEncoding(allocator: self.allocator)
            try stream.encoder.append(headers: headers)
            let encoded = try stream.encoder.endEncoding()
            
            writePayloadSize(encoded.readableBytes + 4)
            return [.byteBuffer(encoded)]
            
        case .ping(let pingData):
            writePayloadSize(8)
            withUnsafeBytes(of: pingData.bytes) { ptr -> Void in
                buf.write(bytes: ptr)
            }
            
        case .goAway(let lastStreamID, let errorCode, let opaqueData):
            let streamVal: UInt32 = UInt32(lastStreamID.networkStreamID ?? 0) & ~0x8000_0000
            buf.write(integer: streamVal)
            buf.write(integer: UInt32(errorCode.networkCode))
            
            if let data = opaqueData {
                writePayloadSize(data.readableBytes + 8)
                return [.byteBuffer(data)]
            } else {
                writePayloadSize(8)
            }
            
        case .windowUpdate(let size):
            writePayloadSize(4)
            buf.write(integer: UInt32(size) & ~0x8000_0000)
            
        case .alternativeService(let origin, let field):
            let initial = buf.writerIndex
            
            if let org = origin {
                buf.moveWriterIndex(forwardBy: 2)
                let start = buf.writerIndex
                buf.write(string: org)
                buf.set(integer: UInt16(buf.writerIndex - start), at: initial)
            } else {
                buf.write(integer: UInt16(0))
            }
            
            if let value = field {
                writePayloadSize(buf.writerIndex - initial + value.readableBytes)
                return [.byteBuffer(value)]
            } else {
                writePayloadSize(buf.writerIndex - initial)
            }
            
        case .origin(let origins):
            let initial = buf.writerIndex
            for origin in origins {
                let sizeLoc = buf.writerIndex
                buf.moveWriterIndex(forwardBy: 2)
                
                let start = buf.writerIndex
                buf.write(string: origin)
                buf.set(integer: UInt16(buf.writerIndex - start), at: sizeLoc)
            }
            
            writePayloadSize(buf.writerIndex - initial)
        }
        
        // all bytes to write are in the provided buffer now
        return []
    }
}

fileprivate struct FrameHeader {
    var length: Int     // actually 24-bits
    var type: UInt8
    var flags: UInt8
    var rawStreamID: UInt32 // including reserved bit
}

fileprivate extension ByteBuffer {
    mutating func readFrameHeader() -> FrameHeader? {
        guard self.readableBytes >= 9 else {
            return nil
        }
        
        let lenBytes: [UInt8] = self.readBytes(length: 3)!
        let len = Int(lenBytes[0]) >> 16 | Int(lenBytes[1]) >> 8 | Int(lenBytes[2])
        let type: UInt8 = self.readInteger()!
        let flags: UInt8 = self.readInteger()!
        let rawStreamID: UInt32 = self.readInteger()!
        
        return FrameHeader(length: len, type: type, flags: flags, rawStreamID: rawStreamID)
    }
}
