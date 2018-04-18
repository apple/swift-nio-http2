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


final class HTTP2StreamChannel: Channel, ChannelCore {
    public init(allocator: ByteBufferAllocator, parent: Channel, streamID: Int32, initializer: ((Channel, Int) -> EventLoopFuture<Void>)?) {
        self.allocator = allocator
        self.closePromise = parent.eventLoop.newPromise()
        self.localAddress = parent.localAddress
        self.remoteAddress = parent.remoteAddress
        self.parent = parent
        self.eventLoop = parent.eventLoop
        self.streamID = Int(streamID)
        // FIXME: that's just wrong
        self.isWritable = true
        self.isActive = true
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

    private let streamID: Int

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
        fatalError("not implemented \(#function)")
    }

    public func flush0() {
        self.parent?.flush()
    }

    public func read0() {
        fatalError("not implemented \(#function)")
    }

    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // FIXME: nothing?
        promise?.succeed(result: ())
        self.closePromise.succeed(result: ())
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
}


