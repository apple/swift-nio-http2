//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// swift-format-ignore: NoBlockComments
/*
 * Copyright 2024, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import NIOCore
import NIOTLS

/// A `ChannelHandler` which manages the lifecycle of an HTTP/2 connection.
///
/// This handler is responsible for managing several aspects of the connection. These include:
/// 1. Handling the graceful close of connections. When gracefully closing a connection the server
///    sends a GOAWAY frame with the last stream ID set to the maximum stream ID allowed followed by
///    a PING frame. On receipt of the PING frame the server sends another GOAWAY frame with the
///    highest ID of all streams which have been opened. After this, the handler closes the
///    connection once all streams are closed.
/// 2. Enforcing that graceful shutdown doesn't exceed a configured limit (if configured).
/// 3. Gracefully closing the connection once it reaches the maximum configured age (if configured).
/// 4. Gracefully closing the connection once it has been idle for a given period of time (if
///    configured).
/// 5. Periodically sending keep alive pings to the client (if configured) and closing the
///    connection if necessary.
public final class NIOHTTP2ServerConnectionManagementHandler: ChannelDuplexHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    /// The `EventLoop` of the `Channel` this handler exists in.
    private let eventLoop: any EventLoop

    /// The timer used to gracefully close idle connections.
    private var maxIdleTimerHandler: Timer<MaxIdleTimerHandlerView>?

    /// The timer used to gracefully close old connections.
    private var maxAgeTimerHandler: Timer<MaxAgeTimerHandlerView>?

    /// The timer used to forcefully close a connection during a graceful close.
    /// The timer starts after the second GOAWAY frame has been sent.
    private var maxGraceTimerHandler: Timer<MaxGraceTimerHandlerView>?

    /// The timer used to send keep-alive pings.
    private var keepaliveTimerHandler: Timer<KeepaliveTimerHandlerView>?

    /// The timer used to detect keep alive timeouts, if keep-alive pings are enabled.
    private var keepaliveTimeoutHandler: Timer<KeepaliveTimeoutHandlerView>?

    /// Opaque data sent in keep alive pings.
    private let keepalivePingData: HTTP2PingData

    /// Whether a flush is pending.
    private var flushPending: Bool

    /// Whether `channelRead` has been called and `channelReadComplete` hasn't yet been called.
    /// Resets once `channelReadComplete` returns.
    private var inReadLoop: Bool

    /// The context of the channel this handler is in.
    private var context: ChannelHandlerContext?

    /// The current state of the connection.
    private var state: StateMachine

    /// Configuration parameters for ``NIOHTTP2ServerConnectionManagementHandler``.
    ///
    /// This configuration provides several ways to manage the lifetime of HTTP/2 connections:
    /// - When `maxIdleTime` is set, graceful shutdown will be triggered when the connection has had no active streams
    ///   for the specified duration.
    /// - When `maxAge` is set, graceful shutdown will be triggered when the connection has been alive for the specified
    ///   duration.
    /// - When `maxGraceTime` is set, the connection will be forcefully closed if active streams don't finish within the
    ///   specified duration after graceful shutdown is triggered.
    /// - When `keepalive` is set, clients will be periodically pinged to verify they're still responsive; unresponsive
    ///   clients will trigger graceful connection closure.
    ///
    /// Each parameter is optional; when set to `nil`, that particular behavior is disabled.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let configuration = NIOHTTP2ServerConnectionManagementHandler.Configuration(
    ///     maxIdleTime: .minutes(5),
    ///     maxAge: .hours(1),
    ///     maxGraceTime: .seconds(20),
    ///     keepalive: .init(pingInterval: .seconds(30), ackTimeout: .seconds(20))
    /// )
    /// ```
    ///
    /// This configuration:
    /// - Closes idle connections after 5 minutes;
    /// - Closes connections that have been active for 1 hour regardless of activity;
    /// - Forces connection closure after 20 seconds if active streams haven't finished after graceful shutdown is
    ///   triggered;
    /// - Sends keep-alive pings every 30 seconds with a 20 second response timeout.
    ///
    /// The created configuration can then be used to initialize a ``NIOHTTP2ServerConnectionManagementHandler``
    /// instance:
    ///
    /// ```swift
    /// let handler = NIOHTTP2ServerConnectionManagementHandler(
    ///     eventLoop: eventLoop,
    ///     configuration: configuration
    /// )
    /// ```
    public struct Configuration: Sendable {
        /// The maximum amount of time a connection may be idle for before being closed. When `nil`, connections can
        /// remain idle indefinitely.
        public var maxIdleTime: TimeAmount?

        /// The maximum amount of time a connection may exist before being gracefully closed. When `nil`, connections
        /// can live indefinitely.
        public var maxAge: TimeAmount?

        /// The maximum amount of time that the connection has to close gracefully. When `nil`, no time
        /// limit is enforced for active streams to finish during graceful shutdown.
        public var maxGraceTime: TimeAmount?

        /// Configuration for keep-alive ping behavior. Defaults to `nil`, disabling keep-alive pings.
        public var keepalive: Keepalive?

        /// Configuration for HTTP/2 keep-alive ping behavior.
        ///
        /// Keep-alive pings verify that the client is still responsive by periodically sending pings and expecting
        /// acknowledgements. If the client responds within the specified timeout, the connection remains open.
        /// Otherwise, the connection is shut down.
        public struct Keepalive: Sendable, Hashable {
            /// The amount of time to wait after reading data before sending a keep-alive ping.
            public var pingInterval: TimeAmount

            /// The amount of time the client has to reply after the server sends a keep-alive ping to keep the
            /// connection open. The connection is closed if no reply is received.
            public var ackTimeout: TimeAmount

            /// - Parameters:
            ///   - pingInterval: The amount of time to wait after reading data before sending a keep-alive ping.
            ///   - ackTimeout: The amount of time the client has to reply after the server sends a keep-alive ping to
            ///     keep the connection open. The connection is closed if no reply is received.
            public init(pingInterval: TimeAmount, ackTimeout: TimeAmount) {
                self.pingInterval = pingInterval
                self.ackTimeout = ackTimeout
            }
        }

        /// - Parameters:
        ///   - maxIdleTime: The maximum amount of time a connection may be idle for before being closed. When `nil`,
        ///     connections can remain idle indefinitely.
        ///   - maxAge: The maximum amount of time a connection may exist before being gracefully closed. When `nil`,
        ///     connections can live indefinitely.
        ///   - maxGraceTime: The maximum amount of time that the connection has to close gracefully. When `nil`, no
        ///     time limit is enforced for active streams to finish during graceful shutdown.
        ///   - keepalive: Configuration for keep-alive ping behavior. Defaults to `nil`, disabling keep-alive pings.
        public init(
            maxIdleTime: TimeAmount?,
            maxAge: TimeAmount?,
            maxGraceTime: TimeAmount?,
            keepalive: Keepalive?
        ) {
            self.maxIdleTime = maxIdleTime
            self.maxAge = maxAge
            self.maxGraceTime = maxGraceTime
            self.keepalive = keepalive
        }

        /// A recommended default configuration.
        ///
        /// This configuration enforces a 5 minute limit for active streams to finish during graceful shutdown and
        /// sends keep-alive pings every 2 hours with a 20 second response timeout. Both maximum connection idle time
        /// and connection age limit are disabled.
        public static var defaults: Self {
            Self(
                maxIdleTime: nil,
                maxAge: nil,
                maxGraceTime: .minutes(5),
                keepalive: .init(pingInterval: .hours(2), ackTimeout: .seconds(20))
            )
        }
    }

    /// Creates a new handler which manages the lifecycle of a connection.
    ///
    /// - Parameters:
    ///   - eventLoop: The `EventLoop` of the `Channel` this handler is placed in.
    ///   - configuration: Configuration parameters for managing the connection lifecycle.
    public init(eventLoop: any EventLoop, configuration: Configuration) {
        self.eventLoop = eventLoop

        // Generate a random value to be used as keep alive ping data.
        let pingData = UInt64.random(in: .min ... .max)
        self.keepalivePingData = HTTP2PingData(withInteger: pingData)

        self.state = StateMachine(goAwayPingData: HTTP2PingData(withInteger: ~pingData))

        self.flushPending = false
        self.inReadLoop = false

        if let maxIdleTime = configuration.maxIdleTime {
            self.maxIdleTimerHandler = Timer(
                eventLoop: eventLoop,
                duration: maxIdleTime,
                handler: MaxIdleTimerHandlerView(self)
            )
        }
        if let maxAge = configuration.maxAge {
            self.maxAgeTimerHandler = Timer(
                eventLoop: eventLoop,
                duration: maxAge,
                handler: MaxAgeTimerHandlerView(self)
            )
        }
        if let maxGraceTime = configuration.maxGraceTime {
            self.maxGraceTimerHandler = Timer(
                eventLoop: eventLoop,
                duration: maxGraceTime,
                handler: MaxGraceTimerHandlerView(self)
            )
        }

        if let keepaliveConfiguration = configuration.keepalive {
            self.keepaliveTimerHandler = Timer(
                eventLoop: eventLoop,
                duration: keepaliveConfiguration.pingInterval,
                handler: KeepaliveTimerHandlerView(self)
            )
            self.keepaliveTimeoutHandler = Timer(
                eventLoop: eventLoop,
                duration: keepaliveConfiguration.ackTimeout,
                handler: KeepaliveTimeoutHandlerView(self)
            )
        }
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        context.eventLoop.preconditionInEventLoop()
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    public func channelActive(context: ChannelHandlerContext) {
        self.maxAgeTimerHandler?.start()
        self.maxIdleTimerHandler?.start()
        self.keepaliveTimerHandler?.start()
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.maxIdleTimerHandler?.cancel()
        self.maxIdleTimerHandler = nil

        self.maxAgeTimerHandler?.cancel()
        self.maxAgeTimerHandler = nil

        self.maxGraceTimerHandler?.cancel()
        self.maxGraceTimerHandler = nil

        self.keepaliveTimerHandler?.cancel()
        self.keepaliveTimerHandler = nil

        self.keepaliveTimeoutHandler?.cancel()
        self.keepaliveTimeoutHandler = nil

        context.fireChannelInactive()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as NIOHTTP2StreamCreatedEvent:
            self._streamCreated(event.streamID)

        case let event as StreamClosedEvent:
            self._streamClosed(event.streamID)

        case is ChannelShouldQuiesceEvent:
            self.initiateGracefulShutdown()

        default:
            ()
        }

        context.fireUserInboundEventTriggered(event)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.inReadLoop = true

        // Any read data indicates that the connection is alive so cancel the keep-alive timers.
        self.keepaliveTimerHandler?.cancel()
        self.keepaliveTimeoutHandler?.cancel()

        let frame = self.unwrapInboundIn(data)
        switch frame.payload {
        case .ping(let data, let ack) where ack == true:
            self.handlePingAck(context: context, data: data)

        default:
            // Only interested in PING frames with the ACK flag set.
            // NIOHTTP2Handler handles all other frames (including PING frames where the ACK flag is *not* set), so we
            // can ignore them here.
            ()
        }

        context.fireChannelRead(data)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        while self.flushPending {
            self.flushPending = false
            context.flush()
        }

        self.inReadLoop = false

        // Done reading: schedule the keep-alive timer.
        self.keepaliveTimerHandler?.start()

        context.fireChannelReadComplete()
    }

    public func flush(context: ChannelHandlerContext) {
        self.maybeFlush(context: context)
    }
}

// Timer handler views.
extension NIOHTTP2ServerConnectionManagementHandler {
    struct MaxIdleTimerHandlerView: Sendable, NIOScheduledCallbackHandler {
        private let handler: NIOLoopBound<NIOHTTP2ServerConnectionManagementHandler>

        init(_ handler: NIOHTTP2ServerConnectionManagementHandler) {
            self.handler = .init(handler, eventLoop: handler.eventLoop)
        }

        func handleScheduledCallback(eventLoop: some EventLoop) {
            self.handler.value.initiateGracefulShutdown()
        }
    }

    struct MaxAgeTimerHandlerView: Sendable, NIOScheduledCallbackHandler {
        private let handler: NIOLoopBound<NIOHTTP2ServerConnectionManagementHandler>

        init(_ handler: NIOHTTP2ServerConnectionManagementHandler) {
            self.handler = .init(handler, eventLoop: handler.eventLoop)
        }

        func handleScheduledCallback(eventLoop: some EventLoop) {
            self.handler.value.initiateGracefulShutdown()
        }
    }

    struct MaxGraceTimerHandlerView: Sendable, NIOScheduledCallbackHandler {
        private let handler: NIOLoopBound<NIOHTTP2ServerConnectionManagementHandler>

        init(_ handler: NIOHTTP2ServerConnectionManagementHandler) {
            self.handler = .init(handler, eventLoop: handler.eventLoop)
        }

        func handleScheduledCallback(eventLoop: some EventLoop) {
            self.handler.value.context?.close(promise: nil)
        }
    }

    struct KeepaliveTimerHandlerView: Sendable, NIOScheduledCallbackHandler {
        private let handler: NIOLoopBound<NIOHTTP2ServerConnectionManagementHandler>

        init(_ handler: NIOHTTP2ServerConnectionManagementHandler) {
            self.handler = .init(handler, eventLoop: handler.eventLoop)
        }

        func handleScheduledCallback(eventLoop: some EventLoop) {
            self.handler.value.keepaliveTimerFired()
        }
    }

    struct KeepaliveTimeoutHandlerView: Sendable, NIOScheduledCallbackHandler {
        private let handler: NIOLoopBound<NIOHTTP2ServerConnectionManagementHandler>

        init(_ handler: NIOHTTP2ServerConnectionManagementHandler) {
            self.handler = .init(handler, eventLoop: handler.eventLoop)
        }

        func handleScheduledCallback(eventLoop: some EventLoop) {
            self.handler.value.initiateGracefulShutdown()
        }
    }
}

extension NIOHTTP2ServerConnectionManagementHandler {
    /// A delegate for receiving HTTP/2 stream lifecycle events.
    public struct HTTP2StreamDelegate: Sendable, NIOHTTP2StreamDelegate {
        private let handler: NIOLoopBound<NIOHTTP2ServerConnectionManagementHandler>

        init(_ handler: NIOHTTP2ServerConnectionManagementHandler) {
            self.handler = .init(handler, eventLoop: handler.eventLoop)
        }

        /// Notifies the handler that a new HTTP/2 stream was created.
        /// - Parameters:
        ///   - id: The ID of the created stream.
        ///   - channel: The channel on which the stream was created.
        public func streamCreated(_ id: HTTP2StreamID, channel: any Channel) {
            if self.handler.eventLoop.inEventLoop {
                self.handler.value._streamCreated(id)
            } else {
                self.handler.eventLoop.execute {
                    self.handler.value._streamCreated(id)
                }
            }
        }

        /// Notifies the handler that an HTTP/2 stream was closed.
        /// - Parameters:
        ///   - id: The ID of the closed stream.
        ///   - channel: The channel on which the stream was closed.
        public func streamClosed(_ id: HTTP2StreamID, channel: any Channel) {
            if self.handler.eventLoop.inEventLoop {
                self.handler.value._streamClosed(id)
            } else {
                self.handler.eventLoop.execute {
                    self.handler.value._streamClosed(id)
                }
            }
        }
    }

    public var http2StreamDelegate: HTTP2StreamDelegate {
        HTTP2StreamDelegate(self)
    }

    private func _streamCreated(_ id: HTTP2StreamID) {
        // The connection isn't idle if a stream is open.
        self.maxIdleTimerHandler?.cancel()
        self.state.streamOpened(id)
    }

    private func _streamClosed(_ id: HTTP2StreamID) {
        guard let context = self.context else { return }

        switch self.state.streamClosed(id) {
        case .startIdleTimer:
            self.maxIdleTimerHandler?.start()
        case .close:
            // Defer closing until the next tick of the event loop.
            //
            // This point is reached because the server is shutting down gracefully and the stream count
            // has dropped to zero, meaning the connection is no longer required and can be closed.
            // However, the stream would've been closed by writing and flushing a frame with end stream
            // set. These are two distinct events in the channel pipeline. The HTTP/2 handler updates the
            // state machine when a frame is written, which in this case results in the stream closed
            // event which we're reacting to here.
            //
            // Importantly the HTTP/2 handler hasn't yet seen the flush event, so the bytes of the frame
            // with end-stream set - and potentially some other frames - are sitting in a buffer in the
            // HTTP/2 handler. If we close on this event loop tick then those frames will be dropped.
            // Delaying the close by a loop tick will allow the flush to happen before the close.
            let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.eventLoop.execute {
                loopBound.value.close(mode: .all, promise: nil)
            }

        case .none:
            ()
        }
    }
}

extension NIOHTTP2ServerConnectionManagementHandler {
    private func maybeFlush(context: ChannelHandlerContext) {
        if self.inReadLoop {
            self.flushPending = true
        } else {
            context.flush()
        }
    }

    private func initiateGracefulShutdown() {
        guard let context = self.context else { return }
        context.eventLoop.assertInEventLoop()

        // Cancel any timers if initiating shutdown.
        self.maxIdleTimerHandler?.cancel()
        self.maxAgeTimerHandler?.cancel()
        self.keepaliveTimerHandler?.cancel()
        self.keepaliveTimeoutHandler?.cancel()

        switch self.state.startGracefulShutdown() {
        case .sendGoAwayAndPing(let pingData):
            // There's a time window between the server sending a GOAWAY frame and the client receiving
            // it. During this time the client may open new streams as it doesn't yet know about the
            // GOAWAY frame.
            //
            // The server therefore sends a GOAWAY with the last stream ID set to the maximum stream ID
            // and follows it with a PING frame. When the server receives the ack for the PING frame it
            // knows that the client has received the initial GOAWAY frame and that no more streams may
            // be opened. The server can then send an additional GOAWAY frame with a more representative
            // last stream ID.
            let goAway = HTTP2Frame(
                streamID: .rootStream,
                payload: .goAway(
                    lastStreamID: .maxID,
                    errorCode: .noError,
                    opaqueData: nil
                )
            )

            let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(pingData, ack: false))

            context.write(self.wrapOutboundOut(goAway), promise: nil)
            context.write(self.wrapOutboundOut(ping), promise: nil)
            self.maybeFlush(context: context)

        case .none:
            ()  // Already shutting down.
        }
    }

    private func handlePingAck(context: ChannelHandlerContext, data: HTTP2PingData) {
        switch self.state.receivedPingAck(data: data) {
        case .sendGoAway(let streamID, let close):
            let goAway = HTTP2Frame(
                streamID: .rootStream,
                payload: .goAway(lastStreamID: streamID, errorCode: .noError, opaqueData: nil)
            )

            context.write(self.wrapOutboundOut(goAway), promise: nil)
            self.maybeFlush(context: context)

            if close {
                context.close(promise: nil)
            } else {
                // We may have a grace period for finishing once the second GOAWAY frame has finished.
                // If this is set close the connection abruptly once the grace period passes.
                self.maxGraceTimerHandler?.start()
            }

        case .none:
            ()
        }
    }

    private func keepaliveTimerFired() {
        guard let context = self.context else { return }
        let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(self.keepalivePingData, ack: false))
        context.write(self.wrapInboundOut(ping), promise: nil)
        self.maybeFlush(context: context)

        // Schedule a timeout on waiting for the response.
        self.keepaliveTimeoutHandler?.start()
    }
}
