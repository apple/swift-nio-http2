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


/// The current state of a stream channel.
private enum StreamChannelState {
    case idle
    case active
    case closed
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
        self.state = .idle
        self._pipeline = ChannelPipeline(channel: self)

        let initializingFuture: EventLoopFuture<Void> = initializer?(self, self.streamID) ?? self.eventLoop.newSucceededFuture(result: ())
        initializingFuture.map {
            self.state = .active
            self.pipeline.fireChannelActive()
        }.whenFailure {
            self.errorEncountered(error: $0)
        }
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

    public var isActive: Bool {
        return self.state == .active
    }

    public var _unsafe: ChannelCore {
        return self
    }

    public let eventLoop: EventLoop

    private let streamID: HTTP2StreamID

    private var state: StreamChannelState

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
        // TODO(cory): In some cases this should emit RST_STREAM frames.
        self.closedCleanly(promise: promise)
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        fatalError("not implemented \(#function)")
    }

    public func channelRead0(_ data: NIOAny) {
        // do nothing
    }

    public func errorCaught0(error: Error) {
        // do nothing
    }

    private func closedCleanly(promise: EventLoopPromise<Void>?) {
        guard self.state != .closed else {
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }
        self.state = .closed
        promise?.succeed(result: ())
        self.pipeline.fireChannelInactive()
        self.closePromise.succeed(result: ())
    }

    fileprivate func errorEncountered(error: Error) {
        guard self.state != .closed else {
            return
        }
        self.state = .closed
        self.pipeline.fireErrorCaught(error)
        self.pipeline.fireChannelInactive()
        self.closePromise.fail(error: error)
    }
}

// MARK:- Functions used to communicate between the `HTTP2StreamMultiplexer` and the `HTTP2StreamChannel`.
internal extension HTTP2StreamChannel {
    /// Called when a frame is received from the network.
    ///
    /// - parameters:
    ///     - frame: The `HTTP2Frame` received from the network.
    internal func receiveInboundFrame(_ frame: HTTP2Frame) {
        self.pipeline.fireChannelRead(NIOAny(frame))
    }

    /// Called when a frame is sent to the network.
    ///
    /// - parameters:
    ///     - frame: The `HTTP2Frame` to send to the network.
    ///     - promise: The promise associated with the frame write.
    private func receiveOutboundFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        guard let parent = self.parent else {
            assert(!self.isActive)
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
            self.closedCleanly(promise: nil)
        }
    }
}

