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

// Things that don't work yet:
//
// - We don't account for padding in flow control.
// - We don't process settings changes that affect HPACK or max frame size.


/// NIO's default settings used for initial settings values on HTTP/2 streams, when the user hasn't
/// overridden that. This limits the max concurrent streams to 100, and limits the max header list
/// size to 16kB, to avoid trivial resource exhaustion on NIO HTTP/2 users.
public let nioDefaultSettings = [
    HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
    HTTP2Setting(parameter: .maxHeaderListSize, value: 1<<16)
]


public final class NIOHTTP2Handler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = IOData

    /// The magic string sent by clients at the start of a HTTP/2 connection.
    private static let clientMagic: StaticString = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    /// The connection state machine. We always have one of these.
    private var stateMachine: HTTP2ConnectionStateMachine

    /// The frame decoder. Right now this is optional because it needs an allocator, which
    /// we don't have until the channel is up. The rules of handler lifecycles mean that
    /// this can never fail to unwrap in a proper program.
    private var frameDecoder: HTTP2FrameDecoder!

    /// The frame encoder. Right now this is optional because it needs an allocator, which
    /// we don't have until the channel is up. The rules of handler lifecycles mean that
    /// this can never fail to unwrap in a proper program.
    private var frameEncoder: HTTP2FrameEncoder!

    /// The buffer we write data into. This is optional because we need an allocator, which
    /// we don't have until the channel is up. The rules of handler lifecycles mean that
    /// this can never fail to unwrap in a proper program.
    private var writeBuffer: ByteBuffer!

    /// A buffer where we write inbound events before we deliver them. This avoids us reordering
    /// user events and frames when re-entrant operations occur.
    private var inboundEventBuffer: InboundEventBuffer = InboundEventBuffer()

    /// A buffer for outbound frames. In some cases it is necessary to buffer outbound frames before
    /// sending, if sending them would trigger a protocol violation. Those buffered frames live here.
    private var outboundBuffer: CompoundOutboundBuffer

    /// This flag is set to false each time we get a channelReadComplete or flush, and set to true
    /// each time we write a frame automatically from this handler. If set to true in channelReadComplete,
    /// we will choose to flush automatically ourselves.
    private var wroteAutomaticFrame: Bool = false

    /// The mode this handler is operating in.
    private let mode: ParserMode

    /// The initial local settings of this connection. Sent as part of the preamble.
    private let initialSettings: HTTP2Settings

    // TODO(cory): We should revisit this: ideally we won't drop frames but would still deliver them where
    // possible, but I'm not doing that right now.
    /// Whether the channel has closed. If it has, we abort the decode loop, as we don't delay channelInactive.
    private var channelClosed: Bool = false

    /// The mode for this parser to operate in: client or server.
    public enum ParserMode {
        /// Client mode
        case client

        /// Server mode
        case server
    }

    public init(mode: ParserMode, initialSettings: HTTP2Settings = nioDefaultSettings) {
        self.stateMachine = HTTP2ConnectionStateMachine(role: .init(mode))
        self.mode = mode
        self.initialSettings = initialSettings
        self.outboundBuffer = CompoundOutboundBuffer(mode: mode, initialMaxOutboundStreams: 100)
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.frameDecoder = HTTP2FrameDecoder(allocator: context.channel.allocator, expectClientMagic: self.mode == .server)
        self.frameEncoder = HTTP2FrameEncoder(allocator: context.channel.allocator)
        self.writeBuffer = context.channel.allocator.buffer(capacity: 128)

        if context.channel.isActive {
            self.writeAndFlushPreamble(context: context)
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        self.writeAndFlushPreamble(context: context)
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.channelClosed = true
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var data = self.unwrapInboundIn(data)
        self.frameDecoder.append(bytes: &data)

        // Before we go in here we need to deliver any pending user events. This is because
        // we may have been called re-entrantly.
        self.processPendingUserEvents(context: context)

        // We parse eagerly to attempt to give back buffers to the reading channel wherever possible.
        self.frameDecodeLoop(context: context)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        self.unbufferAndFlushAutomaticFrames(context: context)
        context.fireChannelReadComplete()
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)

        do {
            switch try self.outboundBuffer.processOutboundFrame(frame, promise: promise) {
            case .nothing:
                // Nothing to do, got buffered.
                break
            case .forward:
                self.processOutboundFrame(context: context, frame: frame, promise: promise)
            case .forwardAndDrop(let framesToDrop, let error):
                // We need to forward this frame, and then fail these promises.
                self.processOutboundFrame(context: context, frame: frame, promise: promise)
                for (_, promise) in framesToDrop {
                    promise?.fail(error)
                }
            case .succeedAndDrop(let framesToDrop, let error):
                // We need to succeed this frame promise and fail the others. We fail the others first to keep the
                // promises in order.
                for (_, promise) in framesToDrop {
                    promise?.fail(error)
                }
                promise?.succeed(())
            }
        } catch {
            promise?.fail(error)
        }
    }

    public func flush(context: ChannelHandlerContext) {
        // We need to always flush here, so we'll pretend we wrote an automatic frame even if we didn't.
        self.wroteAutomaticFrame = true
        self.outboundBuffer.flushReceived()
        self.unbufferAndFlushAutomaticFrames(context: context)
    }
}


/// Inbound frame handling.
extension NIOHTTP2Handler {
    /// Spins over the frame decoder parsing frames and sending them down the channel pipeline.
    private func frameDecodeLoop(context: ChannelHandlerContext) {
        while !self.channelClosed, let (nextFrame, length) = self.decodeFrame(context: context) {
            guard case .continue = self.processFrame(nextFrame, flowControlledLength: length, context: context) else {
                break
            }
        }
    }

    /// Decodes a single frame. Returns `nil` if there is no frame to process, or if an error occurred.
    private func decodeFrame(context: ChannelHandlerContext) -> (HTTP2Frame, flowControlledLength: Int)? {
        do {
            return try self.frameDecoder.nextFrame()
        } catch InternalError.codecError(let code) {
            self.inboundConnectionErrorTriggered(context: context, underlyingError: NIOHTTP2Errors.UnableToParseFrame(), reason: code)
            return nil
        } catch is NIOHTTP2Errors.BadClientMagic {
            self.inboundConnectionErrorTriggered(context: context, underlyingError: NIOHTTP2Errors.BadClientMagic(), reason: .protocolError)
            return nil
        } catch {
            self.inboundConnectionErrorTriggered(context: context, underlyingError: error, reason: .internalError)
            return nil
        }
    }

    enum FrameProcessResult {
        case `continue`
        case stop
    }

    private func processFrame(_ frame: HTTP2Frame, flowControlledLength: Int, context: ChannelHandlerContext) -> FrameProcessResult {
        // All frames have one basic processing step: do we send them on, or drop them?
        // Some frames have further processing steps, regarding triggering user events or other operations.
        // Here we centralise this processing.
        let result: StateMachineResultWithEffect

        switch frame.payload {
        case .alternativeService, .origin:
            // TODO(cory): Implement
            fatalError("Currently some frames are unhandled.")
        case .data(let dataBody):
            result = self.stateMachine.receiveData(streamID: frame.streamID, flowControlledBytes: flowControlledLength, isEndStreamSet: dataBody.endStream)
        case .goAway(let lastStreamID, _, _):
            result = self.stateMachine.receiveGoaway(lastStreamID: lastStreamID)
        case .headers(let headerBody):
            result = self.stateMachine.receiveHeaders(streamID: frame.streamID, headers: headerBody.headers, isEndStreamSet: headerBody.endStream)
        case .ping(let pingData, let ack):
            let (stateMachineResult, postPingOperation) = self.stateMachine.receivePing(ackFlagSet: ack)
            result = stateMachineResult
            switch postPingOperation {
            case .nothing:
                break
            case .sendAck:
                self.writeBuffer.clear()
                let responseFrame = HTTP2Frame(streamID: frame.streamID, payload: .ping(pingData, ack: true))
                self.encodeAndWriteFrame(context: context, frame: responseFrame, promise: nil)
                self.wroteAutomaticFrame = true
            }
        case .priority:
            result = self.stateMachine.receivePriority()
        case .pushPromise(let pushedStreamData):
            result = self.stateMachine.receivePushPromise(originalStreamID: frame.streamID, childStreamID: pushedStreamData.pushedStreamID, headers: pushedStreamData.headers)
        case .rstStream(let reason):
            result = self.stateMachine.receiveRstStream(streamID: frame.streamID, reason: reason)
        case .settings(let newSettings):
            let (stateMachineResult, postSettingsOperation) = self.stateMachine.receiveSettings(newSettings,
                                                                                                frameEncoder: &self.frameEncoder,
                                                                                                frameDecoder: &self.frameDecoder)
            result = stateMachineResult
            switch postSettingsOperation {
            case .nothing:
                break
            case .sendAck:
                self.writeBuffer.clear()
                self.encodeAndWriteFrame(context: context, frame: HTTP2Frame(streamID: .rootStream, payload: .settings(.ack)), promise: nil)
                self.wroteAutomaticFrame = true
            }

        case .windowUpdate(let increment):
            result = self.stateMachine.receiveWindowUpdate(streamID: frame.streamID, windowIncrement: UInt32(increment))
        }

        self.processStateChange(result.effect)

        let returnValue: FrameProcessResult
        switch result.result {
        case .succeed:
            // Frame is good, we can pass it on.
            context.fireChannelRead(self.wrapInboundOut(frame))
            returnValue = .continue
        case .ignoreFrame:
            // Frame is good but no action needs to be taken.
            returnValue = .continue
        case .connectionError(let underlyingError, let errorCode):
            // We should stop parsing on received connection errors, the connection is going away anyway.
            self.inboundConnectionErrorTriggered(context: context, underlyingError: underlyingError, reason: errorCode)
            returnValue = .stop
        case .streamError(let streamID, let underlyingError, let errorCode):
            // We can continue parsing on stream errors in most cases, the frame is just ignored.
            self.inboundStreamErrorTriggered(context: context, streamID: streamID, underlyingError: underlyingError, reason: errorCode)
            returnValue = .continue
        }

        // Before we return the loop we process any user events that are currently pending.
        // These will likely only be ones that were generated now.
        self.processPendingUserEvents(context: context)

        return returnValue
    }

    /// A connection error was hit while receiving a frame.
    private func inboundConnectionErrorTriggered(context: ChannelHandlerContext, underlyingError: Error, reason: HTTP2ErrorCode) {
        // A connection error brings the entire connection down. We attempt to write a GOAWAY frame, and then report this
        // error. It's possible that we'll be unable to write the GOAWAY frame, but that also just logs the error.
        // Because we don't know what data the user handled before we got this, we propose that they may have seen all of it.
        // The user may choose to fire a more specific error if they wish.
        let goAwayFrame = HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: reason, opaqueData: nil))
        self.processOutboundFrame(context: context, frame: goAwayFrame, promise: nil)
        context.flush()
        context.fireErrorCaught(underlyingError)
    }

    /// A stream error was hit while receiving a frame.
    private func inboundStreamErrorTriggered(context: ChannelHandlerContext, streamID: HTTP2StreamID, underlyingError: Error, reason: HTTP2ErrorCode) {
        // A stream error brings down a single stream, causing a RST_STREAM frame. We attempt to write this, and then report
        // the error. It's possible that we'll be unable to write this, which will likely escalate this error, but that's
        // the user's issue.
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(reason))
        self.processOutboundFrame(context: context, frame: rstStreamFrame, promise: nil)
        context.flush()
        context.fireErrorCaught(underlyingError)
    }

    /// Emit any pending user events.
    private func processPendingUserEvents(context: ChannelHandlerContext) {
        for event in self.inboundEventBuffer {
            context.fireUserInboundEventTriggered(event)
        }
    }
}


/// Outbound frame handling.
extension NIOHTTP2Handler {
    /// Issues the preamble when necessary.
    private func writeAndFlushPreamble(context: ChannelHandlerContext) {
        guard self.stateMachine.mustSendPreamble else {
            return
        }

        if case .client = self.mode {
            self.writeBuffer.clear()
            self.writeBuffer.writeStaticString(NIOHTTP2Handler.clientMagic)
            context.write(self.wrapOutboundOut(.byteBuffer(self.writeBuffer)), promise: nil)
        }

        let initialSettingsFrame = HTTP2Frame(streamID: .rootStream, payload: .settings(.settings(self.initialSettings)))
        self.processOutboundFrame(context: context, frame: initialSettingsFrame, promise: nil)
        context.flush()
    }

    private func processOutboundFrame(context: ChannelHandlerContext, frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        let result: StateMachineResultWithEffect

        switch frame.payload {
        case .alternativeService, .origin:
            // TODO(cory): Implement
            fatalError("Currently some frames are unhandled.")
        case .data(let data):
            // TODO(cory): Correctly account for padding data.
            result = self.stateMachine.sendData(streamID: frame.streamID, flowControlledBytes: data.data.readableBytes, isEndStreamSet: data.endStream)
        case .goAway(let lastStreamID, _, _):
            result = self.stateMachine.sendGoaway(lastStreamID: lastStreamID)
        case .headers(let headerContent):
            result = self.stateMachine.sendHeaders(streamID: frame.streamID, headers: headerContent.headers, isEndStreamSet: headerContent.endStream)
        case .ping:
            result = self.stateMachine.sendPing()
        case .priority:
            result = self.stateMachine.sendPriority()
        case .pushPromise(let pushedContent):
            result = self.stateMachine.sendPushPromise(originalStreamID: frame.streamID, childStreamID: pushedContent.pushedStreamID, headers: pushedContent.headers)
        case .rstStream(let reason):
            result = self.stateMachine.sendRstStream(streamID: frame.streamID, reason: reason)
        case .settings(.settings(let newSettings)):
            result = self.stateMachine.sendSettings(newSettings)
        case .settings(.ack):
            // We do not allow sending SETTINGS ACK frames.
            promise?.fail(NIOHTTP2Errors.Unsupported(info: "Users may not send SETTINGS ACK frames"))
            return
        case .windowUpdate(let increment):
            result = self.stateMachine.sendWindowUpdate(streamID: frame.streamID, windowIncrement: UInt32(increment))
        }

        self.processStateChange(result.effect)

        switch result.result {
        case .ignoreFrame:
            preconditionFailure("Cannot be asked to ignore outbound frames.")
        case .connectionError(let underlyingError, _), .streamError(_, let underlyingError, _):
            self.outboundErrorTriggered(context: context, promise: promise, underlyingError: underlyingError)
            return
        case .succeed:
            self.writeBuffer.clear()
            self.encodeAndWriteFrame(context: context, frame: frame, promise: promise)
        }

        // This may have caused user events that need to be fired, so do so.
        self.processPendingUserEvents(context: context)
    }

    /// Encodes a frame and writes it to the network.
    private func encodeAndWriteFrame(context: ChannelHandlerContext, frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        let extraFrameData: IOData?

        do {
            extraFrameData = try self.frameEncoder.encode(frame: frame, to: &self.writeBuffer)
        } catch InternalError.codecError {
            self.outboundErrorTriggered(context: context, promise: promise, underlyingError: NIOHTTP2Errors.UnableToSerializeFrame())
            return
        } catch {
            self.outboundErrorTriggered(context: context, promise: promise, underlyingError: error)
            return
        }

        // Ok, if we got here we're good to send data. We want to attach the promise to the latest write, not
        // always the frame header.
        if let extraFrameData = extraFrameData {
            context.write(self.wrapOutboundOut(.byteBuffer(self.writeBuffer)), promise: nil)
            context.write(self.wrapOutboundOut(extraFrameData), promise: promise)
        } else {
            context.write(self.wrapOutboundOut(.byteBuffer(self.writeBuffer)), promise: promise)
        }
    }

    /// A stream or connection error was hit while attempting to send a frame.
    private func outboundErrorTriggered(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?, underlyingError: Error) {
        promise?.fail(underlyingError)
        context.fireErrorCaught(underlyingError)
    }
}


// MARK:- Helpers
extension NIOHTTP2Handler {
    private func processStateChange(_ stateChange: NIOHTTP2ConnectionStateChange?) {
        guard let stateChange = stateChange else {
            return
        }

        switch stateChange {
        case .streamClosed(let streamClosedData):
            self.inboundEventBuffer.pendingUserEvent(StreamClosedEvent(streamID: streamClosedData.streamID, reason: streamClosedData.reason))

            let failedWrites = self.outboundBuffer.streamClosed(streamClosedData.streamID)
            let error = NIOHTTP2Errors.StreamClosed(streamID: streamClosedData.streamID, errorCode: streamClosedData.reason ?? .cancel)
            for promise in failedWrites {
                promise?.fail(error)
            }
        case .streamCreated(let streamCreatedData):
            self.outboundBuffer.streamCreated(streamCreatedData.streamID, initialWindowSize: streamCreatedData.localStreamWindowSize.map(UInt32.init) ?? 0)
            self.inboundEventBuffer.pendingUserEvent(NIOHTTP2StreamCreatedEvent(streamID: streamCreatedData.streamID,
                                                                                localInitialWindowSize: streamCreatedData.localStreamWindowSize.map(UInt32.init),
                                                                                remoteInitialWindowSize: streamCreatedData.remoteStreamWindowSize.map(UInt32.init)))
        case .bulkStreamClosure(let streamClosureData):
            for droppedStream in streamClosureData.closedStreams {
                self.inboundEventBuffer.pendingUserEvent(StreamClosedEvent(streamID: droppedStream, reason: .cancel))

                let failedWrites = self.outboundBuffer.streamClosed(droppedStream)
                let error = NIOHTTP2Errors.StreamClosed(streamID: droppedStream, errorCode: .cancel)
                for promise in failedWrites {
                    promise?.fail(error)
                }
            }
        case .flowControlChange(let change):
            self.outboundBuffer.connectionWindowSize = change.localConnectionWindowSize
            self.inboundEventBuffer.pendingUserEvent(NIOHTTP2WindowUpdatedEvent(streamID: .rootStream, inboundWindowSize: change.remoteConnectionWindowSize, outboundWindowSize: change.localConnectionWindowSize))
            if let streamSize = change.localStreamWindowSize {
                self.outboundBuffer.updateStreamWindow(streamSize.streamID, newSize: streamSize.localStreamWindowSize.map(Int32.init) ?? 0)
                self.inboundEventBuffer.pendingUserEvent(NIOHTTP2WindowUpdatedEvent(streamID: streamSize.streamID, inboundWindowSize: streamSize.remoteStreamWindowSize, outboundWindowSize: streamSize.localStreamWindowSize))
            }
        case .streamCreatedAndClosed(let cAndCData):
            self.outboundBuffer.streamCreated(cAndCData.streamID, initialWindowSize: 0)
            let failedWrites = self.outboundBuffer.streamClosed(cAndCData.streamID)
            let error = NIOHTTP2Errors.StreamClosed(streamID: cAndCData.streamID, errorCode: .cancel)
            for promise in failedWrites {
                promise?.fail(error)
            }
        case .remoteSettingsChanged(let settingsChange):
            // TODO(cory): also max concurrent streams.
            if settingsChange.streamWindowSizeChange != 0 {
                self.outboundBuffer.initialWindowSizeChanged(settingsChange.streamWindowSizeChange)
            }
        case .localSettingsChanged(let settingsChange):
            if settingsChange.streamWindowSizeChange != 0 {
                self.inboundEventBuffer.pendingUserEvent(NIOHTTP2BulkStreamWindowChangeEvent(delta: settingsChange.streamWindowSizeChange))
            }
        }
    }

    private func unbufferAndFlushAutomaticFrames(context: ChannelHandlerContext) {
        // Two jobs: we have to unbuffer any buffered frames that can be written, and also potentially flush.
        loop: while true {
            switch self.outboundBuffer.nextFlushedWritableFrame() {
            case .noFrame:
                break loop
            case .error(let promise, let error):
                promise?.fail(error)
            case .frame(let frame, let promise):
                self.processOutboundFrame(context: context, frame: frame, promise: promise)
                self.wroteAutomaticFrame = true
            }
        }

        if self.wroteAutomaticFrame {
            self.wroteAutomaticFrame = false
            context.flush()
        }
    }
}


private extension HTTP2ConnectionStateMachine.ConnectionRole {
    init(_ role: NIOHTTP2Handler.ParserMode) {
        switch role {
        case .client:
            self = .client
        case .server:
            self = .server
        }
    }
}
