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

/// `StreamIDOption` allows users to query the stream ID for a given `HTTP2StreamChannel`.
///
/// On active `HTTP2StreamChannel`s, it is possible that a channel handler or user may need to know which
/// stream ID the channel owns. This channel option allows that query. Please note that this channel option
/// is *get-only*: that is, it cannot be used with `setOption`. The stream ID for a given `HTTP2StreamChannel`
/// is immutable.
public enum StreamIDOption: ChannelOption {
    public typealias AssociatedValueType = Void
    public typealias OptionType = HTTP2StreamID

    case const(Void)
}

/// The various channel options specific to `HTTP2StreamChannel`s.
///
/// Please note that some of NIO's regular `ChannelOptions` are valid on `HTTP2StreamChannel`s.
public struct HTTP2StreamChannelOptions {
    /// - seealso: `StreamIDOption`.
    public static let streamID: StreamIDOption = .const(())
}


/// The current state of a stream channel.
private enum StreamChannelState {
    case idle
    case active
    case closing
    case closingFromIdle
    case closed

    mutating func activate() {
        switch self {
        case .idle:
            self = .active
        case .active, .closing, .closingFromIdle, .closed:
            preconditionFailure("Became active from state \(self)")
        }
    }

    mutating func beginClosing() {
        switch self {
        case .active, .closing:
            self = .closing
        case .idle, .closingFromIdle:
            self = .closingFromIdle
        case .closed:
            preconditionFailure("Cannot begin closing while closed")
        }
    }

    mutating func completeClosing() {
        switch self {
        case .idle, .closing, .closingFromIdle, .active:
            self = .closed
        case .closed:
            preconditionFailure("Complete closing from \(self)")
        }
    }
}


final class HTTP2StreamChannel: Channel, ChannelCore {
    internal init(allocator: ByteBufferAllocator, parent: Channel, streamID: HTTP2StreamID) {
        self.allocator = allocator
        self.closePromise = parent.eventLoop.newPromise()
        self.localAddress = parent.localAddress
        self.remoteAddress = parent.remoteAddress
        self.parent = parent
        self.eventLoop = parent.eventLoop
        self.streamID = streamID
        // FIXME: that's just wrong
        self.isWritable = true
        self.state = .idle

        // To begin with we initialize autoRead to false, but we are going to fetch it from our parent before we
        // go much further.
        self.autoRead = false
        self._pipeline = ChannelPipeline(channel: self)
    }

    @discardableResult
    internal func configure(initializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?) -> EventLoopFuture<Void> {
        // We need to configure this channel. This involves doing four things:
        // 1. Setting our autoRead state from the parent
        // 2. Calling the initializer, if provided.
        // 3. Activating when complete.
        // 4. Catching errors if they occur.
        let f = self.parent!.getOption(option: ChannelOptions.autoRead).then { autoRead -> EventLoopFuture<Void> in
            self.autoRead = autoRead
            return initializer?(self, self.streamID) ?? self.eventLoop.newSucceededFuture(result: ())
        }.map {
            self.state.activate()
            self.pipeline.fireChannelActive()
            if self.autoRead {
                self.read0()
            }
            self.deliverPendingWrites()
        }

        f.whenFailure { (error: Error) in
            if self.streamID.networkStreamID != nil {
                self.closedWhileOpen()
            } else {
                self.errorEncountered(error: error)
            }
        }
        return f
    }

    private var _pipeline: ChannelPipeline!

    public let allocator: ByteBufferAllocator

    private let closePromise: EventLoopPromise<()>

    public var closeFuture: EventLoopFuture<Void> {
        return self.closePromise.futureResult
    }

    public var pipeline: ChannelPipeline {
        return self._pipeline
    }

    public let localAddress: SocketAddress?

    public let remoteAddress: SocketAddress?

    public let parent: Channel?

    func localAddress0() throws -> SocketAddress {
        fatalError()
    }

    func remoteAddress0() throws -> SocketAddress {
        fatalError()
    }

    func setOption<T>(option: T, value: T.OptionType) -> EventLoopFuture<Void> where T: ChannelOption {
        if eventLoop.inEventLoop {
            do {
                return eventLoop.newSucceededFuture(result: try setOption0(option: option, value: value))
            } catch {
                return eventLoop.newFailedFuture(error: error)
            }
        } else {
            return eventLoop.submit { try self.setOption0(option: option, value: value) }
        }
    }

    public func getOption<T>(option: T) -> EventLoopFuture<T.OptionType> where T: ChannelOption {
        if eventLoop.inEventLoop {
            do {
                return eventLoop.newSucceededFuture(result: try getOption0(option: option))
            } catch {
                return eventLoop.newFailedFuture(error: error)
            }
        } else {
            return eventLoop.submit { try self.getOption0(option: option) }
        }
    }

    private func setOption0<T>(option: T, value: T.OptionType) throws where T: ChannelOption {
        assert(eventLoop.inEventLoop)

        switch option {
        case _ as AutoReadOption:
            self.autoRead = value as! Bool
        default:
            fatalError("setting option \(option) on HTTP2StreamChannel not supported")
        }
    }

    private func getOption0<T>(option: T) throws -> T.OptionType where T: ChannelOption {
        assert(eventLoop.inEventLoop)

        switch option {
        case _ as StreamIDOption:
            return self.streamID as! T.OptionType
        case _ as AutoReadOption:
            return self.autoRead as! T.OptionType
        default:
            fatalError("option \(option) not supported on HTTP2StreamChannel")
        }
    }

    public let isWritable: Bool

    public var isActive: Bool {
        return self.state == .active || self.state == .closing
    }

    public var _unsafe: ChannelCore {
        return self
    }

    public let eventLoop: EventLoop

    private let streamID: HTTP2StreamID

    private var state: StreamChannelState

    /// If close0 was called but the stream could not synchronously close (because it's currently
    /// active), the promise is stored here until it can be fulfilled.
    private var pendingClosePromise: EventLoopPromise<Void>?

    /// A buffer of pending inbound reads delivered from the parent channel.
    ///
    /// In the future this buffer will be used to manage interactions with read() and even, one day,
    /// with flow control. For now, though, all this does is hold frames until we have set the
    /// channel up.
    private var pendingReads: CircularBuffer<HTTP2Frame> = CircularBuffer(initialRingCapacity: 8)

    /// Whether `autoRead` is enabled. By default, all `HTTP2StreamChannel` objects inherit their `autoRead`
    /// state from their parent.
    private var autoRead: Bool

    /// Whether a call to `read` has happened without any frames available to read (that is, whether newly
    /// received frames should be immediately delivered to the pipeline).
    private var unsatisfiedRead: Bool = false

    /// A buffer of pending outbound writes to deliver to the parent channel.
    ///
    /// To correctly respect flushes, we deliberately withold frames from the parent channel until this
    /// stream is flushed, at which time we deliver them all. This buffer holds the pending ones.
    private var pendingWrites: MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)> = MarkedCircularBuffer(initialRingCapacity: 8)

    public func register0(promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard self.state != .closed else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        let frame = self.unwrapData(data, as: HTTP2Frame.self)
        self.pendingWrites.append((frame, promise))
    }

    public func flush0() {
        self.pendingWrites.mark()

        if self.isActive {
            self.deliverPendingWrites()
        }
    }

    public func read0() {
        if self.unsatisfiedRead {
            // We already have an unsatisfied read, let's do nothing.
            return
        }

        // At this stage, we have an unsatisfied read. If there is no pending data to read,
        // we're going to call read() on the parent channel. Otherwise, we're going to
        // succeed the read out of our pending data.
        self.unsatisfiedRead = true
        if self.pendingReads.count > 0 {
            self.tryToRead()
        } else {
            self.parent?.read()
        }
    }

    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // If the stream is already closed, we can fail this early and abort processing. If it's not, we need to emit a
        // RST_STREAM frame.
        guard self.state != .closed else {
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }

        // Store the pending close promise: it'll be succeeded later.
        if let promise = promise {
            if let pendingPromise = self.pendingClosePromise {
                pendingPromise.futureResult.cascade(promise: promise)
            } else {
                self.pendingClosePromise = promise
            }
        }

        self.closedWhileOpen()
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        // do nothing
    }

    public func channelRead0(_ data: NIOAny) {
        // do nothing
    }

    public func errorCaught0(error: Error) {
        // do nothing
    }

    /// Called when the channel was closed from the pipeline while the stream is still open.
    ///
    /// Will emit a RST_STREAM frame in order to close the stream. Note that this function does not
    /// directly close the stream: it waits until the stream closed notification is fired.
    private func closedWhileOpen() {
        precondition(self.state != .closed)
        guard self.state != .closing else {
            // If we're already closing, nothing to do here.
            return
        }

        self.state.beginClosing()
        let resetFrame = HTTP2Frame(streamID: self.streamID, payload: .rstStream(.cancel))
        self.receiveOutboundFrame(resetFrame, promise: nil)
        self.parent?.flush()
    }

    private func closedCleanly() {
        guard self.state != .closed else {
            return
        }
        self.state.completeClosing()
        self.dropPendingReads()
        self.failPendingWrites(error: ChannelError.eof)
        if let promise = self.pendingClosePromise {
            self.pendingClosePromise = nil
            promise.succeed(result: ())
        }
        self.pipeline.fireChannelInactive()

        self.eventLoop.execute {
            self.removeHandlers(channel: self)
            self.closePromise.succeed(result: ())
        }
    }

    fileprivate func errorEncountered(error: Error) {
        guard self.state != .closed else {
            return
        }
        self.state.completeClosing()
        self.dropPendingReads()
        self.failPendingWrites(error: error)
        if let promise = self.pendingClosePromise {
            self.pendingClosePromise = nil
            promise.fail(error: error)
        }
        self.pipeline.fireErrorCaught(error)
        self.pipeline.fireChannelInactive()

        self.eventLoop.execute {
            self.removeHandlers(channel: self)
            self.closePromise.fail(error: error)
        }
    }

    private func tryToRead() {
        // If there's no read to satisfy, no worries about it.
        guard self.unsatisfiedRead else {
            return
        }

        assert(self.pendingReads.count > 0, "tryToRead called without reads!")

        // If we're not active, we will hold on to these reads.
        guard self.isActive else {
            return
        }

        // Ok, we're satisfying a read here.
        self.unsatisfiedRead = false
        self.deliverPendingReads()

        // If auto-read is turned on, recurse into read0.
        // This cannot recurse indefinitely unless frames are being delivered
        // by the read stacks, which is generally fairly unlikely to continue unbounded.
        if self.autoRead {
            self.read0()
        }
    }
}

// MARK:- Functions used to manage pending reads and writes.
private extension HTTP2StreamChannel {
    /// Drop all pending reads.
    private func dropPendingReads() {
        /// To drop all the reads, as we don't need to report it, we just allocate a new buffer of 0 size.
        self.pendingReads = CircularBuffer(initialRingCapacity: 0)
    }

    /// Deliver all pending reads to the channel.
    private func deliverPendingReads() {
        assert(self.isActive)
        while self.pendingReads.count > 0 {
            self.pipeline.fireChannelRead(NIOAny(self.pendingReads.removeFirst()))
        }
        self.pipeline.fireChannelReadComplete()
    }

    /// Delivers all pending flushed writes to the parent channel.
    private func deliverPendingWrites() {
        // If there are no pending writes, don't bother with the processing.
        guard self.pendingWrites.hasMark() else {
            return
        }

        while self.pendingWrites.hasMark() {
            let write = self.pendingWrites.removeFirst()
            self.receiveOutboundFrame(write.0, promise: write.1)
        }
        self.parent?.flush()
    }

    /// Fails all pending writes with the given error.
    private func failPendingWrites(error: Error) {
        assert(self.state == .closed)
        while self.pendingWrites.count > 0 {
            self.pendingWrites.removeFirst().1?.fail(error: error)
        }
    }
}

// MARK:- Functions used to communicate between the `HTTP2StreamMultiplexer` and the `HTTP2StreamChannel`.
internal extension HTTP2StreamChannel {
    /// Called when a frame is received from the network.
    ///
    /// - parameters:
    ///     - frame: The `HTTP2Frame` received from the network.
    internal func receiveInboundFrame(_ frame: HTTP2Frame) {
        guard self.state != .closed else {
            // Do nothing
            return
        }

        self.pendingReads.append(frame)
        self.tryToRead()
    }


    /// Called when a frame is sent to the network.
    ///
    /// - parameters:
    ///     - frame: The `HTTP2Frame` to send to the network.
    ///     - promise: The promise associated with the frame write.
    private func receiveOutboundFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        guard let parent = self.parent, self.state != .closed else {
            let error = ChannelError.alreadyClosed
            promise?.fail(error: error)
            self.errorEncountered(error: error)
            return
        }
        parent.write(frame, promise: promise)
    }

    /// Called when a stream closure is received from the network.
    ///
    /// - parameters:
    ///     - reason: The reason received from the network, if any.
    internal func receiveStreamClosed(_ reason: HTTP2ErrorCode?) {
        if let reason = reason {
            let err = NIOHTTP2Errors.StreamClosed(streamID: self.streamID, errorCode: reason)
            self.errorEncountered(error: err)
        } else {
            self.closedCleanly()
        }
    }
}

