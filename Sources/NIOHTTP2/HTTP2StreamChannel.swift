//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import NIOConcurrencyHelpers
import NIOCore

/// The various channel options specific to `HTTP2StreamChannel`s.
///
/// Please note that some of NIO's regular `ChannelOptions` are valid on `HTTP2StreamChannel`s.
public struct HTTP2StreamChannelOptions: Sendable {
    /// See ``HTTP2StreamChannelOptions/Types/StreamIDOption``.
    public static let streamID: HTTP2StreamChannelOptions.Types.StreamIDOption = .init()
}

extension HTTP2StreamChannelOptions {
    /// A namespace for the types used to represent HTTP/2 stream channel options.
    public enum Types: Sendable {}
}

@available(*, deprecated, renamed: "HTTP2StreamChannelOptions.Types.StreamIDOption")
public typealias StreamIDOption = HTTP2StreamChannelOptions.Types.StreamIDOption

extension HTTP2StreamChannelOptions.Types {
    /// ``StreamIDOption`` allows users to query the stream ID for a given `HTTP2StreamChannel`.
    ///
    /// On active `HTTP2StreamChannel`s, it is possible that a channel handler or user may need to know which
    /// stream ID the channel owns. This channel option allows that query. Please note that this channel option
    /// is *get-only*: that is, it cannot be used with `setOption`. The stream ID for a given `HTTP2StreamChannel`
    /// is immutable.
    ///
    /// If a channel is not active, the stream ID will not be present, and attempting to
    /// get this channel option will fail.
    public struct StreamIDOption: ChannelOption {
        public typealias Value = HTTP2StreamID

        public init() {}
    }
}

/// The current state of a stream channel.
private enum StreamChannelState {
    /// The stream has been created, but not configured.
    case idle

    /// The is "active": we haven't sent channelActive yet, but it exists on the network and any shutdown must cause a frame to be emitted.
    case remoteActive

    /// This is also "active", but different to the above: we've sent channelActive, but the NIOHTTP2Handler hasn't seen the frame yet,
    /// and so we can close this channel without action if needed.
    case localActive

    /// This is actually active: channelActive has been fired and the HTTP2Handler believes this stream exists.
    case active

    /// We are closing from a state where channelActive had been fired. In practice this is only ever active, as
    /// in localActive we transition directly to closed.
    case closing

    /// We're closing from a state where we have never fired channel active, but where the channel was on the network.
    /// This means we need to send frames and wait for their side effects.
    case closingNeverActivated

    /// We're fully closed.
    case closed

    mutating func activate() {
        switch self {
        case .idle:
            self = .localActive
        case .remoteActive:
            self = .active
        case .localActive, .active, .closing, .closingNeverActivated, .closed:
            preconditionFailure("Became active from state \(self)")
        }
    }

    mutating func networkActive() {
        switch self {
        case .idle:
            self = .remoteActive
        case .localActive:
            self = .active
        case .closed:
            preconditionFailure("Stream must be reset on network activation when closed")
        case .remoteActive, .active, .closing, .closingNeverActivated:
            preconditionFailure("Cannot become network active twice, in state \(self)")
        }
    }

    mutating func beginClosing() {
        switch self {
        case .active, .closing:
            self = .closing
        case .closingNeverActivated, .remoteActive:
            self = .closingNeverActivated
        case .idle, .localActive:
            preconditionFailure("Idle streams immediately close")
        case .closed:
            preconditionFailure("Cannot begin closing while closed")
        }
    }

    mutating func completeClosing() {
        switch self {
        case .idle, .remoteActive, .closing, .closingNeverActivated, .active, .localActive:
            self = .closed
        case .closed:
            preconditionFailure("Complete closing from \(self)")
        }
    }
}

// The type of data read from and written to the channel.
enum HTTP2StreamDataType {
    /// `HTTP2Frame`
    case frame
    /// `HTTP2Frame.FramePayload`
    case framePayload
}

private enum HTTP2StreamData {
    case frame(HTTP2Frame)
    case framePayload(HTTP2Frame.FramePayload)

    var flowControlledSize: Int {
        switch self {
        case .frame(let frame):
            return frame.payload.flowControlledSize
        case .framePayload(let payload):
            return payload.flowControlledSize
        }
    }
}

@usableFromInline
final class HTTP2StreamChannel: Channel, ChannelCore, @unchecked Sendable {
    // @unchecked Sendable because the only mutable state is `_pipeline` which is only modified in init

    /// The stream data type of the channel.
    private let streamDataType: HTTP2StreamDataType

    internal init(
        allocator: ByteBufferAllocator,
        parent: Channel,
        multiplexer: OutboundStreamMultiplexer,
        streamID: HTTP2StreamID?,
        targetWindowSize: Int32,
        outboundBytesHighWatermark: Int,
        outboundBytesLowWatermark: Int,
        streamDataType: HTTP2StreamDataType
    ) {
        self.allocator = allocator
        self.closePromise = parent.eventLoop.makePromise()
        self.localAddress = parent.localAddress
        self.remoteAddress = parent.remoteAddress
        self.parent = parent
        self.eventLoop = parent.eventLoop
        self.streamID = streamID
        self.multiplexer = multiplexer
        self.windowManager = InboundWindowManager(targetSize: Int32(targetWindowSize))
        self.flags = NIOLockedValueBox(Flags(isActive: false, isWritable: true))
        self.state = .idle
        self.streamDataType = streamDataType
        self.writabilityManager = StreamChannelFlowController(
            highWatermark: outboundBytesHighWatermark,
            lowWatermark: outboundBytesLowWatermark,
            parentIsWritable: parent.isWritable
        )

        // To begin with we initialize autoRead to false, but we are going to fetch it from our parent before we
        // go much further.
        self.autoRead = false
        self._pipeline = ChannelPipeline(channel: self)
    }

    internal func configure(
        initializer: NIOChannelInitializerWithStreamID?,
        userPromise promise: EventLoopPromise<Channel>?
    ) {
        assert(self.streamDataType == .frame)
        // We need to configure this channel. This involves doing four things:
        // 1. Setting our autoRead state from the parent
        // 2. Calling the initializer, if provided.
        // 3. Activating when complete.
        // 4. Catching errors if they occur.
        self.getAutoReadFromParent { autoReadResult in
            switch autoReadResult {
            case .success(let autoRead):
                self.autoRead = autoRead
                if let initializer = initializer {
                    // This initializer callback can only be invoked if we already have a stream ID.
                    // So we force-unwrap here.
                    initializer(self, self.streamID!).whenComplete { result in
                        self.onInitializationResult(result.map { self }, promise: promise)
                    }
                } else {
                    self.postInitializerActivate(output: self, promise: promise)
                }
            case .failure(let error):
                self.configurationFailed(withError: error, promise: promise)
            }
        }
    }

    internal func configure(initializer: NIOChannelInitializer?, userPromise promise: EventLoopPromise<Channel>?) {
        assert(self.streamDataType == .framePayload)
        // We need to configure this channel. This involves doing four things:
        // 1. Setting our autoRead state from the parent
        // 2. Calling the initializer, if provided.
        // 3. Activating when complete.
        // 4. Catching errors if they occur.
        self.getAutoReadFromParent { autoReadResult in
            switch autoReadResult {
            case .success(let autoRead):
                self.autoRead = autoRead
                if let initializer = initializer {
                    initializer(self).whenComplete { result in
                        self.onInitializationResult(result.map { self }, promise: promise)
                    }
                } else {
                    self.postInitializerActivate(output: self, promise: promise)
                }
            case .failure(let error):
                self.configurationFailed(withError: error, promise: promise)
            }
        }
    }

    // This variant is used in the async stream case.
    // It uses `Any`s because when called from `configureInboundStream` it is passed the initializer stored on the handler
    // which can't be a typed generic without changing the handler API.
    internal func configure(
        initializer: @escaping NIOChannelInitializerWithOutput<any Sendable>,
        userPromise promise: EventLoopPromise<any Sendable>?
    ) {
        assert(self.streamDataType == .framePayload)
        // We need to configure this channel. This involves doing four things:
        // 1. Setting our autoRead state from the parent
        // 2. Calling the initializer, if provided.
        // 3. Activating when complete.
        // 4. Catching errors if they occur.
        self.getAutoReadFromParent { autoReadResult in
            switch autoReadResult {
            case .success(let autoRead):
                self.autoRead = autoRead
                initializer(self).whenComplete { result in
                    self.onInitializationResult(result.map { $0 }, promise: promise)
                }
            case .failure(let error):
                self.configurationFailed(withError: error, promise: promise)
            }
        }
    }

    func onInitializationResult<Output: Sendable>(
        _ initializerResult: Result<Output, Error>,
        promise: EventLoopPromise<Output>?
    ) {
        switch initializerResult {
        case .success(let output):
            self.postInitializerActivate(output: output, promise: promise)
        case .failure(let error):
            self.configurationFailed(withError: error, promise: promise)
        }
    }

    /// Gets the 'autoRead' option from the parent channel and invokes the `body` closure with the
    /// result. This may be done synchronously if the parent `Channel` supports synchronous options.
    private func getAutoReadFromParent(_ body: @Sendable @escaping (Result<Bool, Error>) -> Void) {
        // This force unwrap is safe as parent is assigned in the initializer, and never unassigned.
        // Note we also don't set the value here: the additional `map` causes an extra allocation
        // when using a Swift 5.0 compiler.
        if let syncOptions = self.parent!.syncOptions {
            let autoRead = Result(catching: { try syncOptions.getOption(ChannelOptions.autoRead) })
            body(autoRead)
        } else {
            self.parent!.getOption(ChannelOptions.autoRead).whenComplete { autoRead in
                body(autoRead)
            }
        }
    }

    /// Activates the channel if the parent channel is active and succeeds the given `promise`.
    private func postInitializerActivate<Output: Sendable>(output: Output, promise: EventLoopPromise<Output>?) {
        // This force unwrap is safe as parent is assigned in the initializer, and never unassigned.
        // If parent is not active, we expect to receive a channelActive later.
        if self.parent!.isActive {
            self.performActivation()
        }

        // We aren't using cascade here to avoid the allocations it causes.
        promise?.succeed(output)
    }

    /// Handle any error that occurred during configuration.
    private func configurationFailed<Output: Sendable>(withError error: Error, promise: EventLoopPromise<Output>?) {
        switch self.state {
        case .idle, .localActive, .closed:
            // The stream isn't open on the network, nothing to close.
            self.errorEncountered(error: error)
        case .remoteActive, .active, .closing, .closingNeverActivated:
            // In all of these states the stream is still on the network and we may need to take action.
            self.closedWhileOpen()
        }

        promise?.fail(error)
    }

    /// Activates this channel.
    internal func performActivation() {
        precondition(self.parent?.isActive ?? false, "Parent must be active to activate the child")

        if self.state == .closed || self.state == .closingNeverActivated {
            // We're already closed, or we've been asked to close and are waiting for the network.
            // No need to activate in either case
            return
        }

        self.modifyingState { $0.activate() }
        self.pipeline.fireChannelActive()
        self.tryToAutoRead()
        self.deliverPendingWrites()
    }

    internal func networkActivationReceived() {
        if self.state == .closed {
            // Uh-oh: we got an activation but we think we're closed! We need to send a RST_STREAM frame. We'll only do it if we have a stream ID.
            if let streamID = self.streamID {
                let resetFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(.cancel))
                self.parent?.writeAndFlush(resetFrame, promise: nil)
            }
            return
        }
        self.modifyingState { $0.networkActive() }

        let writabilityChanged = self.flags.withLockedValue {
            if self.writabilityManager.isWritable != $0.isWritable {
                $0.isWritable.toggle()
                return true
            } else {
                return false
            }
        }

        // We have probably delayed telling the user that this channel isn't writable, but we should do
        // it now.
        if writabilityChanged {
            self.pipeline.fireChannelWritabilityChanged()
        }

        // If we got here, we may need to flush some pending reads. Notably we don't call read0 here as
        // we don't actually want to start reading before activation, which tryToRead will refuse to do.
        if self.pendingReads.count > 0 {
            self.tryToRead()
        }
    }

    private var _pipeline: ChannelPipeline!

    public let allocator: ByteBufferAllocator

    private let closePromise: EventLoopPromise<()>

    private let multiplexer: OutboundStreamMultiplexer

    public var closeFuture: EventLoopFuture<Void> {
        self.closePromise.futureResult
    }

    public var pipeline: ChannelPipeline {
        self._pipeline
    }

    public let localAddress: SocketAddress?

    public let remoteAddress: SocketAddress?

    public let parent: Channel?

    @usableFromInline
    func localAddress0() throws -> SocketAddress {
        fatalError()
    }

    @usableFromInline
    func remoteAddress0() throws -> SocketAddress {
        fatalError()
    }

    @usableFromInline
    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            do {
                return self.eventLoop.makeSucceededFuture(try self.setOption0(option, value: value))
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        } else {
            return self.eventLoop.submit { try self.setOption0(option, value: value) }
        }
    }

    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        if self.eventLoop.inEventLoop {
            do {
                return self.eventLoop.makeSucceededFuture(try self.getOption0(option))
            } catch {
                return self.eventLoop.makeFailedFuture(error)
            }
        } else {
            return self.eventLoop.submit { try self.getOption0(option) }
        }
    }

    private func setOption0<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
        self.eventLoop.preconditionInEventLoop()

        switch option {
        case _ as ChannelOptions.Types.AutoReadOption:
            self.autoRead = value as! Bool
        default:
            fatalError("setting option \(option) on HTTP2StreamChannel not supported")
        }
    }

    private func getOption0<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
        self.eventLoop.preconditionInEventLoop()

        switch option {
        case _ as HTTP2StreamChannelOptions.Types.StreamIDOption:
            if let streamID = self.streamID {
                return streamID as! Option.Value
            } else {
                throw NIOHTTP2Errors.noStreamIDAvailable()
            }
        case _ as ChannelOptions.Types.AutoReadOption:
            return self.autoRead as! Option.Value
        default:
            fatalError("option \(option) not supported on HTTP2StreamChannel")
        }
    }

    private struct Flags {
        var isActive: Bool
        var isWritable: Bool
    }

    private let flags: NIOLockedValueBox<Flags>

    public var isWritable: Bool {
        self.flags.withLockedValue { $0.isWritable }
    }

    private var _isActive: Bool {
        self.state == .active || self.state == .closing || self.state == .localActive
    }

    public var isActive: Bool {
        self.flags.withLockedValue { $0.isActive }
    }

    public var _channelCore: ChannelCore {
        self
    }

    public let eventLoop: EventLoop

    internal var streamID: HTTP2StreamID?

    private var state: StreamChannelState

    private var windowManager: InboundWindowManager

    /// If close0 was called but the stream could not synchronously close (because it's currently
    /// active), the promise is stored here until it can be fulfilled.
    private var pendingClosePromise: EventLoopPromise<Void>?

    /// A buffer of pending inbound reads delivered from the parent channel.
    ///
    /// In the future this buffer will be used to manage interactions with read() and even, one day,
    /// with flow control. For now, though, all this does is hold frames until we have set the
    /// channel up.
    private var pendingReads: CircularBuffer<HTTP2Frame> = CircularBuffer(initialCapacity: 8)

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
    private var pendingWrites: MarkedCircularBuffer<(HTTP2StreamData, EventLoopPromise<Void>?)> = MarkedCircularBuffer(
        initialCapacity: 8
    )

    /// A list node used to hold stream channels.
    internal var streamChannelListNode: StreamChannelListNode = StreamChannelListNode()

    /// An object that controls whether this channel should be writable.
    private var writabilityManager: StreamChannelFlowController

    public func register0(promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    func wroteBytes(_ writeSize: Int) {
        self.eventLoop.preconditionInEventLoop()
        if case .changed(newValue: let value) = self.writabilityManager.wroteBytes(writeSize) {
            self.changeWritability(to: value)
        }
    }

    public func write0(_ data: NIOAny, promise userPromise: EventLoopPromise<Void>?) {
        guard self.state != .closed else {
            userPromise?.fail(ChannelError._ioOnClosedChannel)
            return
        }

        let streamData: HTTP2StreamData
        switch self.streamDataType {
        case .frame:
            streamData = .frame(self.unwrapData(data))
        case .framePayload:
            streamData = .framePayload(self.unwrapData(data))
        }

        // For the legacy case we need a promise to attach our flow control callback to.
        //
        // This is no longer needed for the `.inline` stream multiplexer case for which this
        // is all dealt with within the `NIOHTTP2Handler` which calls us back directly
        // via `wroteBytes`.
        //
        // Regardless of whether the write succeeded or failed, we don't count
        // the bytes any longer.
        let promise: EventLoopPromise<Void>?
        let writeSize = streamData.flowControlledSize

        switch self.multiplexer {
        case .inline:
            promise = userPromise
            break  // do nothing at this stage, we'll be called back
        case .legacy:
            promise = userPromise ?? self.eventLoop.makePromise()
            promise!.futureResult.hop(to: self.eventLoop).whenComplete { (_: Result<Void, Error>) in
                self.wroteBytes(writeSize)
            }
        }

        self.pendingWrites.append((streamData, promise))

        // Ok, we can make an outcall now, which means we can safely deal with the flow control.
        if case .changed(newValue: let value) = self.writabilityManager.bufferedBytes(writeSize) {
            self.changeWritability(to: value)
        }
    }

    public func flush0() {
        self.pendingWrites.mark()

        if self._isActive {
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
            promise?.fail(ChannelError._alreadyClosed)
            return
        }

        // Store the pending close promise: it'll be succeeded later.
        if let promise = promise {
            if let pendingPromise = self.pendingClosePromise {
                pendingPromise.futureResult.cascade(to: promise)
            } else {
                self.pendingClosePromise = promise
            }
        }

        switch self.state {
        case .idle, .localActive, .closed:
            // The stream isn't open on the network, just go straight to closed cleanly.
            self.closedCleanly()
        case .remoteActive, .active, .closing, .closingNeverActivated:
            // In all of these states the stream is still on the network and we need to wait.
            self.closedWhileOpen()
        }
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

        self.modifyingState { $0.beginClosing() }
        // We should have a stream ID here, force-unwrap is safe.
        let resetFrame = HTTP2Frame(streamID: self.streamID!, payload: .rstStream(.cancel))
        self.receiveOutboundFrame(resetFrame, promise: nil)
        self.multiplexer.flushStream(self.streamID!)
    }

    private func closedCleanly() {
        guard self.state != .closed else {
            return
        }
        self.modifyingState { $0.completeClosing() }
        self.dropPendingReads()
        self.failPendingWrites(error: ChannelError._eof)
        if let promise = self.pendingClosePromise {
            self.pendingClosePromise = nil
            promise.succeed(())
        }
        self.pipeline.fireChannelInactive()

        self.eventLoop.execute {
            self.removeHandlers(pipeline: self.pipeline)
            self.closePromise.succeed()
            if let streamID = self.streamID {
                self.multiplexer.streamClosed(id: streamID)
            } else {
                self.multiplexer.streamClosed(channelID: ObjectIdentifier(self))
            }
        }
    }

    fileprivate func errorEncountered(error: Error) {
        guard self.state != .closed else {
            return
        }
        self.modifyingState { $0.completeClosing() }
        self.dropPendingReads()
        self.failPendingWrites(error: error)
        if let promise = self.pendingClosePromise {
            self.pendingClosePromise = nil
            promise.fail(error)
        }
        self.pipeline.fireErrorCaught(error)
        self.pipeline.fireChannelInactive()

        self.eventLoop.execute {
            self.removeHandlers(pipeline: self.pipeline)
            self.closePromise.succeed()
            if let streamID = self.streamID {
                self.multiplexer.streamClosed(id: streamID)
            } else {
                self.multiplexer.streamClosed(channelID: ObjectIdentifier(self))
            }
        }
    }

    private func tryToRead() {
        // If there's no read to satisfy, no worries about it.
        guard self.unsatisfiedRead else {
            return
        }

        // If we're not active, we will hold on to these reads.
        guard self._isActive else {
            return
        }

        // If there are no pending reads, do nothing.
        guard self.pendingReads.count > 0 else {
            return
        }

        // Ok, we're satisfying a read here.
        self.unsatisfiedRead = false
        self.deliverPendingReads()
        self.tryToAutoRead()
    }

    private func changeWritability(to newWritability: Bool) {
        self.flags.withLockedValue { $0.isWritable = newWritability }
        self.pipeline.fireChannelWritabilityChanged()
    }

    private func tryToAutoRead() {
        if self.autoRead {
            // If auto-read is turned on, recurse into channelPipeline.read().
            // This cannot recurse indefinitely unless frames are being delivered
            // by the read stacks, which is generally fairly unlikely to continue unbounded.
            self.pipeline.read()
        }
    }
}

// MARK:- Functions used to manage pending reads and writes.
extension HTTP2StreamChannel {
    /// Drop all pending reads.
    private func dropPendingReads() {
        /// We don't need to report the dropped reads, just remove them all.
        self.pendingReads.removeAll(keepingCapacity: true)
    }

    /// Deliver all pending reads to the channel.
    private func deliverPendingReads() {
        assert(self._isActive)
        while self.pendingReads.count > 0 {
            let frame = self.pendingReads.removeFirst()

            let dataLength: Int?

            switch frame.payload {
            case .data(let data):
                dataLength = data.data.readableBytes
            default:
                dataLength = nil
            }

            switch self.streamDataType {
            case .frame:
                self.pipeline.fireChannelRead(frame)
            case .framePayload:
                self.pipeline.fireChannelRead(frame.payload)
            }

            if let size = dataLength, let increment = self.windowManager.bufferedFrameEmitted(size: size) {
                // To have a pending read, we must have a stream ID.
                let frame = HTTP2Frame(streamID: self.streamID!, payload: .windowUpdate(windowSizeIncrement: increment))
                self.receiveOutboundFrame(frame, promise: nil)
                // This flush should really go away, but we need it for now until we sort out window management.
                self.multiplexer.flushStream(self.streamID!)
            }
        }
        self.pipeline.fireChannelReadComplete()
    }

    /// Delivers all pending flushed writes to the parent channel.
    private func deliverPendingWrites() {
        // If there are no pending writes, don't bother with the processing.
        guard self.pendingWrites.hasMark else {
            return
        }

        // Get a streamID from the multiplexer if we haven't got one already.
        if self.streamID == nil {
            self.streamID = self.multiplexer.requestStreamID(forChannel: self)
        }

        while self.pendingWrites.hasMark {
            let (streamData, promise) = self.pendingWrites.removeFirst()
            let frame: HTTP2Frame

            switch streamData {
            case .frame(let f):
                frame = f
            case .framePayload(let payload):
                // This unwrap is okay: we just ensured that `self.streamID` was set above.
                frame = HTTP2Frame(streamID: self.streamID!, payload: payload)
            }

            self.receiveOutboundFrame(frame, promise: promise)
        }
        self.multiplexer.flushStream(self.streamID!)
    }

    /// Fails all pending writes with the given error.
    private func failPendingWrites(error: Error) {
        assert(self.state == .closed)
        while self.pendingWrites.count > 0 {
            self.pendingWrites.removeFirst().1?.fail(error)
        }
    }
}

// MARK:- Functions used to communicate between the `HTTP2StreamMultiplexer` and the `HTTP2StreamChannel`.
extension HTTP2StreamChannel {
    /// Called when a frame is received from the network.
    ///
    /// - Parameters:
    ///   - frame: The `HTTP2Frame` received from the network.
    func receiveInboundFrame(_ frame: HTTP2Frame) {
        guard self.state != .closed else {
            // Do nothing
            return
        }

        // Record the size of the frame so that when we receive a window update event our
        // calculation on whether we emit a WINDOW_UPDATE frame is based on the bytes we have
        // actually delivered into the pipeline.
        if case .data(let dataPayload) = frame.payload {
            self.windowManager.bufferedFrameReceived(size: dataPayload.data.readableBytes)

            // No further window update frames should be sent.
            if dataPayload.endStream {
                self.windowManager.closed = true
            }
        } else if case .headers(let headersPayload) = frame.payload, headersPayload.endStream {
            // No further window update frames should be sent.
            self.windowManager.closed = true
        }

        self.pendingReads.append(frame)
    }

    /// Called when a frame is sent to the network.
    ///
    /// - Parameters:
    ///   - frame: The `HTTP2Frame` to send to the network.
    ///   - promise: The promise associated with the frame write.
    private func receiveOutboundFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        guard self.state != .closed else {
            let error = ChannelError._alreadyClosed
            promise?.fail(error)
            self.errorEncountered(error: error)
            return
        }
        self.multiplexer.writeFrame(frame, promise: promise)
    }

    /// Called when a stream closure is received from the network.
    ///
    /// - Parameters:
    ///   - reason: The reason received from the network, if any.
    func receiveStreamClosed(_ reason: HTTP2ErrorCode?) {
        // Avoid emitting any WINDOW_UPDATE frames now that we're closed.
        self.windowManager.closed = true

        // The stream is closed, we should force forward all pending frames, even without
        // unsatisfied read, to ensure the handlers can see all frames before receiving
        // channelInactive.
        if self.pendingReads.count > 0 && self._isActive {
            self.unsatisfiedRead = false
            self.deliverPendingReads()
        }

        if let reason = reason {
            // To receive from the network, it must be safe to force-unwrap here.
            let err = NIOHTTP2Errors.streamClosed(streamID: self.streamID!, errorCode: reason)
            self.errorEncountered(error: err)
        } else {
            self.closedCleanly()
        }
    }

    func receiveWindowUpdatedEvent(_ windowSize: Int) {
        if let increment = self.windowManager.newWindowSize(windowSize) {
            // To receive from the network, it must be safe to force-unwrap here.
            let frame = HTTP2Frame(streamID: self.streamID!, payload: .windowUpdate(windowSizeIncrement: increment))
            self.receiveOutboundFrame(frame, promise: nil)
            // This flush should really go away, but we need it for now until we sort out window management.
            self.multiplexer.flushStream(self.streamID!)
        }
    }

    func initialWindowSizeChanged(delta: Int) {
        if let increment = self.windowManager.initialWindowSizeChanged(delta: delta) {
            // To receive from the network, it must be safe to force-unwrap here.
            let frame = HTTP2Frame(streamID: self.streamID!, payload: .windowUpdate(windowSizeIncrement: increment))
            self.receiveOutboundFrame(frame, promise: nil)
            // This flush should really go away, but we need it for now until we sort out window management.
            self.multiplexer.flushStream(self.streamID!)
        }
    }

    func receiveParentChannelReadComplete() {
        self.tryToRead()
    }

    func parentChannelWritabilityChanged(newValue: Bool) {
        // There's a trick here that's worth noting: if the child channel hasn't either sent a frame
        // or been activated on the network, we don't actually want to change the observable writability.
        // This is because in this case we really want user code to send a frame as soon as possible to avoid
        // issues with their stream ID becoming out of date. Once the state transitions we can update
        // the writability if needed.
        guard case .changed(newValue: let localValue) = self.writabilityManager.parentWritabilityChanged(newValue)
        else {
            return
        }

        // Ok, the writability changed.
        switch self.state {
        case .idle, .localActive:
            // Do nothing here.
            return
        case .remoteActive, .active, .closing, .closingNeverActivated, .closed:
            self.flags.withLockedValue { $0.isWritable = localValue }
            self.pipeline.fireChannelWritabilityChanged()
        }
    }

    func receiveStreamError(_ error: NIOHTTP2Errors.StreamError) {
        assert(error.streamID == self.streamID)
        self.pipeline.fireErrorCaught(error.baseError)
    }
}

extension HTTP2StreamChannel {
    // A helper function used to ensure that state modification leads to changes in the channel active atomic.
    private func modifyingState<ReturnType>(
        _ closure: (inout StreamChannelState) throws -> ReturnType
    ) rethrows -> ReturnType {
        defer {
            self.flags.withLockedValue { $0.isActive = self._isActive }
        }
        return try closure(&self.state)
    }
}

// MARK: Custom String Convertible
extension HTTP2StreamChannel {
    public var description: String {
        "HTTP2StreamChannel(streamID: \(String(describing: self.streamID)), isActive: \(self.isActive), isWritable: \(self.isWritable))"
    }
}

extension HTTP2StreamChannel {
    internal struct SynchronousOptions: NIOSynchronousChannelOptions {
        private let channel: HTTP2StreamChannel

        fileprivate init(channel: HTTP2StreamChannel) {
            self.channel = channel
        }

        /// Set `option` to `value` on this `Channel`.
        ///
        /// - Important: Must be called on the `EventLoop` the `Channel` is running on.
        public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
            try self.channel.setOption0(option, value: value)
        }

        /// Get the value of `option` for this `Channel`.
        ///
        /// - Important: Must be called on the `EventLoop` the `Channel` is running on.
        public func getOption<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
            try self.channel.getOption0(option)
        }
    }

    /// Returns a view of the `Channel` exposing synchronous versions of `setOption` and `getOption`.
    public var syncOptions: NIOSynchronousChannelOptions? {
        SynchronousOptions(channel: self)
    }
}
