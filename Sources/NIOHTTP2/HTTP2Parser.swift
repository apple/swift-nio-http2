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
import CNIONghttp2

/// NIO's default settings used for initial settings values on HTTP/2 streams, when the user hasn't
/// overridden that. This limits the max concurrent streams to 100, and limits the max header list
/// size to 16kB, to avoid trivial resource exhaustion on NIO HTTP/2 users.
public let nioDefaultSettings = [
    HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
    HTTP2Setting(parameter: .maxHeaderListSize, value: 1<<16)
]


/// A simple state tracking machine that ensures that we can handle re-entrant events.
///
/// This structure deals with the fact that we have shared state (the nghttp2 session) that may be
/// on the call stack. It is not necessarily safe to do that with nghttp2, so we need to avoid
/// re-entrant calls where nghttp2 is on the call stack. In practice that basically involves all
/// operations, so we need a data structure that can manage pending work. In most cases we do not
/// incur re-entrant calls, but that's no excuse for mishandling them!
///
/// The goal here is that in the common case of no re-entrancy we should not trigger any memory
/// allocations or introduce substantial overhead.
fileprivate class ReentrancyManager {
    typealias Output = (HTTP2Frame, EventLoopPromise<Void>?)
    typealias Input = ByteBuffer

    enum Operation {
        case feedInput(Input)
        case flush
        case feedOutput(Output)
        case receivedEOF(EOFType)
        case doOneWrite
    }

    enum ProcessingResult {
        case `continue`
        case complete
    }

    enum EOFType {
        case channelInactive
        case readEOF
    }

    private var bufferedInputs = CircularBuffer<Input>(initialRingCapacity: 8)
    private var bufferedOutputs = MarkedCircularBuffer<Output>(initialRingCapacity: 8)
    private var processing = false
    private var complete = false
    var mustFlush = false
    var eofType: EOFType?

    func feedOutput(_ frame: Output) {
        self.bufferedOutputs.append(frame)
    }

    func feedInput(_ buffer: Input) {
        self.bufferedInputs.append(buffer)
    }

    func markFlushPoint() {
        self.mustFlush = true
        self.bufferedOutputs.mark()
    }

    func dropWrites(error: Error) {
        while self.bufferedOutputs.count > 0 {
            self.bufferedOutputs.removeFirst().1?.fail(error: error)
        }
    }

    /// Process all pending data.
    ///
    /// This is safe across all re-entrance.
    func process(ctx: ChannelHandlerContext, _ body: (Operation, ChannelHandlerContext) -> ProcessingResult) {
        guard !self.processing else {
            return
        }
        self.processing = true
        defer { self.processing = false }

        while case .continue = processOneOperation(ctx: ctx, body) { }
    }

    private func processOneOperation(ctx: ChannelHandlerContext, _ body: (Operation, ChannelHandlerContext) -> ProcessingResult) -> ProcessingResult {
        // If we know that we have fired an inactive connection, we do not process further work.
        if self.complete {
            return .complete
        }

        // We process events in the following order:
        // 1. If there are inputs to process, process them.
        // 2. If we have hit EOF, process it.
        // 3. If there are outputs to deliver, deliver them.
        // 4. If we were asked to flush, flush.
        // If we're already processing, though, we do nothing.
        if self.bufferedInputs.count > 0 {
            return body(.feedInput(self.bufferedInputs.removeFirst()), ctx)
        }

        if let eof = self.eofType {
            self.complete = true
            return body(.receivedEOF(eof), ctx)
        }

        guard self.mustFlush else {
            return .complete
        }

        // If we get to here, we have to flush.
        if self.bufferedOutputs.hasMark() {
            return body(.feedOutput(self.bufferedOutputs.removeFirst()), ctx)
        }

        // Now we want to send some data. If this returns .continue, we want to spin
        // around keep going. If this returns .complete, we can go ahead and flush.
        if case .complete = body(.doOneWrite, ctx) {
            self.mustFlush = false
            return body(.flush, ctx)
        } else {
            return .continue
        }
    }
}


public final class HTTP2Parser: ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundOut = IOData
    public typealias OutboundIn = HTTP2Frame

    /// The mode for this parser to operate in: client or server.
    public enum ParserMode {
        /// Client mode
        case client

        /// Server mode
        case server
    }

    private var session: NGHTTP2Session!
    private let mode: ParserMode
    private let initialSettings: [HTTP2Setting]
    private let reentrancyManager = ReentrancyManager()

    public init(mode: ParserMode, initialSettings: [HTTP2Setting] = nioDefaultSettings) {
        self.mode = mode
        self.initialSettings = initialSettings
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        self.session = NGHTTP2Session(mode: self.mode,
                                      allocator: ctx.channel.allocator,
                                      maxCachedStreamIDs: 1024,  // TODO(cory): Make configurable
                                      frameReceivedHandler: { ctx.fireChannelRead(self.wrapInboundOut($0)) },
                                      sendFunction: { ctx.write(self.wrapOutboundOut($0), promise: $1) },
                                      userEventFunction: { ctx.fireUserInboundEventTriggered($0) })

        self.flushPreamble(ctx: ctx)
        ctx.fireChannelActive()
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        self.session = nil
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        self.reentrancyManager.feedInput(data)
        self.reentrancyManager.process(ctx: ctx, self.process)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        self.reentrancyManager.mustFlush = true
        self.reentrancyManager.process(ctx: ctx, self.process)
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        self.reentrancyManager.eofType = .channelInactive
        self.reentrancyManager.process(ctx: ctx, self.process)
        ctx.fireChannelInactive()
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        // Half-closure is not allowed for HTTP/2: it must always be possible to send frames both ways.
        if case .some(.inputClosed) = event as? ChannelEvent {
            self.reentrancyManager.eofType = .readEOF
            self.reentrancyManager.process(ctx: ctx, self.process)
        } else {
            ctx.fireUserInboundEventTriggered(event)
        }
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.reentrancyManager.feedOutput((frame, promise))
    }

    public func flush(ctx: ChannelHandlerContext) {
        self.reentrancyManager.markFlushPoint()
        self.reentrancyManager.process(ctx: ctx, self.process)
    }

    private func flushPreamble(ctx: ChannelHandlerContext) {
        let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(self.initialSettings))
        self.reentrancyManager.feedOutput((frame, nil))
        self.reentrancyManager.markFlushPoint()
        self.reentrancyManager.process(ctx: ctx, self.process)
    }

    private func dropOutstandingWrites() {
        self.reentrancyManager.dropWrites(error: ChannelError.eof)
    }

    private func process(_ operation: ReentrancyManager.Operation, _ context: ChannelHandlerContext) -> ReentrancyManager.ProcessingResult {
        switch operation {
        case .feedInput(var input):
            self.session.feedInput(buffer: &input)
            return .continue
        case .feedOutput(let frame, let promise):
            self.session.feedOutput(frame: frame, promise: promise)
            return .continue
        case .doOneWrite:
            switch self.session.doOneWrite() {
            case .didWrite:
                return .continue
            case .noWrite:
                return .complete
            }
        case .flush:
            context.flush()
            return .continue
        case .receivedEOF(let eofType):
            do {
                try self.session.receivedEOF()
            } catch {
                context.fireErrorCaught(error)
            }

            switch eofType {
            case .channelInactive:
                context.fireChannelInactive()
            case .readEOF:
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }

            self.dropOutstandingWrites()
            return .complete
        }
    }
}
