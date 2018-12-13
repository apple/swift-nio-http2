//
//  HTTP2NativeParser.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 11/14/18.
//

import NIO
import NIOHPACK

/// Ingests HTTP/2 data and produces frames. You feed data in, and sometimes you'll get a complete frame out.
struct HTTP2FrameDecoder {
    private var headerDecoder: HPACKDecoder
    
    private struct IgnoredFrame : Error {}
    
    private enum ParserState {
        /// We are not in the middle of parsing any frames.
        case idle
        
        /// We are accumulating payload bytes for a single frame.
        case accumulatingData(FrameHeader, ByteBuffer)
        
        /// We are receiving bytes from a DATA frame payload, and are emitting multiple DATA frames,
        /// one for each chunk of bytes we see here.
        case simulatingDataFrames(originalHeader: FrameHeader, padding: UInt8, remainingBytes: Int)
        
        /// We are accumulating a CONTINUATION frame.
        case accumulatingContinuationPayload(originalHeader: FrameHeader, headerBytes: ByteBuffer, continuationHeader: FrameHeader, continuationBytes: ByteBuffer)
        
        // We are waiting for a new CONTINUATION frame to arrive.
        case accumulatingHeaderBlockFragments(FrameHeader, ByteBuffer)
    }
    
    private var isIdle: Bool {
        switch self.state {
        case .idle:
            return true
        default:
            return false
        }
    }
    
    private var state: ParserState = .idle
    private var allocator: ByteBufferAllocator
    
    /// Creates a new HTTP2 frame decoder.
    ///
    /// - parameter allocator: A `ByteBufferAllocator` used when accumulating blocks of data
    ///                        and decoding headers.
    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
        self.headerDecoder = HPACKDecoder(allocator: allocator)
    }
    
    
    /// Reads at most one frame's worth of bytes from the input buffer, and returns a decoded
    /// frame if one has been completely received.
    ///
    /// The method's effect on the input buffer and its return value depend on the content of
    /// the buffer:
    ///
    /// - If the input buffer contains more bytes beyond the current frame, those bytes will
    ///   remain in the buffer; you may continue calling `decode(bytes:)` until the buffer is
    ///   empty, or until its size does not change.
    /// - If a given buffer does not contain a complete frame header (9 bytes), this method
    ///   will take no action, and the buffer will remain unchanged when the method returns.
    /// - If the buffer does not contain an entire frame including payload, it will be cached
    ///   internally by the decoder, and the next call to `decode(bytes:)` will append any
    ///   new bytes to that cache in an effort to complete that frame's payload.
    /// - When enough bytes to decode an entire frame have been accumulated or provided, the
    ///   resultant frame will be returned. If the entire frame and its payload have not yet
    ///   been accumulated, `nil` will be returned.
    /// - If we gather enough bytes to construct a frame, but that frame is invalid or malformed,
    ///   we consume all the bytes and throw the error specified in RFC 7540.
    ///
    /// - note: The HTTP/2 protocol specifies that unknown frame types should be ignored. This
    ///         implementation will silently collect and drop all bytes associated with frames
    ///         whose type is unrecognized; it will not throw an error or otherwise provide
    ///         those bytes for processing elsewhere.
    ///
    /// - Parameter bytes: Raw bytes received, ready to decode. On exit, any consumed bytes
    ///                    will no longer be in the buffer.
    /// - Returns: A decoded frame type or `nil` if more bytes are needed to complete the frame.
    /// - Throws: Errors specified by RFC 7540 § 6 for mis-sized frames or incorrect
    ///           stream/connection association.
    mutating func decode(bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        switch self.state {
        case .idle:
            return try self.readPotentialFrame(from: &bytes)
        case .accumulatingData(let header, var currentBytes):
            let required = header.length - currentBytes.readableBytes
            if bytes.readableBytes >= required {
                var slice = bytes.readSlice(length: required)!
                currentBytes.write(buffer: &slice)
                return try self.readFrame(withHeader: header, from: &currentBytes)
            } else {
                currentBytes.write(buffer: &bytes)  // consume entire input buffer
                return nil  // no frame (yet)
            }
        case .simulatingDataFrames(let header, let padding, let remaining):
            let streamID = HTTP2StreamID(knownID: Int32(header.rawStreamID & ~0x8000_0000))
            let flags = HTTP2Frame.FrameFlags(rawValue: header.flags)
            if bytes.readableBytes < remaining {
                // ping out a fake DATA frame containing these bytes, without the END_STREAM flag being set
                let slice = bytes
                bytes.clear()   // consuming all the bytes
                self.state = .simulatingDataFrames(originalHeader: header, padding: padding, remainingBytes: remaining - slice.readableBytes)
                return HTTP2Frame(streamID: streamID, flags: [], payload: .data(.byteBuffer(slice)))
            } else {
                // we have all remaining bytes, so we include .endStream bit (if set in original frame)
                var slice = bytes.readSlice(length: remaining)!
                if padding > 0 {
                    // trim padding from the bytes we attach to the parsed frame
                    slice.moveWriterIndex(to: slice.writerIndex - Int(padding))
                }
                self.state = .idle
                return HTTP2Frame(streamID: streamID, flags: flags, payload: .data(.byteBuffer(slice)))
            }
        case .accumulatingHeaderBlockFragments(let header, var buffer):
            // special case since we only accept CONTINUATION frames in this state
            guard let continuationHeader = bytes.readFrameHeader() else {
                return nil      // don't have another header yet
            }
            
            guard continuationHeader.type == 0x9 /* CONTINUATION */ else {
                // invalid frame: this is a connection error
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            
            let flags = HTTP2Frame.FrameFlags(rawValue: continuationHeader.flags)
            
            var cbytes: ByteBuffer
            if bytes.readableBytes >= continuationHeader.length {
                cbytes = bytes.readSlice(length: continuationHeader.length)!
                buffer.write(buffer: &cbytes)
                
                if (flags.contains(.endHeaders)) {
                    // we're done: send out a frame
                    return try self.emitSyntheticHeadersFrame(header, bytes: &buffer)
                } else {
                    self.state = .accumulatingHeaderBlockFragments(header, buffer)
                }
            } else {
                cbytes = bytes
                bytes.clear()
                self.state = .accumulatingContinuationPayload(originalHeader: header, headerBytes: buffer, continuationHeader: continuationHeader, continuationBytes: cbytes)
            }
            return nil  // no frame to return yet
            
        case .accumulatingContinuationPayload(let originalHeader, var headerPayload, let continuationHeader, var continuationBytes):
            let required = continuationHeader.length - continuationBytes.readableBytes
            if bytes.readableBytes >= required {
                var slice = bytes.readSlice(length: required)!
                headerPayload.write(buffer: &continuationBytes)
                headerPayload.write(buffer: &slice)
                
                // pretend it's one big HEADERS or PUSH_PROMISE frame
                return try self.emitSyntheticHeadersFrame(originalHeader, bytes: &headerPayload)
            } else {
                continuationBytes.write(buffer: &bytes)
                return nil
            }
        }
    }
    
    private mutating func emitSyntheticHeadersFrame(_ originalHeader: FrameHeader, bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        let newHeader = FrameHeader(length: bytes.readableBytes, type: originalHeader.type,
                                    flags: originalHeader.flags | HTTP2Frame.FrameFlags.endHeaders.rawValue,
                                    rawStreamID: originalHeader.rawStreamID)
        return try self.readFrame(withHeader: newHeader, from: &bytes)      // pretend it's one big HEADERS or PUSH_PROMISE frame
    }
    
    private mutating func readPotentialFrame(from bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        assert(self.isIdle)
        guard let header = bytes.readFrameHeader() else {
            return nil
        }
        
        if bytes.readableBytes >= header.length {
            // we can read the entire thing already
            return try self.readFrame(withHeader: header, from: &bytes)
        } else if header.type != 0 /* DATA frame */ {
            // start accumulating bytes and update our state
            var buffer = allocator.buffer(capacity: header.length)
            buffer.write(buffer: &bytes)    // consumes the bytes from the input buffer
            self.state = .accumulatingData(header, buffer)
            return nil
        } else {
            if bytes.readableBytes == 0 {
                // we only have the header of a DATA frame. Don't emit a frame, but keep the header around
                // to synthesize more once we have the data.
                if header.flags & 0x08 != 0 {
                    // it's padded. We can't enter .simulatingDataFrames without knowing our pad length, so
                    // work around this by un-reading the header bytes and returning nil.
                    bytes.moveReaderIndex(to: bytes.readerIndex - 9)
                } else {
                    // no padding to read, so everything to follow is payload: just enter simulation state
                    // with all bytes remaining.
                    self.state = .simulatingDataFrames(originalHeader: header, padding: 0, remainingBytes: header.length)
                }
                
                return nil
            }
            
            // Received a partial DATA frame: return current bytes as a single frame, then simulate
            // further frames as more of the payload arrives
            let streamID = HTTP2StreamID(knownID: Int32(header.rawStreamID & ~0x8000_0000))
            guard streamID != .rootStream else {
                // DATA frames MUST be associated with a stream. If a DATA frame is received whose
                // stream identifier field is 0x0, the recipient MUST respond with a connection error
                // (Section 5.4.1) of type PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
            
            var slice = bytes
            let consumed = slice.readableBytes
            bytes.clear()       // consumed all the bytes
            
            let flags = HTTP2Frame.FrameFlags(rawValue: header.flags)
            let padding: UInt8
            if flags.contains(.padded) {
                padding = slice.readInteger()!
            } else {
                padding = 0
            }
            self.state = .simulatingDataFrames(originalHeader: header, padding: padding, remainingBytes: header.length - consumed)
            
            // NB: our synthetic frames never claim padding, nor are they (by definition) a stream end
            return HTTP2Frame(streamID: streamID, flags: [], payload: .data(.byteBuffer(slice)))
        }
    }
    
    private mutating func readFrame(withHeader header: FrameHeader, from bytes: inout ByteBuffer) throws -> HTTP2Frame? {
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
        do {
            switch header.type {
            case 0:
                payload = try self.parseDataFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
            case 1:
                if flags.contains(.endHeaders) {
                    payload = try self.parseHeadersFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
                } else {
                    let slice = bytes.readSlice(length: header.length)!
                    self.state = .accumulatingHeaderBlockFragments(header, slice)
                    return nil
                }
            case 2:
                payload = try self.parsePriorityFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 3:
                payload = try self.parseRstStreamFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 4:
                payload = try self.parseSettingsFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
            case 5:
                if flags.contains(.endHeaders) {
                    payload = try self.parsePushPromiseFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
                } else {
                    // don't emit the frame, store it and wait for CONTINUATION frames to arrive
                    let slice = bytes.readSlice(length: header.length)!
                    self.state = .accumulatingHeaderBlockFragments(header, slice)
                    return nil
                }
            case 6:
                payload = try self.parsePingFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 7:
                payload = try self.parseGoAwayFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 8:
                payload = try self.parseWindowUpdateFramePayload(length: header.length, bytes: &bytes)
            case 9:
                // CONTINUATION frame should never be found here -- if they are, they're out of sequence
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            case 10:
                payload = try self.parseAltSvcFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 11:
                payload = try self.parseOriginFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            default:
                // RFC 7540 § 4.1 https://httpwg.org/specs/rfc7540.html#FrameHeader
                //    "Implementations MUST ignore and discard any frame that has a type that is unknown."
                throw IgnoredFrame()
            }
        } catch _ as IgnoredFrame {
            self.state = .idle
            bytes.moveReaderIndex(forwardBy: header.length)
            return nil
        } catch _ as NIOHPACKError {
            // convert into a connection error of type COMPRESSION_ERROR
            throw NIOHTTP2Errors.ConnectionError(code: .compressionError)
        }
        
        self.state = .idle
        return HTTP2Frame(streamID: streamID, flags: flags, payload: payload)
    }
    
    private func parseDataFramePayload(length: Int, streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
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
            dataLen = length - 1 - Int(padding)
            if dataLen <= 0 {
                // If the length of the padding is the length of the frame payload or greater,
                // the recipient MUST treat this as a connection error (Section 5.4.1) of type
                // PROTOCOL_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
            }
        } else {
            padding = 0
            dataLen = length
        }
        
        let buf: ByteBuffer
        if bytes.readableBytes == dataLen {
            buf = bytes
        } else {
            buf = bytes.readSlice(length: dataLen)!
        }
        
        return .data(.byteBuffer(buf))
    }
    
    private mutating func parseHeadersFramePayload(length: Int, streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // HEADERS frame : RFC 7540 § 6.2
        guard streamID != .rootStream else {
            // HEADERS frames MUST be associated with a stream. If a HEADERS frame is received whose
            // stream identifier field is 0x0, the recipient MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
        }
        
        var bytesToRead = length
        
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
        
        // slice out the relevant chunk of data (ignoring padding)
        let headerByteSize = bytesToRead - Int(padding)
        var slice = bytes.readSlice(length: headerByteSize)!
        let headers = try self.headerDecoder.decodeHeaders(from: &slice)
        
        return .headers(headers, priorityData)
    }
    
    private func parsePriorityFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // PRIORITY frame : RFC 7540 § 6.3
        guard streamID != .rootStream else {
            // The PRIORITY frame always identifies a stream. If a PRIORITY frame is received
            // with a stream identifier of 0x0, the recipient MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
        }
        guard length == 5 else {
            // A PRIORITY frame with a length other than 5 octets MUST be treated as a stream
            // error (Section 5.4.2) of type FRAME_SIZE_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
        }
        
        let raw: UInt32 = bytes.readInteger()!
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: raw & 0x8000_0000 != 0,
                                                         dependency: HTTP2StreamID(knownID: Int32(raw & ~0x8000_0000)),
                                                         weight: bytes.readInteger()!)
        return .priority(priorityData)
    }
    
    private func parseRstStreamFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // RST_STREAM frame : RFC 7540 § 6.4
        guard streamID != .rootStream else {
            // RST_STREAM frames MUST be associated with a stream. If a RST_STREAM frame is
            // received with a stream identifier of 0x0, the recipient MUST treat this as a
            // connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
        }
        guard length == 4 else {
            // A RST_STREAM frame with a length other than 4 octets MUST be treated as a
            // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
        }
        
        let errcode: UInt32 = bytes.readInteger()!
        return .rstStream(HTTP2ErrorCode(errcode))
    }
    
    private func parseSettingsFramePayload(length: Int, streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
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
            guard length == 0 else {
                // When [the ACK flag] is set, the payload of the SETTINGS frame MUST be empty.
                // Receipt of a SETTINGS frame with the ACK flag set and a length field value
                // other than 0 MUST be treated as a connection error (Section 5.4.1) of type
                // FRAME_SIZE_ERROR.
                throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
            }
        } else if length == 0 || length % 6 != 0 {
            // A SETTINGS frame with a length other than a multiple of 6 octets MUST be treated
            // as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
        }
        
        var settings: [HTTP2Setting] = []
        settings.reserveCapacity(length / 6)
        
        var consumed = 0
        while consumed < length {
            // TODO: name here should be HTTP2SettingsParameter(fromNetwork:), but that's currently defined for NGHTTP2's Int32 value
            let identifier = HTTP2SettingsParameter(fromPayload: bytes.readInteger()!)
            let value: UInt32 = bytes.readInteger()!
            
            settings.append(HTTP2Setting(parameter: identifier, value: Int(value)))
            consumed += 6
        }
        
        return .settings(settings)
    }
    
    private mutating func parsePushPromiseFramePayload(length: Int, streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // PUSH_PROMISE frame : RFC 7540 § 6.6
        guard streamID != .rootStream else {
            // The stream identifier of a PUSH_PROMISE frame indicates the stream it is associated with.
            // If the stream identifier field specifies the value 0x0, a recipient MUST respond with a
            // connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
        }
        
        var bytesToRead = length
        
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
        var slice = bytes.readSlice(length: headerByteLen)!
        let headers = try self.headerDecoder.decodeHeaders(from: &slice)
        
        return .pushPromise(promisedStreamID, headers)
    }
    
    private func parsePingFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // PING frame : RFC 7540 § 6.7
        guard length == 8 else {
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
        
        return .ping(HTTP2PingData(withTuple: tuple))
    }
    
    private func parseGoAwayFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // GOAWAY frame : RFC 7540 § 6.8
        guard streamID == .rootStream else {
            // The GOAWAY frame applies to the connection, not a specific stream. An endpoint
            // MUST treat a GOAWAY frame with a stream identifier other than 0x0 as a connection
            // error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .protocolError)
        }
        
        guard length >= 8 else {
            // Must have at least 8 bytes of data (last-stream-id plus error-code).
            throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
        }
        
        let raw: UInt32 = bytes.readInteger()!
        let errcode: UInt32 = bytes.readInteger()!
        
        let debugData: ByteBuffer?
        let extraLen = length - 8
        if extraLen > 0 {
            debugData = bytes.readSlice(length: extraLen)
        } else {
            debugData = nil
        }
        
        return .goAway(lastStreamID: HTTP2StreamID(knownID: Int32(raw & ~0x8000_000)),
                       errorCode: HTTP2ErrorCode(errcode), opaqueData: debugData)
    }
    
    private func parseWindowUpdateFramePayload(length: Int, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // WINDOW_UPDATE frame : RFC 7540 § 6.9
        guard length == 4 else {
            // A WINDOW_UPDATE frame with a length other than 4 octets MUST be treated as a
            // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw NIOHTTP2Errors.ConnectionError(code: .frameSizeError)
        }
        
        let raw: UInt32 = bytes.readInteger()!
        return .windowUpdate(windowSizeIncrement: Int(raw & ~0x8000_0000))
    }
    
    private func parseAltSvcFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // ALTSVC frame : RFC 7838 § 4
        guard length >= 2 else {
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
        
        let fieldLen = length - 2 - Int(originLen)
        let value: ByteBuffer?
        if fieldLen != 0 {
            value = bytes.readSlice(length: fieldLen)!
        } else {
            value = nil
        }
        
        return .alternativeService(origin: origin, field: value)
    }
    
    private func parseOriginFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // ORIGIN frame : RFC 8336 § 2
        guard streamID == .rootStream else {
            // The ORIGIN frame MUST be sent on stream 0; an ORIGIN frame on any
            // other stream is invalid and MUST be ignored.
            throw IgnoredFrame()
        }
        
        var origins: [String] = []
        var remaining = length
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
        
        return .origin(origins)
    }
}

struct HTTP2FrameEncoder {
    private let allocator: ByteBufferAllocator
    private var headerEncoder: HPACKEncoder
    
    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
        self.headerEncoder = HPACKEncoder(allocator: allocator)
    }
    
    /// Encodes the frame and optionally returns one or more blobs of data
    /// ready for the system.
    ///
    /// Returned data blobs would include anything of potentially flexible
    /// length, such as DATA payloads, header fragments in HEADERS or PUSH_PROMISE
    /// frames, and so on. This is to avoid manually copying chunks of data which
    /// we could just enqueue separately in sequence on the channel. Generally, if
    /// we have a byte buffer somewhere, we will return that separately rather than
    /// copy it into another buffer, with the corresponding allocation overhead.
    ///
    /// - Parameters:
    ///   - frame: The frame to encode.
    ///   - buf: Destination buffer for the encoded frame.
    /// - Returns: An array containing zero or more additional buffers to send, in
    ///            order. These may contain data frames' payload bytes, encoded
    ///            header fragments, etc.
    /// - Throws: Errors returned from HPACK encoder.
    mutating func encode(frame: HTTP2Frame, to buf: inout ByteBuffer) throws -> IOData? {
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
        buf.write(integer: frame.streamID.networkStreamID!)
        
        func writePayloadSize(_ size: Int) {
            var bytes: (UInt8, UInt8, UInt8)
            bytes.0 = UInt8((size & 0xff_00_00) >> 16)
            bytes.1 = UInt8((size & 0x00_ff_00) >>  8)
            bytes.2 = UInt8( size & 0x00_00_ff)
            withUnsafeBytes(of: bytes) { ptr in
                _ = buf.set(bytes: ptr, at: start)
            }
        }
        
        let payloadStart = buf.writerIndex
        
        // frame payload follows, which depends on the frame type itself
        switch frame.payload {
        case .data(let data):
            writePayloadSize(data.readableBytes)
            return data
            
        case .headers(let headers, let priority):
            if let priority = priority {
                var dependencyRaw = UInt32(priority.dependency.networkStreamID ?? 0)
                if priority.exclusive {
                    dependencyRaw |= 0x8000_0000
                }
                buf.write(integer: dependencyRaw)
                buf.write(integer: priority.weight)
            }
            
            // HPACK-encoded data. Find the stream and its associated encoder/decoder
            try self.headerEncoder.beginEncoding(allocator: self.allocator)
            try self.headerEncoder.append(headers: headers)
            let encoded = try self.headerEncoder.endEncoding()
            
            writePayloadSize(buf.writerIndex - payloadStart + encoded.readableBytes)
            return .byteBuffer(encoded)
            
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
            let streamVal: UInt32 = UInt32(streamID.networkStreamID ?? 0)
            buf.write(integer: streamVal)
            
            try self.headerEncoder.beginEncoding(allocator: self.allocator)
            try self.headerEncoder.append(headers: headers)
            let encoded = try self.headerEncoder.endEncoding()
            
            writePayloadSize(encoded.readableBytes + 4)
            return .byteBuffer(encoded)
            
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
                return .byteBuffer(data)
            } else {
                writePayloadSize(8)
            }
            
        case .windowUpdate(let size):
            writePayloadSize(4)
            buf.write(integer: UInt32(size) & ~0x8000_0000)
            
        case .alternativeService(let origin, let field):
            if let org = origin {
                buf.moveWriterIndex(forwardBy: 2)
                let start = buf.writerIndex
                buf.write(string: org)
                buf.set(integer: UInt16(buf.writerIndex - start), at: payloadStart)
            } else {
                buf.write(integer: UInt16(0))
            }
            
            if let value = field {
                writePayloadSize(buf.writerIndex - payloadStart + value.readableBytes)
                return .byteBuffer(value)
            } else {
                writePayloadSize(buf.writerIndex - payloadStart)
            }
            
        case .origin(let origins):
            for origin in origins {
                let sizeLoc = buf.writerIndex
                buf.moveWriterIndex(forwardBy: 2)
                
                let start = buf.writerIndex
                buf.write(string: origin)
                buf.set(integer: UInt16(buf.writerIndex - start), at: sizeLoc)
            }
            
            writePayloadSize(buf.writerIndex - payloadStart)
        }
        
        // all bytes to write are in the provided buffer now
        return nil
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
