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
import NIOHPACK

fileprivate protocol BytesAccumulating {
    mutating func accumulate(bytes: inout ByteBuffer)
}

/// Ingests HTTP/2 data and produces frames. You feed data in, and sometimes you'll get a complete frame out.
struct HTTP2FrameDecoder {
    private static let clientMagicBytes = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    private struct IgnoredFrame: Error {}

    /// The state for a parser that is waiting for the client magic.
    private struct ClientMagicState: BytesAccumulating {
        var pendingBytes: ByteBuffer! = nil

        mutating func accumulate(bytes: inout ByteBuffer) {
            guard var pendingBytes = self.pendingBytes else {
                // Take a copy of the pending bytes, consume them.
                self.pendingBytes = bytes
                bytes.moveReaderIndex(to: bytes.writerIndex)
                return
            }
            pendingBytes.write(buffer: &bytes)
            self.pendingBytes = pendingBytes
        }
    }
    
    /// The state for a parser that is currently idle.
    private struct IdleParserState: BytesAccumulating {
        // This is nil in exactly one instance, with an explicit check
        var unusedBytes: ByteBuffer!
        
        init(unusedBytes: ByteBuffer?) {
            self.unusedBytes = unusedBytes
            if self.unusedBytes != nil && self.unusedBytes.readableBytes == 0 {
                // if it's an empty buffer, reset the read/write indices so the read/write indices
                // don't just race each other & cause many many reallocations and larger allocations
                self.unusedBytes.quietlyReset()
            }
        }
        
        mutating func accumulate(bytes: inout ByteBuffer) {
            if unusedBytes != nil {
                self.unusedBytes.write(buffer: &bytes)
            } else {
                // take a copy of the input buffer
                self.unusedBytes = bytes
                // consume the bytes from the input buffer, so it's empty on exit
                bytes.moveReaderIndex(to: bytes.writerIndex)
            }
        }
    }
    
    /// The state for a parser that is currently accumulating payload data associated with
    /// a successfully decoded frame header.
    private struct AccumulatingPayloadParserState: BytesAccumulating {
        var header: FrameHeader
        var accumulatedBytes: ByteBuffer
        
        init(fromIdle state: IdleParserState, header: FrameHeader) {
            self.header = header
            self.accumulatedBytes = state.unusedBytes
        }
        
        mutating func accumulate(bytes: inout ByteBuffer) {
            self.accumulatedBytes.write(buffer: &bytes)
        }
    }
    
    /// The state for a parser that is currently emitting simulated DATA frames.
    ///
    /// In this state we are receiving bytes associated with a DATA frame. We have
    /// read the header successfully and, instead of accumulating all the payload bytes
    /// and emitting the single monolithic DATA frame sent by our peer, we instead emit
    /// one DATA frame for each payload chunk we receive from the networking stack. This
    /// allows us to make use of the existing `ByteBuffer`s allocated by the stack,
    /// and lets us avoid compiling a large buffer in our own memory. Note that it's
    /// entirely plausible for a 20MB payload to be split into four 5MB DATA frames,
    /// such that the client of this library will already be accumulating them into
    /// some form of buffer or file. Our breaking this into (say) twenty 1MB DATA
    /// frames will not affect that, and will avoid additional allocations and copies
    /// in the meantime.
    private struct SimulatingDataFramesParserState: BytesAccumulating {
        var header: FrameHeader
        var payload: ByteBuffer
        let expectedPadding: UInt8
        var remainingByteCount: Int
        
        init(fromIdle state: IdleParserState, header: FrameHeader, expectedPadding: UInt8, remainingBytes: Int) {
            self.header = header
            self.payload = state.unusedBytes
            self.expectedPadding = expectedPadding
            self.remainingByteCount = remainingBytes
        }
        
        init(fromAccumulatingPayload state: AccumulatingPayloadParserState, expectedPadding: UInt8, remainingBytes: Int) {
            self.header = state.header
            self.payload = state.accumulatedBytes
            self.expectedPadding = expectedPadding
            self.remainingByteCount = remainingBytes
        }
        
        mutating func accumulate(bytes: inout ByteBuffer) {
            self.payload.write(buffer: &bytes)
        }
    }
    
    /// The state for a parser that is accumulating the payload of a CONTINUATION frame.
    ///
    /// The CONTINUATION frame must follow from an existing HEADERS or PUSH_PROMISE frame,
    /// whose details are kept in this state.
    private struct AccumulatingContinuationPayloadParserState: BytesAccumulating {
        var headerBlockState: AccumulatingHeaderBlockFragmentsParserState
        var continuationPayload: ByteBuffer
        let continuationHeader: FrameHeader
        
        init(fromAccumulatingHeaderBlockFragments acc: AccumulatingHeaderBlockFragmentsParserState,
             continuationHeader: FrameHeader) {
            self.headerBlockState = acc
            self.continuationPayload = acc.incomingPayload
            self.continuationHeader = continuationHeader
        }
        
        mutating func accumulate(bytes: inout ByteBuffer) {
            self.continuationPayload.write(buffer: &bytes)
        }
    }
    
    private struct AccumulatingHeaderBlockFragmentsParserState: BytesAccumulating {
        var header: FrameHeader
        var accumulatedPayload: ByteBuffer
        var incomingPayload: ByteBuffer
        
        init(fromAccumulatingPayload acc: AccumulatingPayloadParserState, initialPayload: ByteBuffer) {
            self.header = acc.header
            self.accumulatedPayload = initialPayload
            self.incomingPayload = acc.accumulatedBytes
        }
        
        init(fromAccumulatingContinuation acc: AccumulatingContinuationPayloadParserState) {
            precondition(acc.continuationPayload.readableBytes >= acc.continuationHeader.length)
            
            self.header = acc.headerBlockState.header
            self.header.length += acc.continuationHeader.length
            self.accumulatedPayload = acc.headerBlockState.accumulatedPayload
            self.incomingPayload = acc.continuationPayload
            
            // strip off the continuation payload from the incoming payload
            var slice = self.incomingPayload.readSlice(length: acc.continuationHeader.length)!
            self.accumulatedPayload.write(buffer: &slice)
        }
        
        mutating func accumulate(bytes: inout ByteBuffer) {
            self.incomingPayload.write(buffer: &bytes)
        }
    }
    
    private enum ParserState {
        /// We are waiting for the initial client magic string.
        case awaitingClientMagic(ClientMagicState)

        /// We are not in the middle of parsing any frames.
        case idle(IdleParserState)
        
        /// We are accumulating payload bytes for a single frame.
        case accumulatingData(AccumulatingPayloadParserState)
        
        /// We are receiving bytes from a DATA frame payload, and are emitting multiple DATA frames,
        /// one for each chunk of bytes we see here.
        case simulatingDataFrames(SimulatingDataFramesParserState)
        
        /// We are accumulating a CONTINUATION frame.
        case accumulatingContinuationPayload(AccumulatingContinuationPayloadParserState)
        
        // We are waiting for a new CONTINUATION frame to arrive.
        case accumulatingHeaderBlockFragments(AccumulatingHeaderBlockFragmentsParserState)
    }
    
    private var isIdle: Bool {
        switch self.state {
        case .idle:
            return true
        default:
            return false
        }
    }
    
    var headerDecoder: HPACKDecoder
    private var state: ParserState
    private var allocator: ByteBufferAllocator
    
    /// Creates a new HTTP2 frame decoder.
    ///
    /// - parameter allocator: A `ByteBufferAllocator` used when accumulating blocks of data
    ///                        and decoding headers.
    /// - parameter expectClientMagic: Whether the parser should expect to receive the bytes of
    ///                                client magic string before frame parsing begins.
    init(allocator: ByteBufferAllocator, expectClientMagic: Bool) {
        self.allocator = allocator
        self.headerDecoder = HPACKDecoder(allocator: allocator)

        if expectClientMagic {
            self.state = .awaitingClientMagic(ClientMagicState(pendingBytes: nil))
        } else {
            self.state = .idle(IdleParserState(unusedBytes: nil))
        }
    }
    
    /// Used to pass bytes to the decoder.
    ///
    /// Once you've added bytes, call `nextFrame()` repeatedly to obtain any frames that can
    /// be decoded from the bytes previously accumulated.
    ///
    /// - Parameter bytes: Raw bytes received, ready to decode.
    mutating func append(bytes: inout ByteBuffer) {
        switch self.state {
        case .awaitingClientMagic(var state):
            state.accumulate(bytes: &bytes)
            self.state = .awaitingClientMagic(state)
        case .idle(var state):
            state.accumulate(bytes: &bytes)
            self.state = .idle(state)
        case .accumulatingData(var state):
            state.accumulate(bytes: &bytes)
            self.state = .accumulatingData(state)
        case .simulatingDataFrames(var state):
            state.accumulate(bytes: &bytes)
            self.state = .simulatingDataFrames(state)
        case .accumulatingContinuationPayload(var state):
            state.accumulate(bytes: &bytes)
            self.state = .accumulatingContinuationPayload(state)
        case .accumulatingHeaderBlockFragments(var state):
            state.accumulate(bytes: &bytes)
            self.state = .accumulatingHeaderBlockFragments(state)
        }
    }
    
    /// Attempts to decode a frame from the accumulated bytes passed to
    /// `append(bytes:)`.
    ///
    /// - returns: A decoded frame, or `nil` if no frame could be decoded.
    /// - throws: An error if a decoded frame violated the HTTP/2 protocol
    ///           rules.
    mutating func nextFrame() throws -> HTTP2Frame? {
        // Start running through our state machine until
        return try self.processNextState()
    }
    
    private mutating func processNextState() throws -> HTTP2Frame? {
        switch self.state {
        case .awaitingClientMagic(var state):
            // The client magic is 24 octets long: If we don't have it, keep waiting.
            guard let clientMagic = state.pendingBytes.readBytes(length: 24) else {
                return nil
            }

            guard clientMagic == HTTP2FrameDecoder.clientMagicBytes else {
                throw NIOHTTP2Errors.BadClientMagic()
            }

            self.state = .idle(.init(unusedBytes: state.pendingBytes))

        case .idle(var state):
            guard let header = state.unusedBytes.readFrameHeader() else {
                return nil
            }
            
            // if this is a DATA frame and either has no padding or has padding and we can read the pad length:
            if header.type == 0 && (!header.flags.contains(.padded) || state.unusedBytes.readableBytes > 0) {
                // DATA frame -- we simulate smaller frames with each incoming block
                if header.flags.contains(.padded) {
                    let padding: UInt8 = state.unusedBytes.readInteger()!
                    let remaining = header.length - 1
                    guard remaining - Int(padding) >= 0 else {
                        // there must be some actual bytes here
                        throw InternalError.codecError(code: .protocolError)
                    }
                    self.state = .simulatingDataFrames(SimulatingDataFramesParserState(fromIdle: state, header: header, expectedPadding: padding, remainingBytes: header.length - 1))
                } else {
                    self.state = .simulatingDataFrames(SimulatingDataFramesParserState(fromIdle: state, header: header, expectedPadding: 0, remainingBytes: header.length))
                }
            } else {
                // regular frame, or we need to read a padding size from a DATA frame
                self.state = .accumulatingData(AccumulatingPayloadParserState(fromIdle: state, header: header))
            }
            
        case .accumulatingData(var state):
            if state.header.type == 0 && state.accumulatedBytes.readableBytes > 0 {
                // We now have enough bytes to read the expected padding
                // We should only be here if it's a DATA frame with padding and we couldn't read
                // the padding before:
                assert(state.header.flags.contains(.padded))
                let padding: UInt8 = state.accumulatedBytes.readInteger()!
                self.state = .simulatingDataFrames(SimulatingDataFramesParserState(fromAccumulatingPayload: state, expectedPadding: padding, remainingBytes: state.header.length - 1))
                break       // fall out of switch to call self.processNextState() again, which will send the simulated frame
            }
            guard state.header.type != 9 else {
                // we shouldn't see any CONTINUATION frames in this state
                throw InternalError.codecError(code: .internalError)
            }
            guard state.accumulatedBytes.readableBytes >= state.header.length else {
                return nil
            }
            
            // entire frame is available -- handle special cases (HEADERS/PUSH_PROMISE) first
            if (state.header.type == 1 || state.header.type == 5) && !state.header.flags.contains(.endHeaders) {
                // don't emit these, coalesce them with following CONTINUATION frames
                // strip out the frame payload bytes
                var payloadBytes = state.accumulatedBytes.readSlice(length: state.header.length)!
                
                // handle padding bytes, if any
                if state.header.flags.contains(.padded) {
                    // read the padding byte
                    let padding: UInt8 = payloadBytes.readInteger()!
                    // remove that many bytes from the end of the payload buffer
                    payloadBytes.moveWriterIndex(to: payloadBytes.writerIndex - Int(padding))
                    state.header.flags.subtract(.padded)     // we ate the padding
                }
                
                self.state = .accumulatingHeaderBlockFragments(AccumulatingHeaderBlockFragmentsParserState(fromAccumulatingPayload: state,
                                                                                                           initialPayload: payloadBytes))
                break       // go to process this state now
            }
            
            // an entire frame's data, including HEADERS/PUSH_PROMISE with the END_STREAM flag set
            // this may legitimately return nil if we ignore the frame
            let result = try self.readFrame(withHeader: state.header, from: &state.accumulatedBytes)
            self.state = .idle(IdleParserState(unusedBytes: state.accumulatedBytes))
            
            // if we got a frame, return it. If not that means we consumed and ignored a frame, so we
            // should go round again.
            if let frame = result {
                return frame
            }
            
        case .simulatingDataFrames(var state):
            // DATA frames cannot be sent on the root stream
            guard state.header.rawStreamID != 0 else {
                throw InternalError.codecError(code: .protocolError)
            }
            guard state.payload.readableBytes > 0 else {
                // need more bytes!
                return nil
            }
            
            if state.remainingByteCount <= Int(state.expectedPadding) {
                // we're just eating pad bytes now, maintaining state and emitting nothing
                if state.payload.readableBytes >= state.remainingByteCount {
                    // we've got them all, move to idle state with any following bytes
                    state.payload.moveReaderIndex(forwardBy: state.remainingByteCount)
                    self.state = .idle(IdleParserState(unusedBytes: state.payload))
                } else {
                    // stay in state and wait for more bytes
                    return nil
                }
            }
            
            // create a frame using these bytes, or a subset thereof
            var frameBytes: ByteBuffer
            var nextState: ParserState
            let flags: HTTP2Frame.FrameFlags
            if state.payload.readableBytes >= state.remainingByteCount {
                // read all the bytes for this last frame
                frameBytes = state.payload.readSlice(length: state.remainingByteCount)!
                if state.expectedPadding != 0 {
                    frameBytes.moveWriterIndex(to: frameBytes.writerIndex - Int(state.expectedPadding))
                }
                if state.payload.readableBytes == 0 {
                    state.payload.quietlyReset()
                }
                
                nextState = .idle(IdleParserState(unusedBytes: state.payload))
                flags = state.header.flags.subtracting(.padded)     // we never actually emit padding bytes
            } else if state.payload.readableBytes >= state.remainingByteCount - Int(state.expectedPadding) {
                // Here we have the last actual bytes of the payload, but haven't yet received all the
                // padding bytes that follow to complete the frame.
                frameBytes = state.payload.readSlice(length: state.remainingByteCount - Int(state.expectedPadding))!
                state.remainingByteCount -= frameBytes.readableBytes
                nextState = .simulatingDataFrames(state)        // we still need to consume the remaining padding bytes
                flags = state.header.flags.subtracting(.padded)     // keep the END_STREAM on there
            } else {
                frameBytes = state.payload      // entire thing
                state.remainingByteCount -= frameBytes.readableBytes
                state.payload.quietlyReset()
                nextState = .simulatingDataFrames(state)
                flags = state.header.flags.subtracting([.endStream, .padded])   // we never actually emit padding bytes
            }
            
            let streamID = HTTP2StreamID(networkID: state.header.rawStreamID)
            let outputFrame = HTTP2Frame(streamID: streamID, flags: flags, payload: .data(.byteBuffer(frameBytes)))
            self.state = nextState
            return outputFrame
            
        case .accumulatingContinuationPayload(var state):
            guard state.continuationHeader.length <= state.continuationPayload.readableBytes else {
                // not enough bytes yet
                return nil
            }
            
            // we have collected enough bytes: is this the last CONTINUATION frame?
            guard state.continuationHeader.flags.contains(.endHeaders) else {
                // nope, switch back to accumulating fragments
                self.state = .accumulatingHeaderBlockFragments(AccumulatingHeaderBlockFragmentsParserState(fromAccumulatingContinuation: state))
                break       // go process the new state
            }
            
            // it is, yay! Output a frame
            var payload = state.headerBlockState.accumulatedPayload
            var continuationSlice = state.continuationPayload.readSlice(length: state.continuationHeader.length)!
            payload.write(buffer: &continuationSlice)
            
            // we have something that looks just like a HEADERS or PUSH_PROMISE frame now
            var header = state.headerBlockState.header
            header.length += state.continuationHeader.length
            header.flags.formUnion(.endHeaders)
            let frame = try self.readFrame(withHeader: header, from: &payload)
            assert(frame != nil)
            
            // move to idle, passing in whatever was left after we consumed the CONTINUATION payload
            self.state = .idle(IdleParserState(unusedBytes: state.continuationPayload))
            return frame
            
        case .accumulatingHeaderBlockFragments(var state):
            // we have an entire HEADERS/PUSH_PROMISE frame, but one or more CONTINUATION frames
            // are arriving. Wait for them.
            guard let header = state.incomingPayload.readFrameHeader() else {
                return nil      // not enough bytes yet
            }
            
            // incoming frame: should be CONTINUATION
            guard header.type == 9 else {
                throw InternalError.codecError(code: .protocolError)
            }
            
            self.state = .accumulatingContinuationPayload(AccumulatingContinuationPayloadParserState(fromAccumulatingHeaderBlockFragments: state, continuationHeader: header))
            // will investigate this new state
        }
        
        return try self.processNextState()
    }
    
    private mutating func readFrame(withHeader header: FrameHeader, from bytes: inout ByteBuffer) throws -> HTTP2Frame? {
        assert(bytes.readableBytes >= header.length, "Buffer should contain at least \(header.length) bytes.")
        
        let flags = header.flags
        let streamID = HTTP2StreamID(networkID: header.rawStreamID)
        let frameEndIndex = bytes.readerIndex + header.length
        
        let payload: HTTP2Frame.FramePayload
        do {
            switch header.type {
            case 0:
                payload = try self.parseDataFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
            case 1:
                guard flags.contains(.endHeaders) else {
                    // we shouldn't be able to get here -- HEADERS frames only get passed into readFrame()
                    // when the END_HEADERS flag is set
                    throw InternalError.codecError(code: .internalError)
                }
                payload = try self.parseHeadersFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
            case 2:
                payload = try self.parsePriorityFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 3:
                payload = try self.parseRstStreamFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 4:
                payload = try self.parseSettingsFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
            case 5:
                guard flags.contains(.endHeaders) else {
                    // we shouldn't be able to get here -- PUSH_PROMOISE frames only get passed into readFrame()
                    // when the END_HEADERS flag is set
                    throw InternalError.codecError(code: .internalError)
                }
                payload = try self.parsePushPromiseFramePayload(length: header.length, streamID: streamID, flags: flags, bytes: &bytes)
            case 6:
                payload = try self.parsePingFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 7:
                payload = try self.parseGoAwayFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 8:
                payload = try self.parseWindowUpdateFramePayload(length: header.length, bytes: &bytes)
            case 9:
                // CONTINUATION frame should never be found here -- we should have handled them elsewhere
                throw InternalError.codecError(code: .internalError)
            case 10:
                payload = try self.parseAltSvcFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            case 12:
                payload = try self.parseOriginFramePayload(length: header.length, streamID: streamID, bytes: &bytes)
            default:
                // RFC 7540 § 4.1 https://httpwg.org/specs/rfc7540.html#FrameHeader
                //    "Implementations MUST ignore and discard any frame that has a type that is unknown."
                bytes.moveReaderIndex(to: frameEndIndex)
                self.state = .idle(IdleParserState(unusedBytes: bytes))
                return nil
            }
        } catch is IgnoredFrame {
            bytes.moveReaderIndex(to: frameEndIndex)
            self.state = .idle(IdleParserState(unusedBytes: bytes))
            return nil
        } catch _ as NIOHPACKError {
            // convert into a connection error of type COMPRESSION_ERROR
            bytes.moveReaderIndex(to: frameEndIndex)
            self.state = .idle(IdleParserState(unusedBytes: bytes))
            throw InternalError.codecError(code: .compressionError)
        } catch {
            bytes.moveReaderIndex(to: frameEndIndex)
            self.state = .idle(IdleParserState(unusedBytes: bytes))
            throw error
        }
        
        // ensure we've consumed all the input bytes
        bytes.moveReaderIndex(to: frameEndIndex)
        self.state = .idle(IdleParserState(unusedBytes: bytes))
        return HTTP2Frame(streamID: streamID, flags: flags, payload: payload)
    }
    
    private func parseDataFramePayload(length: Int, streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // DATA frame : RFC 7540 § 6.1
        guard streamID != .rootStream else {
            // DATA frames MUST be associated with a stream. If a DATA frame is received whose
            // stream identifier field is 0x0, the recipient MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }
        
        var dataLen = length
        let padding = try self.validatePadding(of: &bytes, against: &dataLen, flags: flags)
        
        let buf = bytes.readSlice(length: dataLen)!
        if padding > 0 {
            // don't forget to consume any padding bytes
            bytes.moveReaderIndex(forwardBy: padding)
        }
        return .data(.byteBuffer(buf))
    }
    
    private mutating func parseHeadersFramePayload(length: Int, streamID: HTTP2StreamID, flags: HTTP2Frame.FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // HEADERS frame : RFC 7540 § 6.2
        guard streamID != .rootStream else {
            // HEADERS frames MUST be associated with a stream. If a HEADERS frame is received whose
            // stream identifier field is 0x0, the recipient MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }
        
        var bytesToRead = length
        let padding = try self.validatePadding(of: &bytes, against: &bytesToRead, flags: flags)
        
        let priorityData: HTTP2Frame.StreamPriorityData?
        if flags.contains(.priority) {
            let raw: UInt32 = bytes.readInteger()!
            priorityData = HTTP2Frame.StreamPriorityData(exclusive: (raw & 0x8000_0000 != 0),
                                                         dependency: HTTP2StreamID(networkID: raw),
                                                         weight: bytes.readInteger()!)
            bytesToRead -= 5
        } else {
            priorityData = nil
        }
        
        // slice out the relevant chunk of data (ignoring padding)
        let headerByteSize = bytesToRead - padding
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
            throw InternalError.codecError(code: .protocolError)
        }
        guard length == 5 else {
            // A PRIORITY frame with a length other than 5 octets MUST be treated as a stream
            // error (Section 5.4.2) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
        }
        
        let raw: UInt32 = bytes.readInteger()!
        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: raw & 0x8000_0000 != 0,
                                                         dependency: HTTP2StreamID(networkID: raw),
                                                         weight: bytes.readInteger()!)
        return .priority(priorityData)
    }
    
    private func parseRstStreamFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // RST_STREAM frame : RFC 7540 § 6.4
        guard streamID != .rootStream else {
            // RST_STREAM frames MUST be associated with a stream. If a RST_STREAM frame is
            // received with a stream identifier of 0x0, the recipient MUST treat this as a
            // connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }
        guard length == 4 else {
            // A RST_STREAM frame with a length other than 4 octets MUST be treated as a
            // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
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
            throw InternalError.codecError(code: .protocolError)
        }
        if flags.contains(.ack) {
            guard length == 0 else {
                // When [the ACK flag] is set, the payload of the SETTINGS frame MUST be empty.
                // Receipt of a SETTINGS frame with the ACK flag set and a length field value
                // other than 0 MUST be treated as a connection error (Section 5.4.1) of type
                // FRAME_SIZE_ERROR.
                throw InternalError.codecError(code: .frameSizeError)
            }
        } else if length == 0 || length % 6 != 0 {
            // A SETTINGS frame with a length other than a multiple of 6 octets MUST be treated
            // as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
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
            throw InternalError.codecError(code: .protocolError)
        }
        
        var bytesToRead = length
        let padding = try self.validatePadding(of: &bytes, against: &bytesToRead, flags: flags)
        
        let promisedStreamID = HTTP2StreamID(networkID: bytes.readInteger()!)
        bytesToRead -= 4
        
        guard promisedStreamID != .rootStream else {
            throw InternalError.codecError(code: .protocolError)
        }
        
        let headerByteLen = bytesToRead - padding
        var slice = bytes.readSlice(length: headerByteLen)!
        let headers = try self.headerDecoder.decodeHeaders(from: &slice)
        
        return .pushPromise(promisedStreamID, headers)
    }
    
    private func parsePingFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // PING frame : RFC 7540 § 6.7
        guard length == 8 else {
            // Receipt of a PING frame with a length field value other than 8 MUST be treated
            // as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
        }
        guard streamID == .rootStream else {
            // PING frames are not associated with any individual stream. If a PING frame is
            // received with a stream identifier field value other than 0x0, the recipient MUST
            // respond with a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
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
            throw InternalError.codecError(code: .protocolError)
        }
        
        guard length >= 8 else {
            // Must have at least 8 bytes of data (last-stream-id plus error-code).
            throw InternalError.codecError(code: .frameSizeError)
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
        
        return .goAway(lastStreamID: HTTP2StreamID(networkID: raw),
                       errorCode: HTTP2ErrorCode(errcode), opaqueData: debugData)
    }
    
    private func parseWindowUpdateFramePayload(length: Int, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // WINDOW_UPDATE frame : RFC 7540 § 6.9
        guard length == 4 else {
            // A WINDOW_UPDATE frame with a length other than 4 octets MUST be treated as a
            // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
        }
        
        let raw: UInt32 = bytes.readInteger()!
        return .windowUpdate(windowSizeIncrement: Int(raw & ~0x8000_0000))
    }
    
    private func parseAltSvcFramePayload(length: Int, streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // ALTSVC frame : RFC 7838 § 4
        guard length >= 2 else {
            // Must be at least two bytes, to contain the length of the optional 'Origin' field.
            throw InternalError.codecError(code: .frameSizeError)
        }
        
        let originLen: UInt16 = bytes.readInteger()!
        let origin: String?
        if originLen > 0 {
            origin = bytes.readString(length: Int(originLen))!
        } else {
            origin = nil
        }
        
        if streamID == .rootStream && originLen == 0 {
            // MUST have origin on root stream
            throw IgnoredFrame()
        }
        if streamID != .rootStream && originLen != 0 {
            // MUST NOT have origin on non-root stream
            throw IgnoredFrame()
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
                throw InternalError.codecError(code: .protocolError)
            }
            let originLen: UInt16 = bytes.readInteger()!
            remaining -= 2
            
            guard remaining >= Int(originLen) else {
                // Malformed frame.
                throw InternalError.codecError(code: .frameSizeError)
            }
            let origin = bytes.readString(length: Int(originLen))!
            remaining -= Int(originLen)
            
            origins.append(origin)
        }
        
        return .origin(origins)
    }
    
    private func validatePadding(of bytes: inout ByteBuffer, against length: inout Int, flags: HTTP2Frame.FrameFlags) throws -> Int {
        guard flags.contains(.padded) else {
            return 0
        }
        
        let padding: UInt8 = bytes.readInteger()!
        length -= 1
        
        if length <= Int(padding) {
            // Padding that exceeds the remaining payload size MUST be treated as a PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }
        
        return Int(padding)
    }
}

struct HTTP2FrameEncoder {
    private let allocator: ByteBufferAllocator
    var headerEncoder: HPACKEncoder
    
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
        if frame.flags.contains(.padded) {
            // we don't support sending padded frames just now
            throw NIOHTTP2Errors.Unsupported(info: "Padding is not supported on sent frames at this time")
        }
        
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
        
        let payloadStart = buf.writerIndex
        
        // frame payload follows, which depends on the frame type itself
        switch frame.payload {
        case .data(let data):
            buf.writePayloadSize(data.readableBytes, at: start)
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
            
            try self.headerEncoder.encode(headers: headers, to: &buf)
            buf.writePayloadSize(buf.writerIndex - payloadStart, at: start)
            
        case .priority(let priorityData):
            buf.writePayloadSize(5, at: start)
            
            var raw = UInt32(priorityData.dependency.networkStreamID ?? 0)
            if priorityData.exclusive {
                raw |= 0x8000_0000
            }
            buf.write(integer: raw)
            buf.write(integer: priorityData.weight)
            
        case .rstStream(let errcode):
            buf.writePayloadSize(4, at: start)
            buf.write(integer: UInt32(errcode.networkCode))
            
        case .settings(let settings):
            buf.writePayloadSize(settings.count * 6, at: start)
            for setting in settings {
                buf.write(integer: setting.parameter.networkRepresentation)
                buf.write(integer: setting._value)
            }
            
        case .pushPromise(let streamID, let headers):
            let streamVal: UInt32 = UInt32(streamID.networkStreamID ?? 0)
            buf.write(integer: streamVal)
            
            try self.headerEncoder.encode(headers: headers, to: &buf)
            
            buf.writePayloadSize(buf.writerIndex - payloadStart, at: start)
            
        case .ping(let pingData):
            buf.writePayloadSize(8, at: start)
            withUnsafeBytes(of: pingData.bytes) { ptr -> Void in
                buf.write(bytes: ptr)
            }
            
        case .goAway(let lastStreamID, let errorCode, let opaqueData):
            let streamVal: UInt32 = UInt32(lastStreamID.networkStreamID ?? 0) & ~0x8000_0000
            buf.write(integer: streamVal)
            buf.write(integer: UInt32(errorCode.networkCode))
            
            if let data = opaqueData {
                buf.writePayloadSize(data.readableBytes + 8, at: start)
                return .byteBuffer(data)
            } else {
                buf.writePayloadSize(8, at: start)
            }
            
        case .windowUpdate(let size):
            buf.writePayloadSize(4, at: start)
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
                buf.writePayloadSize(buf.writerIndex - payloadStart + value.readableBytes, at: start)
                return .byteBuffer(value)
            } else {
                buf.writePayloadSize(buf.writerIndex - payloadStart, at: start)
            }
            
        case .origin(let origins):
            for origin in origins {
                let sizeLoc = buf.writerIndex
                buf.moveWriterIndex(forwardBy: 2)
                
                let start = buf.writerIndex
                buf.write(string: origin)
                buf.set(integer: UInt16(buf.writerIndex - start), at: sizeLoc)
            }
            
            buf.writePayloadSize(buf.writerIndex - payloadStart, at: start)
        }
        
        // all bytes to write are in the provided buffer now
        return nil
    }
}

fileprivate struct FrameHeader {
    var length: Int     // actually 24-bits
    var type: UInt8
    var flags: HTTP2Frame.FrameFlags
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
        
        return FrameHeader(length: len, type: type, flags: HTTP2Frame.FrameFlags(rawValue: flags), rawStreamID: rawStreamID)
    }
    
    mutating func writePayloadSize(_ size: Int, at location: Int) {
        // Yes, this performs better than running a UInt8 through the generic write(integer:) three times.
        var bytes: (UInt8, UInt8, UInt8)
        bytes.0 = UInt8((size & 0xff_00_00) >> 16)
        bytes.1 = UInt8((size & 0x00_ff_00) >>  8)
        bytes.2 = UInt8( size & 0x00_00_ff)
        withUnsafeBytes(of: bytes) { ptr in
            _ = self.set(bytes: ptr, at: location)
        }
    }
    
    mutating func quietlyReset() {
        self.moveReaderIndex(to: 0)
        self.moveWriterIndex(to: 0)
    }
}