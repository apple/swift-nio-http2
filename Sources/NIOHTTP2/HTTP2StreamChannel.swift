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
    public typealias OptionType = Int

    case const(Void)
}

/// The various channel options specific to `HTTP2StreamChannel`s.
///
/// Please note that some of NIO's regular `ChannelOptions` are valid on `HTTP2StreamChannel`s.
public struct HTTP2StreamChannelOptions {
    /// - seealso: `StreamIDOption`.
    public static let streamID: StreamIDOption = .const(())
}


/// The current state of a stream.
///
/// This state structure provides a state machine to keep track of stream state. This is used only
/// to track the channel active state: it does not provide a complete HTTP/2 state enforcement state
/// machine. In particular, this state machine does not prevent many kinds of message ordering issues:
/// for example, it allows sending DATA frames before the stream is open. This kind of error will be
/// caught in other parts of the channel and failed appropriately.
fileprivate struct StreamState {
    private enum State {
        case idle
        case reservedLocal
        case reservedRemote
        case open
        case halfClosedLocal
        case halfClosedRemote
        case closed
    }

    /// The state-affecting inputs.
    private enum Input {
        case headersReceived
        case endStreamReceived
        case pushPromiseReceived
        case rstStreamReceived
        case headersSent
        case endStreamSent
        case pushPromiseSent
        case rstStreamSent
    }

    fileprivate typealias Action = @convention(thin) (HTTP2StreamChannel) -> Void

    private static let noCallout: Action = { (channel: HTTP2StreamChannel) in }

    /// The current state of the stream.
    private var state = State.idle

    /// Whether the stream is in an "active" state, such that some frames can be sent or received.
    var isActive: Bool {
        switch self.state {
        case .idle, .closed:
            return false
        case .reservedLocal, .reservedRemote, .open, .halfClosedLocal, .halfClosedRemote:
            return true
        }
    }

    /// Whether the stream is entirely closed. Idle does not count.
    var isClosed: Bool {
        return self.state == .closed
    }

    mutating func receivedFrame(frame: HTTP2Frame) throws -> Action {
        switch frame.payload {
        case .headers:
            assert(frame.endHeaders, "Fragmented headers frame received!")
            return try self.processInput(.headersReceived)
        case .continuation:
            preconditionFailure("Received unexpected CONTINUATION frame")
        case .pushPromise:
            assert(frame.endHeaders, "Fragmented PUSH_PROMISE frame received!")
            return try self.processInput(.pushPromiseReceived)
        case .rstStream:
            return try self.processInput(.rstStreamReceived)
        default:
            // Does not affect state.
            return { (channel: HTTP2StreamChannel) in }
        }
    }

    mutating func receivedEndStream() throws -> Action {
        return try self.processInput(.endStreamReceived)
    }

    mutating func sentFrame(frame: HTTP2Frame) throws -> Action {
        switch frame.payload {
        case .headers:
            assert(frame.endHeaders, "Fragmented headers frame sent!")
            return try self.processInput(.headersSent)
        case .continuation:
            preconditionFailure("Sent unexpected CONTINUATION frame")
        case .pushPromise:
            assert(frame.endHeaders, "Fragmented PUSH_PROMISE frame sent!")
            return try self.processInput(.pushPromiseSent)
        case .rstStream:
            return try self.processInput(.rstStreamSent)
        default:
            // Does not affect state.
            return { (channel: HTTP2StreamChannel) in }
        }
    }

    mutating func sentEndStream() throws -> Action {
        return try self.processInput(.endStreamSent)
    }

    /// Tells the state machine the user has elected to close the stream directly, without
    /// emitting a frame. Triggers the appropriate actions based on stream state.
    mutating func closedByUser() throws -> Action {
        // TODO(cory): This should tell the stream to emit a RSTSTREAM frame when appropriate.
        switch (self.state) {
        case .idle:
            // Stream was never opened, we can close directly.
            self.state = .closed
            return StreamState.noCallout
        case .reservedLocal, .reservedRemote, .open, .halfClosedLocal, .halfClosedRemote:
            // Stream is currently open, we must become inactive and emit a RST_STREAM frame.
            // TODO: RST_STREAM!
            self.state = .closed
            return { (channel: HTTP2StreamChannel) in channel.becomeInactive() }
        case .closed:
            // We are already closed, this action should error.
            throw ChannelError.alreadyClosed
        }
    }

    private mutating func processInput(_ input: Input) throws -> Action  {
        switch (self.state, input) {
        case (.idle, .headersReceived),
             (.idle, .headersSent):
            self.state = .open
            return { (channel: HTTP2StreamChannel) in channel.becomeActive() }
        case (.idle, .pushPromiseReceived):
            self.state = .reservedRemote
            return { (channel: HTTP2StreamChannel) in channel.becomeActive() }
        case (.idle, .pushPromiseSent):
            self.state = .reservedLocal
            return { (channel: HTTP2StreamChannel) in channel.becomeActive() }

        case (.reservedLocal, .headersSent):
            self.state = .halfClosedRemote
            return StreamState.noCallout
        case (.reservedLocal, .rstStreamSent),
             (.reservedLocal, .rstStreamReceived):
            self.state = .closed
            return { (channel: HTTP2StreamChannel) in channel.becomeInactive() }

        case (.reservedRemote, .headersReceived):
            self.state = .halfClosedLocal
            return StreamState.noCallout
        case (.reservedRemote, .rstStreamSent),
             (.reservedRemote, .rstStreamReceived):
            self.state = .closed
            return { (channel: HTTP2StreamChannel) in channel.becomeInactive() }

        case (.open, .headersSent),
             (.open, .headersReceived):
            // No state transition here, these frames are allowed.
            return StreamState.noCallout
        case (.open, .endStreamSent):
            self.state = .halfClosedLocal
            return StreamState.noCallout
        case (.open, .endStreamReceived):
            self.state = .halfClosedRemote
            return StreamState.noCallout
        case (.open, .rstStreamSent),
             (.open, .rstStreamReceived):
            self.state = .closed
            return { (channel: HTTP2StreamChannel) in channel.becomeInactive() }

        case (.halfClosedRemote, .headersSent):
            // No state transition, allowed to send headers in half-closed remote.
            return StreamState.noCallout
        case (.halfClosedRemote, .endStreamSent),
             (.halfClosedRemote, .rstStreamSent),
             (.halfClosedRemote, .rstStreamReceived):
            self.state = .closed
            return { (channel: HTTP2StreamChannel) in channel.becomeInactive() }

        case (.halfClosedLocal, .headersReceived):
            // No state transition, allowed to receive headers in half-closed local.
            return StreamState.noCallout
        case (.halfClosedLocal, .endStreamReceived),
             (.halfClosedLocal, .rstStreamSent),
             (.halfClosedLocal, .rstStreamReceived):
            self.state = .closed
            return { (channel: HTTP2StreamChannel) in channel.becomeInactive() }

        // The following state transitions aren't legal, they take the system out.
        // There are no valid transitions from the closed state.
        case (.idle, .endStreamReceived),
             (.idle, .rstStreamReceived),
             (.idle, .endStreamSent),
             (.idle, .rstStreamSent),
             (.reservedLocal, .headersReceived),
             (.reservedLocal, .pushPromiseSent),
             (.reservedLocal, .pushPromiseReceived),
             (.reservedLocal, .endStreamReceived),
             (.reservedLocal, .endStreamSent),
             (.reservedRemote, .headersSent),
             (.reservedRemote, .pushPromiseSent),
             (.reservedRemote, .pushPromiseReceived),
             (.reservedRemote, .endStreamReceived),
             (.reservedRemote, .endStreamSent),
             (.open, .pushPromiseSent),
             (.open, .pushPromiseReceived),
             (.halfClosedRemote, .headersReceived),
             (.halfClosedRemote, .pushPromiseSent),
             (.halfClosedRemote, .pushPromiseReceived),
             (.halfClosedRemote, .endStreamReceived),
             (.halfClosedLocal, .headersSent),
             (.halfClosedLocal, .pushPromiseSent),
             (.halfClosedLocal, .pushPromiseReceived),
             (.halfClosedLocal, .endStreamSent),
             (.closed, _):
            throw HTTP2StreamChannelError.invalidFrameOrdering
        }
    }
}


/// Errors that can be thrown from the `HTTP2StreamChannel`.
public enum HTTP2StreamChannelError: Error {
    /// The order of frames sent and received on the `HTTP2StreamChannel` is invalid.
    case invalidFrameOrdering
}


final class HTTP2StreamChannel: Channel, ChannelCore {
    public init(allocator: ByteBufferAllocator, parent: Channel, streamID: HTTP2StreamID, initializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)?) {
        self.allocator = allocator
        self.closePromise = parent.eventLoop.newPromise()
        self.localAddress = parent.localAddress
        self.remoteAddress = parent.remoteAddress
        self.parent = parent
        self.eventLoop = parent.eventLoop
        self.streamID = streamID
        // FIXME: that's just wrong
        self.isWritable = true
        self.isActive = true
        self.state = StreamState()
        self._pipeline = ChannelPipeline(channel: self)

        // TODO(cory): This needs to do some state management, but we can't until we do the proper interface for communicating between
        // the multiplexer and this channel.
        _ = initializer?(self, self.streamID)
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

    func setOption<T>(option: T, value: T.OptionType) -> EventLoopFuture<Void> where T : ChannelOption {
        fatalError()
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

    func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)

        switch option {
        case _ as StreamIDOption:
            return self.streamID as! T.OptionType
        default:
            fatalError("option \(option) not supported")
        }
    }

    public let isWritable: Bool

    public let isActive: Bool

    public var _unsafe: ChannelCore {
        return self
    }

    public let eventLoop: EventLoop

    private let streamID: HTTP2StreamID

    private var state: StreamState

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
        let frame = self.unwrapData(data, as: HTTP2Frame.self)
        self.receiveOutboundFrame(frame, promise: promise)
    }

    public func flush0() {
        self.parent?.flush()
    }

    public func read0() {
        fatalError("not implemented \(#function)")
    }

    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        do {
            let callout = try self.state.closedByUser()
            promise?.succeed(result: ())
            callout(self)
        } catch {
            promise?.fail(error: error)
        }
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func channelRead0(_ data: NIOAny) {
        // do nothing
    }

    public func errorCaught0(error: Error) {
        fatalError("not implemented \(#function)")
    }

    private func closeFromStateMachine() {
        // This should only be called if the state machine believes we are closed.
        assert(self.state.isClosed)
        self.pipeline.fireChannelInactive()
        self.closePromise.succeed(result: ())
    }
}


private extension HTTP2StreamChannel {
    /// A context manager that closes the channel if an error is hit.
    ///
    /// - parameters:
    ///     - promise: A promise to fail if the body throws.
    ///     - body: The code to execute and catch errors for.
    private func closeOnError(promise: EventLoopPromise<Void>?, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            promise?.fail(error: error)
            self.close0(error: error, mode: .all, promise: nil)
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
        self.closeOnError(promise: nil) {
            try self.state.receivedFrame(frame: frame)(self)
            if frame.endStream {
                try self.state.receivedEndStream()(self)
            }
            self.pipeline.fireChannelRead(NIOAny(frame))
        }
    }

    /// Called when a frame is sent to the network.
    ///
    /// - parameters:
    ///     - frame: The `HTTP2Frame` to send to the network.
    ///     - promise: The promise associated with the frame write.
    private func receiveOutboundFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        self.closeOnError(promise: promise) {
            try self.state.sentFrame(frame: frame)(self)
            if frame.endStream {
                try self.state.sentEndStream()(self)
            }
            guard let parent = self.parent else {
                assert(!self.isActive)
                throw ChannelError.alreadyClosed
            }
            parent.write(frame, promise: promise)
        }
    }
}

// MARK:- Methods used to communicate between the `StreamState` and `HTTP2StreamChannel` objects.
fileprivate extension HTTP2StreamChannel {
    /// Called when a frame has been sent or received that makes the channel active.
    fileprivate func becomeActive() {
        self.pipeline.fireChannelActive()
    }

    /// Called when a frame has been sent or received that makes the channel inactive.
    fileprivate func becomeInactive() {
        self.closeFromStateMachine()
    }
}
