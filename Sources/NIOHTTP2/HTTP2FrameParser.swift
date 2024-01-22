//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHPACK

/// Ingests HTTP/2 data and produces frames. You feed data in, and sometimes you'll get a complete frame out.
struct HTTP2FrameDecoder {
    private static let clientMagicBytes = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    /// The result of a pass through the decoder state machine.
    private enum ParseResult {
        case needMoreData
        case `continue`
        case frame(HTTP2Frame, flowControlledLength: Int)
    }

    private struct IgnoredFrame: Error {}

    /// The state for a parser that is waiting for the client magic.
    private struct ClientMagicState {
        private var pendingBytes: ByteBuffer?

        init() {
            self.pendingBytes = nil
        }

        mutating func process() throws -> AccumulatingFrameHeaderParserState? {
            // The client magic is 24 octets long: If we don't have it, keep waiting.
            guard var pendingBytes = self.pendingBytes,
                    let clientMagic = pendingBytes.readSlice(length: 24) else {
                return nil
            }

            guard clientMagic.readableBytesView.elementsEqual(HTTP2FrameDecoder.clientMagicBytes) else {
                throw NIOHTTP2Errors.badClientMagic()
            }

            return AccumulatingFrameHeaderParserState(unusedBytes: pendingBytes)
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.pendingBytes.setOrWriteImmutableBuffer(bytes)
        }
    }

    /// The state for a parser that is currently accumulating the bytes of a frame header.
    private struct AccumulatingFrameHeaderParserState {
        private(set) var unusedBytes: ByteBuffer

        init(unusedBytes: ByteBuffer) {
            self.unusedBytes = unusedBytes
            if self.unusedBytes.readableBytes == 0 {
                // if it's an empty buffer, reset the read/write indices so the read/write indices
                // don't just race each other & cause many many reallocations and larger allocations
                self.unusedBytes.quietlyReset()
            }
        }

        enum NextState {
            case awaitingPaddingLengthByte(AwaitingPaddingLengthByteParserState)
            case accumulatingPayload(AccumulatingPayloadParserState)
            case simulatingDataFrames(SimulatingDataFramesParserState)
        }

        /// Process the frame header.
        ///
        /// We have three possible transitions here: we can transition to awaiting a padding
        /// length byte, we can transition to simulating data frames, or we can transition to
        /// processing any non-padded non-DATA frame.
        ///
        /// We also do pro-active verification of the state here.
        mutating func process(maxFrameSize: UInt32, maxHeaderListSize: Int) throws -> NextState? {
            guard let header = self.unusedBytes.readFrameHeader() else {
                return nil
            }

            // Confirm that SETTINGS_MAX_FRAME_SIZE is respected.
            guard header.length <= maxFrameSize else {
                throw InternalError.codecError(code: .frameSizeError)
            }

            switch header.type {
            case .data:
                // ensure we're on a valid stream
                guard header.streamID != .rootStream else {
                    // DATA frames cannot appear on the root stream
                    throw InternalError.codecError(code: .protocolError)
                }

                if header.flags.contains(.padded) {
                    guard header.length > 0 else {
                        // There needs to be at least the padding length byte, so the minimum frame size is 1.
                        throw InternalError.codecError(code: .protocolError)
                    }
                    return .awaitingPaddingLengthByte(
                        AwaitingPaddingLengthByteParserState(fromAccumulatingFrameHeader: self, frameHeader: header)
                    )
                } else {
                    return .simulatingDataFrames(
                        SimulatingDataFramesParserState(fromIdle: self, header: header, remainingBytes: header.length)
                    )
                }

            case .headers, .pushPromise:
                // Before we move on, do a quick preflight: if this frame header is for a frame that will
                // definitely violate SETTINGS_MAX_HEADER_LIST_SIZE, quit now.
                if header.length > maxHeaderListSize {
                    throw NIOHTTP2Errors.excessivelyLargeHeaderBlock()
                }

                if header.flags.contains(.padded) {
                    guard header.length > 0 else {
                        // There needs to be at least the padding length byte, so the minimum frame size is 1.
                        throw InternalError.codecError(code: .protocolError)
                    }

                    return .awaitingPaddingLengthByte(
                        AwaitingPaddingLengthByteParserState(fromAccumulatingFrameHeader: self, frameHeader: header)
                    )
                } else {
                    return .accumulatingPayload(AccumulatingPayloadParserState(fromIdle: self, header: header))
                }

            default:
                return .accumulatingPayload(AccumulatingPayloadParserState(fromIdle: self, header: header))
            }
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.unusedBytes.writeImmutableBuffer(bytes)
        }
    }

    private struct AwaitingPaddingLengthByteParserState {
        private var header: FrameHeader
        private var accumulatedBytes: ByteBuffer

        init(fromAccumulatingFrameHeader state: AccumulatingFrameHeaderParserState, frameHeader: FrameHeader) {
            precondition(frameHeader.type.supportsPadding)
            precondition(frameHeader.flags.contains(.padded))

            precondition(frameHeader.length > 0)
            self.header = frameHeader
            self.accumulatedBytes = state.unusedBytes
        }

        enum NextState {
            case simulatingDataFrames(SimulatingDataFramesParserState)
            case accumulatingPayload(AccumulatingPayloadParserState)
        }

        /// Process the padding length byte.
        ///
        /// Only HEADERS/PUSH_PROMISE and DATA frames can have padding length bytes,
        /// so we can only go to the states that process those frames.
        mutating func process() throws -> NextState? {
            // If we can, strip the padding byte.
            guard let expectedPadding = self.accumulatedBytes.readInteger(as: UInt8.self) else {
                return nil
            }

            // Amend the header to remove the `.padded` flag and update the expected length.
            // We know that `self.header.length > 0` (as shown in our init), so we can use unchecked math.
            var unpaddedHeader = self.header
            unpaddedHeader.flags.remove(.padded)
            unpaddedHeader.length &-= 1

            if unpaddedHeader.length < Int(expectedPadding) {
                // Padding that exceeds the remaining payload size MUST be treated as a PROTOCOL_ERROR.
                throw InternalError.codecError(code: .protocolError)
            }

            if unpaddedHeader.type == .data {
                return .simulatingDataFrames(
                    SimulatingDataFramesParserState(
                        header: unpaddedHeader,
                        accumulatedBytes: self.accumulatedBytes,
                        expectedPadding: expectedPadding
                    )
                )
            } else {
                return .accumulatingPayload(
                    AccumulatingPayloadParserState(
                        header: unpaddedHeader,
                        accumulatedBytes: self.accumulatedBytes,
                        expectedPadding: expectedPadding
                    )
                )
            }
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.accumulatedBytes.writeImmutableBuffer(bytes)
        }
    }

    /// The state for a parser that is currently accumulating payload data associated with
    /// a successfully decoded frame header.
    private struct AccumulatingPayloadParserState {
        private(set) var header: FrameHeader
        private var accumulatedBytes: ByteBuffer
        private var expectedPadding: Int?

        init(fromIdle state: AccumulatingFrameHeaderParserState, header: FrameHeader) {
            self.header = header
            self.accumulatedBytes = state.unusedBytes
            self.expectedPadding = nil
        }

        init(header: FrameHeader, accumulatedBytes: ByteBuffer, expectedPadding: UInt8) {
            // In this state we must not see a .padded header: it has to have been stripped earlier.
            // Do not remove this first precondition without removing the unchecked math in process().
            precondition(header.length >= Int(expectedPadding))
            precondition((!header.type.supportsPadding) || (!header.flags.contains(.padded)))

            self.header = header
            self.accumulatedBytes = accumulatedBytes
            self.expectedPadding = Int(expectedPadding)
        }

        enum ProcessResult {
            case accumulateHeaderBlockFragments(AccumulatingHeaderBlockFragmentsParserState)
            case parseFrame(header: FrameHeader, payloadBytes: ByteBuffer, paddingBytes: Int?, nextState: AccumulatingFrameHeaderParserState)
        }

        /// Process a frame.
        ///
        /// This has two edges: either we parse out a frame body for consumption, or we jump over to
        /// the CONTINUATION-sequence logic.
        mutating func process() throws -> ProcessResult? {
            switch self.header.type {
            case .continuation:
                // This is an unsolicited CONTINUATION frame
                throw InternalError.codecError(code: .protocolError)

            case .data:
                // This is an internal programming error, we got into a bad state. DATA frames are
                // handled separately.
                throw InternalError.impossibleSituation()

            default:
                break
            }

            guard var payloadBytes = self.accumulatedBytes.readSlice(length: self.header.length) else {
                return nil
            }

            // We're going to pretend the padding isn't there, by stripping off the trailing portion that contains the padding
            // and rewriting the header to imply it was never there.
            var syntheticHeader = self.header

            if let padding = self.expectedPadding {
                // Drop the padding off the back. The precondition in our constructor means we know that subtracting padding from
                // the writer index and header length are both safe.
                payloadBytes.moveWriterIndex(to: payloadBytes.writerIndex &- padding)
                syntheticHeader.length &-= padding
            }

            // entire frame is available -- handle the beginning of a CONTINUATION sequence first.
            if self.header.beginsContinuationSequence {
                // don't emit these, coalesce them with following CONTINUATION frames
                return .accumulateHeaderBlockFragments(
                    AccumulatingHeaderBlockFragmentsParserState(
                        header: syntheticHeader,
                        initialPayload: payloadBytes,
                        incomingPayload: self.accumulatedBytes,
                        originalPaddingBytes: self.expectedPadding
                    )
                )
            }

            // Before we read the frame, we save our state back. This ensures that if we throw an error here, we've
            // appropriately skipped the frame payload.
            let expectedPadding = self.expectedPadding
            let nextState = AccumulatingFrameHeaderParserState(unusedBytes: self.accumulatedBytes)

            return .parseFrame(
                header: syntheticHeader, payloadBytes: payloadBytes, paddingBytes: expectedPadding, nextState: nextState
            )
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.accumulatedBytes.writeImmutableBuffer(bytes)
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
    ///
    /// This object is also responsible for ensuring we correctly manage flow control
    /// for DATA frames. It does this by notifying the state machine up front of the
    /// total flow controlled size of the underlying frame, even if it is synthesising
    /// partial frames. All subsequent partial frames have a flow controlled length of
    /// zero. This ensures that the upper layer can correctly enforce flow control
    /// windows.
    private struct SimulatingDataFramesParserState {
        private(set) var header: FrameHeader
        private var payload: ByteBuffer
        private var remainingByteCount: Int
        private var flowControlledLength: Int
        private var expectedPadding: Int?

        init(fromIdle state: AccumulatingFrameHeaderParserState, header: FrameHeader, remainingBytes: Int) {
            self.header = header
            self.payload = state.unusedBytes
            self.expectedPadding = nil
            self.remainingByteCount = remainingBytes
            self.flowControlledLength = header.length
        }

        init(header: FrameHeader, accumulatedBytes: ByteBuffer, expectedPadding: UInt8) {
            // In this state we must not see a .padded header: it has to have been stripped earlier.
            precondition(header.length >= Int(expectedPadding))
            precondition((!header.type.supportsPadding) || (!header.flags.contains(.padded)))

            self.header = header
            self.payload = accumulatedBytes
            self.expectedPadding = Int(expectedPadding)
            self.remainingByteCount = header.length
            self.flowControlledLength = header.length + 1  // Include the .padding byte
        }

        /// The result of successful processing: we always produce a DATA frame, and have
        /// to jump to a new state.
        struct ProcessResult {
            var frame: HTTP2Frame
            var flowControlledLength: Int
            var nextState: NextState
        }

        enum NextState {
            case simulatingDataFrames(SimulatingDataFramesParserState)
            case strippingTrailingPadding(StrippingTrailingPaddingState)
            case accumulatingFrameHeader(AccumulatingFrameHeaderParserState)
        }

        /// Process a frame while we're synthesizing data frames.
        ///
        /// In this state if we succesfully move forward at all we'll produce a DATA frame, as
        /// well as a new target state.
        mutating func process() throws -> ProcessResult? {
            // Making sure the padded flag should be gone.
            assert(!self.header.flags.contains(.padded))

            let payloadSize = self.remainingByteCount - (self.expectedPadding ?? 0)
            guard payloadSize >= 0 else {
                // This math shouldn't end up short, but we'll defend against it anyway.
                throw InternalError.impossibleSituation()
            }

            if payloadSize > 0 && self.payload.readableBytes == 0 {
                // We can't make progress here, return early.
                return nil
            }

            // create a frame using these bytes, or a subset thereof
            let dataPayload: HTTP2Frame.FramePayload.Data
            let nextState: NextState

            // We extract the flow controlled length early because we only ever emit it once for a given frame. We set it to zero here so that all other frames will
            // return 0 as a flow controlled length.
            let flowControlledLength = self.flowControlledLength
            self.flowControlledLength = 0

            if let frameByteSlice = self.payload.readSlice(length: payloadSize) {
                // Here we have the last actual bytes of the payload.
                // As this is the final bytes of the payload, we report the padding size here (it conceptually trails) and the
                // value of the END_STREAM flag.
                dataPayload = HTTP2Frame.FramePayload.Data(
                    data: .byteBuffer(frameByteSlice),
                    endStream: self.header.flags.contains(.endStream),
                    paddingBytes: self.expectedPadding
                )
                nextState = self.computeNextStateForFinalFrame()
            } else {
                dataPayload = self.createSynthesizedFrame()
                nextState = .simulatingDataFrames(self)
            }

            let outputFrame = HTTP2Frame(streamID: self.header.streamID, payload: .data(dataPayload))
            return ProcessResult(frame: outputFrame, flowControlledLength: flowControlledLength, nextState: nextState)
        }

        private func computeNextStateForFinalFrame() -> NextState {
            if let padding = self.expectedPadding, padding > 0 {
                // We need to strip the padding.
                return .strippingTrailingPadding(
                    StrippingTrailingPaddingState(
                        fromSimulatingDataFramesState: self,
                        excessBytes: self.payload,
                        expectedPadding: padding
                    )
                )
            } else {
                return .accumulatingFrameHeader(AccumulatingFrameHeaderParserState(unusedBytes: self.payload))
            }
        }

        private mutating func createSynthesizedFrame() -> HTTP2Frame.FramePayload.Data {
            // We don't want to synthesise empty data frames. Zero-length data frames go through a different method
            // branch.
            precondition(self.payload.readableBytes > 0)

            let frameBytes = self.payload      // entire thing
            self.remainingByteCount -= frameBytes.readableBytes
            self.payload.quietlyReset()

            return HTTP2Frame.FramePayload.Data(
                data: .byteBuffer(frameBytes),
                endStream: false, // We're synthesising frames, there can't be END_STREAM here.
                paddingBytes: nil // We put all the padding on the last frame in the sequence.
            )
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.payload.writeImmutableBuffer(bytes)
        }
    }

    /// State for a parser that is stripping trailing padidng from a frame.
    ///
    /// This is currently used for DATA frames only. For HEADERS/PUSH_PROMISE frames the edges around
    /// CONTINUATION frames mean that it's easier for us to await the entire frame, including padding,
    /// before we strip it.
    private struct StrippingTrailingPaddingState {
        private var header: FrameHeader
        private var excessBytes: ByteBuffer
        private var expectedPadding: Int

        init(fromSimulatingDataFramesState state: SimulatingDataFramesParserState, excessBytes: ByteBuffer, expectedPadding: Int) {
            precondition(expectedPadding > 0)

            self.header = state.header
            self.excessBytes = excessBytes
            self.expectedPadding = expectedPadding
        }

        init(fromAccumulatingPayloadState state: AccumulatingPayloadParserState, excessBytes: ByteBuffer, expectedPadding: Int) {
            precondition(expectedPadding > 0)

            self.header = state.header
            self.excessBytes = excessBytes
            self.expectedPadding = expectedPadding
        }

        enum NextState {
            case accumulatingFrameHeader(AccumulatingFrameHeaderParserState)
            case strippingTrailingPadding(StrippingTrailingPaddingState)
        }

        mutating func process() -> NextState? {
            if self.excessBytes.readableBytes >= self.expectedPadding {
                // All the padding is here.
                self.excessBytes.moveReaderIndex(forwardBy: self.expectedPadding)
                return .accumulatingFrameHeader(AccumulatingFrameHeaderParserState(unusedBytes: self.excessBytes))
            } else if self.excessBytes.readableBytes > 0 {
                // We're short on padding. Strip some and move forward.
                // Unchecked is safe here: we know that `readableBytes` is positive, and smaller than `expectedPadding`.
                self.expectedPadding &-= self.excessBytes.readableBytes
                self.excessBytes.moveReaderIndex(to: self.excessBytes.writerIndex)
                return .strippingTrailingPadding(self)
            } else {
                // Do nothing, we don't have any bytes to consume.
                return nil
            }
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.excessBytes.writeImmutableBuffer(bytes)
        }
    }

    /// The state for a parser that is accumulating the payload of a CONTINUATION frame.
    ///
    /// The CONTINUATION frame must follow from an existing HEADERS or PUSH_PROMISE frame,
    /// whose details are kept in this state.
    private struct AccumulatingContinuationPayloadParserState {
        private var initialHeader: FrameHeader
        private var continuationHeader: FrameHeader
        private var currentFrameBytes: ByteBuffer
        private var continuationPayload: ByteBuffer
        private var originalPaddingBytes: Int?

        init(fromAccumulatingHeaderBlockFragments acc: AccumulatingHeaderBlockFragmentsParserState,
             continuationHeader: FrameHeader) {
            precondition(acc.header.beginsContinuationSequence)
            precondition(continuationHeader.type == .continuation)

            self.initialHeader = acc.header
            self.continuationHeader = continuationHeader
            self.currentFrameBytes = acc.accumulatedPayload
            self.continuationPayload = acc.incomingPayload
            self.originalPaddingBytes = acc.originalPaddingBytes
        }

        /// The result of successful processing: we either produce a frame and move to the new accumulating state,
        /// or we continue accumulating
        enum ProcessResult {
            case accumulateContinuationHeader(AccumulatingHeaderBlockFragmentsParserState)
            case parseFrame(header: FrameHeader, payloadBytes: ByteBuffer, paddingBytes: Int?, nextState: AccumulatingFrameHeaderParserState)
        }

        mutating func process() throws -> ProcessResult? {
            guard let continuationPayload = self.continuationPayload.readSlice(length: self.continuationHeader.length) else {
                return nil
            }

            // We need to flatten this out. Let's synthesise a new frame with a new header.
            var header = self.initialHeader
            header.length += self.continuationHeader.length
            self.currentFrameBytes.writeImmutableBuffer(continuationPayload)
            let payload = self.currentFrameBytes

            // we have collected enough bytes: is this the last CONTINUATION frame?
            guard self.continuationHeader.flags.contains(.endHeaders) else {
                // nope, switch back to accumulating fragments
                return .accumulateContinuationHeader(
                    AccumulatingHeaderBlockFragmentsParserState(
                        header: header,
                        initialPayload: payload,
                        incomingPayload: self.continuationPayload,
                        originalPaddingBytes: self.originalPaddingBytes
                    )
                )
            }

            // It is! Let's add .endHeaders to our fake frame.
            header.flags.formUnion(.endHeaders)
            let nextState = AccumulatingFrameHeaderParserState(unusedBytes: self.continuationPayload)
            return .parseFrame(header: header, payloadBytes: payload, paddingBytes: self.originalPaddingBytes, nextState: nextState)
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.continuationPayload.writeImmutableBuffer(bytes)
        }
    }

    /// This state is accumulating the various CONTINUATION frames into a single HEADERS or
    /// PUSH_PROMISE frame.
    ///
    /// The `incomingPayload` member holds any bytes from a following frame that haven't yet
    /// accumulated enough to parse the next frame and move to the next state.
    private struct AccumulatingHeaderBlockFragmentsParserState {
        private(set) var header: FrameHeader
        private(set) var accumulatedPayload: ByteBuffer
        private(set) var incomingPayload: ByteBuffer
        private(set) var originalPaddingBytes: Int?

        init(header: FrameHeader, initialPayload: ByteBuffer, incomingPayload: ByteBuffer, originalPaddingBytes: Int?) {
            precondition(header.beginsContinuationSequence)
            self.header = header
            self.accumulatedPayload = initialPayload
            self.incomingPayload = incomingPayload
            self.originalPaddingBytes = originalPaddingBytes
        }

        mutating func process(maxHeaderListSize: Int) throws -> AccumulatingContinuationPayloadParserState? {
            // we have an entire HEADERS/PUSH_PROMISE frame, but one or more CONTINUATION frames
            // are arriving. Wait for them.
            guard let header = self.incomingPayload.readFrameHeader() else {
                return nil
            }

            // incoming frame: should be CONTINUATION
            guard header.type == .continuation else {
                throw InternalError.codecError(code: .protocolError)
            }

            // This must be for the stream we're buffering header block fragments for, or this is an error.
            guard header.streamID == self.header.streamID else {
                throw InternalError.codecError(code: .protocolError)
            }

            // Check whether there is any possibility of this payload decompressing and fitting in max header list size.
            // If there isn't, kill it.
            guard self.header.length + header.length <= maxHeaderListSize else {
                throw NIOHTTP2Errors.excessivelyLargeHeaderBlock()
            }

            return AccumulatingContinuationPayloadParserState(fromAccumulatingHeaderBlockFragments: self, continuationHeader: header)
        }

        mutating func accumulate(bytes: ByteBuffer) {
            self.incomingPayload.writeImmutableBuffer(bytes)
        }
    }

    private enum ParserState {
        /// We are waiting for the initial client magic string.
        case awaitingClientMagic(ClientMagicState)

        /// This parser has been freshly allocated and has never seen any bytes.
        case initialized

        /// We are not in the middle of parsing any frames, we're waiting for a full frame header to arrive.
        case accumulatingFrameHeader(AccumulatingFrameHeaderParserState)

        /// We're waiting for the padding length byte.
        case awaitingPaddingLengthByte(AwaitingPaddingLengthByteParserState)

        /// We are accumulating payload bytes for a single frame.
        case accumulatingPayload(AccumulatingPayloadParserState)

        /// We are receiving bytes from a DATA frame payload, and are emitting multiple DATA frames,
        /// one for each chunk of bytes we see here.
        case simulatingDataFrames(SimulatingDataFramesParserState)

        /// We've parsed a frame, but we're eating the trailing padding.
        case strippingTrailingPadding(StrippingTrailingPaddingState)

        /// We are accumulating a CONTINUATION frame.
        case accumulatingContinuationPayload(AccumulatingContinuationPayloadParserState)

        /// We are waiting for a new CONTINUATION frame to arrive.
        case accumulatingHeaderBlockFragments(AccumulatingHeaderBlockFragmentsParserState)

        /// A temporary state where we are appending data to a buffer. Must always be exited after the append operation.
        case appending

        // MARK: Constructors from the sub-state results. This just hides some noise in the state machine code.
        init(_ targetState: AccumulatingFrameHeaderParserState.NextState) {
            switch targetState {
            case .awaitingPaddingLengthByte(let state):
                self = .awaitingPaddingLengthByte(state)
            case .accumulatingPayload(let state):
                self = .accumulatingPayload(state)
            case .simulatingDataFrames(let state):
                self = .simulatingDataFrames(state)
            }
        }

        init(_ targetState: AwaitingPaddingLengthByteParserState.NextState) {
            switch targetState {
            case .accumulatingPayload(let state):
                self = .accumulatingPayload(state)
            case .simulatingDataFrames(let state):
                self = .simulatingDataFrames(state)
            }
        }

        init(_ targetState: SimulatingDataFramesParserState.NextState) {
            switch targetState {
            case .accumulatingFrameHeader(let state):
                self = .accumulatingFrameHeader(state)
            case .simulatingDataFrames(let state):
                self = .simulatingDataFrames(state)
            case .strippingTrailingPadding(let state):
                self = .strippingTrailingPadding(state)
            }
        }

        init(_ targetState: StrippingTrailingPaddingState.NextState) {
            switch targetState {
            case .strippingTrailingPadding(let state):
                self = .strippingTrailingPadding(state)
            case .accumulatingFrameHeader(let state):
                self = .accumulatingFrameHeader(state)
            }
        }
    }

    internal var headerDecoder: HPACKDecoder
    private var state: ParserState

    // RFC 7540 § 6.5.2 puts the initial value of SETTINGS_MAX_FRAME_SIZE at 2**14 octets
    internal var maxFrameSize: UInt32 = 1<<14

    /// Creates a new HTTP2 frame decoder.
    ///
    /// - parameter allocator: A `ByteBufferAllocator` used when accumulating blocks of data
    ///                        and decoding headers.
    /// - parameter expectClientMagic: Whether the parser should expect to receive the bytes of
    ///                                client magic string before frame parsing begins.
    init(allocator: ByteBufferAllocator, expectClientMagic: Bool) {
        self.headerDecoder = HPACKDecoder(allocator: allocator)

        if expectClientMagic {
            self.state = .awaitingClientMagic(ClientMagicState())
        } else {
            self.state = .initialized
        }
    }

    /// Used to pass bytes to the decoder.
    ///
    /// Once you've added bytes, call `nextFrame()` repeatedly to obtain any frames that can
    /// be decoded from the bytes previously accumulated.
    ///
    /// - Parameter bytes: Raw bytes received, ready to decode.
    mutating func append(bytes: ByteBuffer) {
        switch self.state {
        case .awaitingClientMagic(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .awaitingClientMagic(state)
            }
        case .initialized:
            self.state = .accumulatingFrameHeader(AccumulatingFrameHeaderParserState(unusedBytes: bytes))
        case .accumulatingFrameHeader(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .accumulatingFrameHeader(state)
            }
        case .awaitingPaddingLengthByte(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .awaitingPaddingLengthByte(state)
            }
        case .accumulatingPayload(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .accumulatingPayload(state)
            }
        case .simulatingDataFrames(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .simulatingDataFrames(state)
            }
        case .strippingTrailingPadding(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .strippingTrailingPadding(state)
            }
        case .accumulatingContinuationPayload(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .accumulatingContinuationPayload(state)
            }
        case .accumulatingHeaderBlockFragments(var state):
            self.avoidingParserCoW { newState in
                state.accumulate(bytes: bytes)
                newState = .accumulatingHeaderBlockFragments(state)
            }
        case .appending:
            preconditionFailure("Cannot recursively append in appending state")
        }
    }

    /// Attempts to decode a frame from the accumulated bytes passed to
    /// `append(bytes:)`.
    ///
    /// - Returns: A decoded frame, or `nil` if no frame could be decoded.
    /// - throws: An error if a decoded frame violated the HTTP/2 protocol
    ///           rules.
    mutating func nextFrame() throws -> (HTTP2Frame, flowControlledLength: Int)? {
        // Start running through our state machine until we run out of bytes or we emit a frame.
        while true {
            switch (try self.processNextState()) {
            case .needMoreData:
                return nil
            case .frame(let frame, let flowControlledLength):
                return (frame, flowControlledLength)
            case .continue:
                continue
            }
        }

    }

    private mutating func processNextState() throws -> ParseResult {
        switch self.state {
        case .awaitingClientMagic(var state):
            guard let newState = try state.process() else {
                return .needMoreData
            }

            self.state = .accumulatingFrameHeader(newState)
            return .continue

        case .initialized:
            // no bytes, no frame
            return .needMoreData

        case .accumulatingFrameHeader(var state):
            guard let targetState = try state.process(maxFrameSize: self.maxFrameSize, maxHeaderListSize: self.headerDecoder.maxHeaderListSize) else {
                return .needMoreData
            }

            self.state = .init(targetState)
            return .continue

        case .awaitingPaddingLengthByte(var state):
            guard let targetState = try state.process() else {
                return .needMoreData
            }

            self.state = .init(targetState)
            return .continue


        case .accumulatingPayload(var state):
            guard let processResult = try state.process() else {
                return .needMoreData
            }

            switch processResult {
            case .accumulateHeaderBlockFragments(let state):
                self.state = .accumulatingHeaderBlockFragments(state)
                return .continue

            case .parseFrame(header: let header, payloadBytes: var payloadBytes, paddingBytes: let paddingBytes, nextState: let nextState):
                // Save off the state first, because if the frame payload parse throws we want to be able to skip over the frame.
                self.state = .accumulatingFrameHeader(nextState)

                // an entire frame's data, including HEADERS/PUSH_PROMISE with the END_HEADERS flag set
                // this may legitimately return nil if we ignore the frame
                let result = try self.readFrame(withHeader: header, from: &payloadBytes, paddingBytes: paddingBytes)

                if payloadBytes.readableBytes > 0 {
                    // Enforce that we consumed all the bytes.
                    throw InternalError.codecError(code: .frameSizeError)
                }

                // if we got a frame, return it. If not that means we consumed and ignored a frame, so we
                // should go round again.
                // We cannot emit DATA frames from here, so the flow controlled length is always 0.
                if let frame = result {
                    return .frame(frame, flowControlledLength: 0)
                } else {
                    return .continue
                }
            }

        case .simulatingDataFrames(var state):
            guard let processResult = try state.process() else {
                return .needMoreData
            }

            self.state = .init(processResult.nextState)
            return .frame(processResult.frame, flowControlledLength: processResult.flowControlledLength)

        case .strippingTrailingPadding(var state):
            guard let nextState = state.process() else {
                return .needMoreData
            }

            self.state = .init(nextState)
            return .continue

        case .accumulatingContinuationPayload(var state):
            guard let processResult = try state.process() else {
                return .needMoreData
            }

            switch processResult {
            case .accumulateContinuationHeader(let state):
                self.state = .accumulatingHeaderBlockFragments(state)
                return .continue

            case .parseFrame(header: let header, payloadBytes: var payloadBytes, paddingBytes: let paddingBytes, nextState: let nextState):
                // Save off the state first, because if the frame payload parse throws we want to be able to skip over the frame.
                self.state = .accumulatingFrameHeader(nextState)

                // an entire frame's data, including HEADERS/PUSH_PROMISE with the END_HEADERS flag set
                // this may legitimately return nil if we ignore the frame
                let result = try self.readFrame(withHeader: header, from: &payloadBytes, paddingBytes: paddingBytes)

                if payloadBytes.readableBytes > 0 {
                    // Enforce that we consumed all the bytes.
                    throw InternalError.codecError(code: .frameSizeError)
                }

                // if we got a frame, return it. If not that means we consumed and ignored a frame, so we
                // should go round again.
                // We cannot emit DATA frames from here, so the flow controlled length is always 0.
                if let frame = result {
                    return .frame(frame, flowControlledLength: 0)
                } else {
                    return .continue
                }
            }

        case .accumulatingHeaderBlockFragments(var state):
            guard let processResult = try state.process(maxHeaderListSize: self.headerDecoder.maxHeaderListSize) else {
                return .needMoreData
            }

            self.state = .accumulatingContinuationPayload(processResult)
            return .continue

        case .appending:
            preconditionFailure("Attempting to process in appending state")
        }
    }

    private mutating func readFrame(withHeader header: FrameHeader, from bytes: inout ByteBuffer, paddingBytes: Int?) throws -> HTTP2Frame? {
        assert(bytes.readableBytes == header.length, "Buffer should contain exactly \(header.length) bytes.")

        let flags = header.flags
        let streamID = header.streamID

        let payload: HTTP2Frame.FramePayload
        do {
            switch header.type {
            case .data:
                // Data frames never come through this flow.
                preconditionFailure()
            case .headers:
                precondition(flags.contains(.endHeaders))
                payload = try self.parseHeadersFramePayload(
                    streamID: streamID,
                    flags: flags,
                    bytes: &bytes,
                    paddingBytes: paddingBytes
                )
            case .priority:
                payload = try self.parsePriorityFramePayload(streamID: streamID, bytes: &bytes)
            case .rstStream:
                payload = try self.parseRstStreamFramePayload(streamID: streamID, bytes: &bytes)
            case .settings:
                payload = try self.parseSettingsFramePayload(streamID: streamID, flags: flags, bytes: &bytes)
            case .pushPromise:
                precondition(flags.contains(.endHeaders))
                payload = try self.parsePushPromiseFramePayload(
                    streamID: streamID,
                    flags: flags,
                    bytes: &bytes,
                    paddingBytes: paddingBytes
                )
            case .ping:
                payload = try self.parsePingFramePayload(streamID: streamID, flags: flags, bytes: &bytes)
            case .goAway:
                payload = try self.parseGoAwayFramePayload(streamID: streamID, bytes: &bytes)
            case .windowUpdate:
                payload = try self.parseWindowUpdateFramePayload(bytes: &bytes)
            case .continuation:
                // CONTINUATION frame should never be found here -- we should have handled them elsewhere
                preconditionFailure("Unexpected continuation frame")
            case .altSvc:
                payload = try self.parseAltSvcFramePayload(streamID: streamID, bytes: &bytes)
            case .origin:
                payload = try self.parseOriginFramePayload(streamID: streamID, bytes: &bytes)
            default:
                // RFC 7540 § 4.1 https://httpwg.org/specs/rfc7540.html#FrameHeader
                //    "Implementations MUST ignore and discard any frame that has a type that is unknown."
                bytes.moveReaderIndex(forwardBy: header.length)
                return nil
            }
        } catch is IgnoredFrame {
            return nil
        } catch _ as NIOHPACKError {
            // convert into a connection error of type COMPRESSION_ERROR
            throw InternalError.codecError(code: .compressionError)
        }

        return HTTP2Frame(streamID: streamID, payload: payload)
    }

    private mutating func parseHeadersFramePayload(streamID: HTTP2StreamID, flags: FrameFlags, bytes: inout ByteBuffer, paddingBytes: Int?) throws -> HTTP2Frame.FramePayload {
        // HEADERS frame : RFC 7540 § 6.2
        guard streamID != .rootStream else {
            // HEADERS frames MUST be associated with a stream. If a HEADERS frame is received whose
            // stream identifier field is 0x0, the recipient MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }

        let priorityData: HTTP2Frame.StreamPriorityData?
        if flags.contains(.priority) {
            // If we don't have enough length for the priority data, that's an error.
            guard let (rawStreamID, weight) = bytes.readMultipleIntegers(as: (UInt32, UInt8).self) else {
                throw InternalError.codecError(code: .protocolError)
            }

            priorityData = HTTP2Frame.StreamPriorityData(exclusive: (rawStreamID & 0x8000_0000 != 0),
                                                         dependency: HTTP2StreamID(networkID: rawStreamID),
                                                         weight: weight)
        } else {
            priorityData = nil
        }

        let headers = try self.headerDecoder.decodeHeaders(from: &bytes)
        let headersPayload = HTTP2Frame.FramePayload.Headers(headers: headers,
                                                             priorityData: priorityData,
                                                             endStream: flags.contains(.endStream),
                                                             paddingBytes: paddingBytes)

        return .headers(headersPayload)
    }

    private func parsePriorityFramePayload(streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // PRIORITY frame : RFC 7540 § 6.3
        guard streamID != .rootStream else {
            // The PRIORITY frame always identifies a stream. If a PRIORITY frame is received
            // with a stream identifier of 0x0, the recipient MUST respond with a connection error
            // (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }
        guard let (rawStreamID, weight) = bytes.readMultipleIntegers(as: (UInt32, UInt8).self) else {
            // A PRIORITY frame with a length other than 5 octets MUST be treated as a stream
            // error (Section 5.4.2) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
        }

        let priorityData = HTTP2Frame.StreamPriorityData(exclusive: rawStreamID & 0x8000_0000 != 0,
                                                         dependency: HTTP2StreamID(networkID: rawStreamID),
                                                         weight: weight)
        return .priority(priorityData)
    }

    private func parseRstStreamFramePayload(streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // RST_STREAM frame : RFC 7540 § 6.4
        guard streamID != .rootStream else {
            // RST_STREAM frames MUST be associated with a stream. If a RST_STREAM frame is
            // received with a stream identifier of 0x0, the recipient MUST treat this as a
            // connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }
        guard let errorCode = bytes.readInteger(as: UInt32.self) else {
            // A RST_STREAM frame with a length other than 4 octets MUST be treated as a
            // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
        }

        return .rstStream(HTTP2ErrorCode(errorCode))
    }

    private func parseSettingsFramePayload(streamID: HTTP2StreamID, flags: FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // SETTINGS frame : RFC 7540 § 6.5
        guard streamID == .rootStream else {
            // SETTINGS frames always apply to a connection, never a single stream. The stream
            // identifier for a SETTINGS frame MUST be zero (0x0). If an endpoint receives a
            // SETTINGS frame whose stream identifier field is anything other than 0x0, the
            // endpoint MUST respond with a connection error (Section 5.4.1) of type
            // PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }

        let readableBytes = bytes.readableBytes

        if flags.contains(.ack) {
            guard readableBytes == 0 else {
                // When [the ACK flag] is set, the payload of the SETTINGS frame MUST be empty.
                // Receipt of a SETTINGS frame with the ACK flag set and a length field value
                // other than 0 MUST be treated as a connection error (Section 5.4.1) of type
                // FRAME_SIZE_ERROR.
                throw InternalError.codecError(code: .frameSizeError)
            }

            return .settings(.ack)
        } else if readableBytes % 6 != 0 {
            // A SETTINGS frame with a length other than a multiple of 6 octets MUST be treated
            // as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
        }

        var settings: [HTTP2Setting] = []
        settings.reserveCapacity(readableBytes / 6)

        while let (settingsIdentifier, value) = bytes.readMultipleIntegers(as: (UInt16, UInt32).self) {
            let identifier = HTTP2SettingsParameter(fromPayload: settingsIdentifier)
            settings.append(HTTP2Setting(parameter: identifier, value: Int(value)))
        }

        // This assert should be utterly safe: we're reading 6 bytes at a time above, so there's no way for us to
        // fail to achieve this. It exists only to give us some proximate notification if there was a mistake above.
        assert(bytes.readableBytes == 0)

        return .settings(.settings(settings))
    }

    private mutating func parsePushPromiseFramePayload(streamID: HTTP2StreamID, flags: FrameFlags, bytes: inout ByteBuffer, paddingBytes: Int?) throws -> HTTP2Frame.FramePayload {
        // PUSH_PROMISE frame : RFC 7540 § 6.6
        guard streamID != .rootStream else {
            // The stream identifier of a PUSH_PROMISE frame indicates the stream it is associated with.
            // If the stream identifier field specifies the value 0x0, a recipient MUST respond with a
            // connection error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }

        guard let rawPromisedStreamID = bytes.readInteger(as: UInt32.self) else {
            throw InternalError.codecError(code: .frameSizeError)
        }

        let promisedStreamID = HTTP2StreamID(networkID: rawPromisedStreamID)

        guard promisedStreamID != .rootStream else {
            throw InternalError.codecError(code: .protocolError)
        }

        let headers = try self.headerDecoder.decodeHeaders(from: &bytes)

        let pushPromiseContent = HTTP2Frame.FramePayload.PushPromise(pushedStreamID: promisedStreamID, headers: headers, paddingBytes: paddingBytes)
        return .pushPromise(pushPromiseContent)
    }

    private func parsePingFramePayload(streamID: HTTP2StreamID, flags: FrameFlags, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // PING frame : RFC 7540 § 6.7
        guard let tuple = bytes.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self) else {
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

        return .ping(HTTP2PingData(withTuple: tuple), ack: flags.contains(.ack))
    }

    private func parseGoAwayFramePayload(streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // GOAWAY frame : RFC 7540 § 6.8
        guard streamID == .rootStream else {
            // The GOAWAY frame applies to the connection, not a specific stream. An endpoint
            // MUST treat a GOAWAY frame with a stream identifier other than 0x0 as a connection
            // error (Section 5.4.1) of type PROTOCOL_ERROR.
            throw InternalError.codecError(code: .protocolError)
        }

        guard let (rawLastStreamID, errorCode) = bytes.readMultipleIntegers(as: (UInt32, UInt32).self) else {
            // Must have at least 8 bytes of data (last-stream-id plus error-code).
            throw InternalError.codecError(code: .frameSizeError)
        }

        // Anything left over is the debug data.
        let debugData = bytes.readableBytes > 0 ? bytes : nil
        bytes.moveReaderIndex(to: bytes.writerIndex)

        return .goAway(lastStreamID: HTTP2StreamID(networkID: rawLastStreamID),
                       errorCode: HTTP2ErrorCode(errorCode),
                       opaqueData: debugData)
    }

    private func parseWindowUpdateFramePayload(bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // WINDOW_UPDATE frame : RFC 7540 § 6.9
        guard let rawWindowSizeIncrement = bytes.readInteger(as: UInt32.self) else {
            // A WINDOW_UPDATE frame with a length other than 4 octets MUST be treated as a
            // connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
            throw InternalError.codecError(code: .frameSizeError)
        }

        return .windowUpdate(windowSizeIncrement: Int(rawWindowSizeIncrement & ~0x8000_0000))
    }

    private func parseAltSvcFramePayload(streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // ALTSVC frame : RFC 7838 § 4
        guard let originLen = bytes.readInteger(as: UInt16.self) else {
            // Must be at least two bytes, to contain the length of the optional 'Origin' field.
            throw InternalError.codecError(code: .frameSizeError)
        }

        // For historical reasons we defined the origin as optional, and set to `nil` when the
        // origin len was 0, so we need to preserve that here.
        let origin: String?
        if originLen > 0 {
            guard let originString = bytes.readString(length: Int(originLen)) else {
                throw InternalError.codecError(code: .frameSizeError)
            }

            origin = originString
        } else {
            origin = nil
        }

        // For historical reasons we also defined the field value as optional, and set to `nil` when there were
        // no remaining bytes, so we preserve that here as well.
        let value: ByteBuffer?
        if bytes.readableBytes > 0 {
            value = bytes
            bytes.moveReaderIndex(to: bytes.writerIndex)
        } else {
            value = nil
        }

        // Double-check the frame values.
        if streamID == .rootStream && originLen == 0 {
            // MUST have origin on root stream
            throw IgnoredFrame()
        }
        if streamID != .rootStream && originLen != 0 {
            // MUST NOT have origin on non-root stream
            throw IgnoredFrame()
        }

        return .alternativeService(origin: origin, field: value)
    }

    private func parseOriginFramePayload(streamID: HTTP2StreamID, bytes: inout ByteBuffer) throws -> HTTP2Frame.FramePayload {
        // ORIGIN frame : RFC 8336 § 2
        var origins: [String] = []
        while let originLen = bytes.readInteger(as: UInt16.self) {
            guard let origin = bytes.readString(length: Int(originLen)) else {
                throw InternalError.codecError(code: .frameSizeError)
            }
            origins.append(origin)
        }

        if bytes.readableBytes > 0 {
            // Invalid frame length
            throw InternalError.codecError(code: .frameSizeError)
        }

        // Now double-check that we can safely use this frame.
        guard streamID == .rootStream else {
            // The ORIGIN frame MUST be sent on stream 0; an ORIGIN frame on any
            // other stream is invalid and MUST be ignored.
            throw IgnoredFrame()
        }

        return .origin(origins)
    }
}

fileprivate struct FrameHeader {
    var length: Int     // actually 24-bits
    var type: FrameType
    var flags: FrameFlags
    var streamID: HTTP2StreamID

    fileprivate struct FrameType: Hashable {
        private var rawValue: UInt8

        fileprivate init(_ rawValue: UInt8) {
            self.rawValue = rawValue
        }

        static let data = FrameType(0)
        static let headers = FrameType(1)
        static let priority = FrameType(2)
        static let rstStream = FrameType(3)
        static let settings = FrameType(4)
        static let pushPromise = FrameType(5)
        static let ping = FrameType(6)
        static let goAway = FrameType(7)
        static let windowUpdate = FrameType(8)
        static let continuation = FrameType(9)
        static let altSvc = FrameType(10)
        static let origin = FrameType(12)

        var supportsPadding: Bool {
            return self == .data || self == .headers || self == .pushPromise
        }
    }

    var beginsContinuationSequence: Bool {
        return (self.type == .headers || self.type == .pushPromise) && !self.flags.contains(.endHeaders)
    }
}

extension ByteBuffer {
    fileprivate mutating func readFrameHeader() -> FrameHeader? {
        guard let (lenHigh, lenLow, type, flags, rawStreamID) = self.readMultipleIntegers(as: (UInt16, UInt8, UInt8, UInt8, UInt32).self) else {
            return nil
        }

        return FrameHeader(
            length: Int(lenHigh) << 8 | Int(lenLow),
            type: FrameHeader.FrameType(type),
            flags: FrameFlags(rawValue: flags),
            streamID: HTTP2StreamID(networkID: rawStreamID)
        )
    }

    fileprivate mutating func quietlyReset() {
        self.moveReaderIndex(to: 0)
        self.moveWriterIndex(to: 0)
    }
}


/// The flags supported by the frame types understood by this protocol.
struct FrameFlags: OptionSet, CustomStringConvertible {
    internal typealias RawValue = UInt8

    internal private(set) var rawValue: UInt8

    internal init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// END_STREAM flag. Valid on DATA and HEADERS frames.
    internal static let endStream     = FrameFlags(rawValue: 0x01)

    /// ACK flag. Valid on SETTINGS and PING frames.
    internal static let ack           = FrameFlags(rawValue: 0x01)

    /// END_HEADERS flag. Valid on HEADERS, CONTINUATION, and PUSH_PROMISE frames.
    internal static let endHeaders    = FrameFlags(rawValue: 0x04)

    /// PADDED flag. Valid on DATA, HEADERS, CONTINUATION, and PUSH_PROMISE frames.
    ///
    /// NB: swift-nio-http2 does not automatically pad outgoing frames.
    internal static let padded        = FrameFlags(rawValue: 0x08)

    /// PRIORITY flag. Valid on HEADERS frames, specifically as the first frame sent
    /// on a new stream.
    internal static let priority      = FrameFlags(rawValue: 0x20)

    // useful for test cases
    internal static var allFlags: FrameFlags = [.endStream, .endHeaders, .padded, .priority]

    internal var description: String {
        var strings: [String] = []
        for i in 0..<8 {
            let flagBit: UInt8 = 1 << i
            if (self.rawValue & flagBit) != 0 {
                strings.append(String(flagBit, radix: 16, uppercase: true))
            }
        }
        return "[\(strings.joined(separator: ", "))]"
    }
}


// MARK: CoW helpers
extension HTTP2FrameDecoder {
    /// So, uh...this function needs some explaining.
    ///
    /// There is a downside to having all of the parser data in associated data on enumerations: any modification of
    /// that data will trigger copy on write for heap-allocated data. That means that when we append data to the underlying
    /// ByteBuffer we will CoW it, which is not good.
    ///
    /// The way we can avoid this is by using this helper function. It will temporarily set state to a value with no
    /// associated data, before attempting the body of the function. It will also verify that the parser never
    /// remains in this bad state.
    ///
    /// A key note here is that all callers must ensure that they return to a good state before they exit.
    ///
    /// Sadly, because it's generic and has a closure, we need to force it to be inlined at all call sites, which is
    /// not ideal.
    @inline(__always)
    private mutating func avoidingParserCoW<ReturnType>(_ body: (inout ParserState) -> ReturnType) -> ReturnType {
        self.state = .appending
        defer {
            assert(!self.isAppending)
        }

        return body(&self.state)
    }

    private var isAppending: Bool {
        if case .appending = self.state {
            return true
        } else {
            return false
        }
    }
}
