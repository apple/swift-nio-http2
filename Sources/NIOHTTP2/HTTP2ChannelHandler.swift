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
import NIOCore
import NIOHPACK

/// NIO's default settings used for initial settings values on HTTP/2 streams, when the user hasn't
/// overridden that. This limits the max concurrent streams to 100, and limits the max header list
/// size to 16kB, to avoid trivial resource exhaustion on NIO HTTP/2 users.
public let nioDefaultSettings = [
    HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
    HTTP2Setting(parameter: .maxHeaderListSize, value: HPACKDecoder.defaultMaxHeaderListSize),
]

/// ``NIOHTTP2Handler`` implements the HTTP/2 protocol for a single connection.
///
/// This `ChannelHandler` takes a series of bytes and turns them into a sequence of ``HTTP2Frame`` objects.
/// This type allows implementing a single `ChannelPipeline` that runs a complete HTTP/2 connection, and
/// doesn't deal with managing stream state.
///
/// Most users should combine this with a ``HTTP2StreamMultiplexer`` to get an easier programming model.
public final class NIOHTTP2Handler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundIn = HTTP2Frame
    public typealias OutboundOut = IOData

    /// The magic string sent by clients at the start of a HTTP/2 connection.
    private static let clientMagic: StaticString = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    /// The default value for the maximum number of sequential CONTINUATION frames.
    private static let defaultMaximumSequentialContinuationFrames: Int = 5
    /// The default number of recently reset streams to track.
    private static let defaultMaximumRecentlyResetFrames: Int = 32

    /// The event loop on which this handler will do work.
    @usableFromInline internal let _eventLoop: EventLoop?

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

    /// This flag is set to false each time we issue a flush, and set to true
    /// each time we write a frame. This allows us to avoid flushing unnecessarily.
    private var wroteFrame: Bool = false

    /// This object deploys heuristics to attempt to detect denial of service attacks.
    private var denialOfServiceValidator: DOSHeuristics<RealNIODeadlineClock>

    private var glitchesMonitor: GlitchesMonitor

    /// The mode this handler is operating in.
    private let mode: ParserMode

    /// The initial local settings of this connection. Sent as part of the preamble.
    private let initialSettings: HTTP2Settings

    // TODO(cory): We should revisit this: ideally we won't drop frames but would still deliver them where
    // possible, but I'm not doing that right now.
    /// Whether the channel has closed. If it has, we abort the decode loop, as we don't delay channelInactive.
    private var channelClosed: Bool = false

    /// A cached copy of the channel writability state. Updated in channelWritabilityChanged notifications, and used
    /// to determine buffering strategies.
    private var channelWritable: Bool = true

    /// This variable is set to `true` when we are inside `unbufferAndFlushAutomaticFrames` and protects us from reentering the method
    /// which can cause an infinite recursion.
    private var isUnbufferingAndFlushingAutomaticFrames = false

    /// In some cases channelInactive can be fired while channelActive is still running.
    private var activationState = ActivationState.idle

    /// Whether we should tolerate "impossible" state transitions in debug mode. Only true in tests specifically trying to
    /// trigger them.
    private let tolerateImpossibleStateTransitionsInDebugMode: Bool

    /// The delegate for (de)multiplexing inbound streams.
    private var inboundStreamMultiplexerState: InboundStreamMultiplexerState

    /// The maximum number of sequential CONTINUATION frames.
    private let maximumSequentialContinuationFrames: Int

    /// A delegate which is told about frames which have been written.
    private let frameDelegate: NIOHTTP2FrameDelegate?

    @usableFromInline
    internal var inboundStreamMultiplexer: InboundStreamMultiplexer? {
        self.inboundStreamMultiplexerState.multiplexer
    }

    /// Holds and tracks the state of the ``InboundStreamMultiplexer``.
    ///
    /// It has three states to allow us to stash the config required for the 'inline' case without cluttering the ``NIOHTTP2Handler``
    /// - For legacy multiplexing this begins as`.uninitializedLegacy`, becomes `.initialized` on `handlerAdded` and moves to to `.deinitialized` on `handlerRemoved`.
    /// - For inline multiplexing the behavior is the same with the modification that it begins as `.uninitializedInline` state when the ``NIOHTTP2Handler`` is initialized to hold the config until `handlerAdded`.
    /// It contains as associated values:
    /// - `StreamConfiguration`: Stream configuration for use in the inline stream multiplexer.
    /// - `InboundStreamInitializer`: Callback invoked when new inbound streams are created.
    /// - `NIOHTTP2StreamDelegate`: The delegate to be notified upon stream creation and close.
    /// - `InboundStreamMultiplexer`: The component responsible for (de)multiplexing inbound streams.
    private enum InboundStreamMultiplexerState {
        case uninitializedLegacy
        case uninitializedInline(StreamConfiguration, StreamInitializer, NIOHTTP2StreamDelegate?)
        case uninitializedAsync(StreamConfiguration, StreamInitializerWithAnyOutput, NIOHTTP2StreamDelegate?)
        case initialized(InboundStreamMultiplexer)
        case deinitialized

        internal var multiplexer: InboundStreamMultiplexer? {
            switch self {
            case .initialized(let inboundStreamMultiplexer):
                return inboundStreamMultiplexer
            case .uninitializedLegacy, .uninitializedInline, .uninitializedAsync, .deinitialized:
                return nil
            }
        }

        mutating func initialize(
            context: ChannelHandlerContext,
            http2Handler: NIOHTTP2Handler,
            mode: NIOHTTP2Handler.ParserMode
        ) {
            switch self {
            case .deinitialized:
                preconditionFailure(
                    "This multiplexer has been de-initialized without being reconfigured with a new context."
                )
            case .uninitializedLegacy:
                self = .initialized(.legacy(LegacyInboundStreamMultiplexer(context: context)))

            case .uninitializedInline(let streamConfiguration, let inboundStreamInitializer, let streamDelegate):
                self = .initialized(
                    .inline(
                        InlineStreamMultiplexer(
                            context: context,
                            outboundView: .init(http2Handler: http2Handler),
                            mode: mode,
                            inboundStreamStateInitializer: .excludesStreamID(inboundStreamInitializer),
                            targetWindowSize: max(0, min(streamConfiguration.targetWindowSize, Int(Int32.max))),
                            streamChannelOutboundBytesHighWatermark: streamConfiguration
                                .outboundBufferSizeHighWatermark,
                            streamChannelOutboundBytesLowWatermark: streamConfiguration.outboundBufferSizeLowWatermark,
                            streamDelegate: streamDelegate
                        )
                    )
                )

            case .uninitializedAsync(let streamConfiguration, let inboundStreamInitializer, let streamDelegate):
                self = .initialized(
                    .inline(
                        InlineStreamMultiplexer(
                            context: context,
                            outboundView: .init(http2Handler: http2Handler),
                            mode: mode,
                            inboundStreamStateInitializer: .returnsAny(inboundStreamInitializer),
                            targetWindowSize: max(0, min(streamConfiguration.targetWindowSize, Int(Int32.max))),
                            streamChannelOutboundBytesHighWatermark: streamConfiguration
                                .outboundBufferSizeHighWatermark,
                            streamChannelOutboundBytesLowWatermark: streamConfiguration.outboundBufferSizeLowWatermark,
                            streamDelegate: streamDelegate
                        )
                    )
                )

            case .initialized:
                break  //no-op
            }
        }
    }

    /// The mode for this parser to operate in: client or server.
    public enum ParserMode: Sendable {
        /// Client mode
        case client

        /// Server mode
        case server
    }

    /// Whether a given operation has validation enabled or not.
    public enum ValidationState: Sendable {
        /// Validation is enabled
        case enabled

        /// Validation is disabled
        case disabled
    }

    /// Constructs a ``NIOHTTP2Handler``.
    ///
    /// - Parameters:
    ///   - mode: The mode for this handler, client or server.
    ///   - initialSettings: The settings that will be advertised to the peer in the preamble. Defaults to ``nioDefaultSettings``.
    ///   - headerBlockValidation: Whether to validate sent and received HTTP/2 header blocks. Defaults to ``ValidationState/enabled``.
    ///   - contentLengthValidation: Whether to validate the content length of sent and received streams. Defaults to ``ValidationState/enabled``.
    public convenience init(
        mode: ParserMode,
        initialSettings: HTTP2Settings = nioDefaultSettings,
        headerBlockValidation: ValidationState = .enabled,
        contentLengthValidation: ValidationState = .enabled
    ) {
        self.init(
            mode: mode,
            eventLoop: nil,
            initialSettings: initialSettings,
            headerBlockValidation: headerBlockValidation,
            contentLengthValidation: contentLengthValidation,
            maximumSequentialEmptyDataFrames: 1,
            maximumBufferedControlFrames: 10000,
            maximumSequentialContinuationFrames: NIOHTTP2Handler.defaultMaximumSequentialContinuationFrames,
            maximumRecentlyResetStreams: Self.defaultMaximumRecentlyResetFrames,
            maximumConnectionGlitches: GlitchesMonitor.defaultMaximumGlitches,
            maximumResetFrameCount: 200,
            resetFrameCounterWindow: .seconds(30),
            maximumStreamErrorCount: 200,
            streamErrorCounterWindow: .seconds(30),
            frameDelegate: nil
        )
    }

    /// Constructs a ``NIOHTTP2Handler``.
    ///
    /// - Parameters:
    ///   - mode: The mode for this handler, client or server.
    ///   - initialSettings: The settings that will be advertised to the peer in the preamble. Defaults to ``nioDefaultSettings``.
    ///   - headerBlockValidation: Whether to validate sent and received HTTP/2 header blocks. Defaults to ``ValidationState/enabled``.
    ///   - contentLengthValidation: Whether to validate the content length of sent and received streams. Defaults to ``ValidationState/enabled``.
    ///   - maximumSequentialEmptyDataFrames: Controls the number of empty data frames this handler will tolerate receiving in a row before DoS protection
    ///         is triggered and the connection is terminated. Defaults to 1.
    ///   - maximumBufferedControlFrames: Controls the maximum buffer size of buffered outbound control frames. If we are unable to send control frames as
    ///         fast as we produce them we risk building up an unbounded buffer and exhausting our memory. To protect against this DoS vector, we put an
    ///         upper limit on the depth of this queue. Defaults to 10,000.
    public convenience init(
        mode: ParserMode,
        initialSettings: HTTP2Settings = nioDefaultSettings,
        headerBlockValidation: ValidationState = .enabled,
        contentLengthValidation: ValidationState = .enabled,
        maximumSequentialEmptyDataFrames: Int = 1,
        maximumBufferedControlFrames: Int = 10000
    ) {
        self.init(
            mode: mode,
            eventLoop: nil,
            initialSettings: initialSettings,
            headerBlockValidation: headerBlockValidation,
            contentLengthValidation: contentLengthValidation,
            maximumSequentialEmptyDataFrames: maximumSequentialEmptyDataFrames,
            maximumBufferedControlFrames: maximumBufferedControlFrames,
            maximumSequentialContinuationFrames: NIOHTTP2Handler.defaultMaximumSequentialContinuationFrames,
            maximumRecentlyResetStreams: Self.defaultMaximumRecentlyResetFrames,
            maximumConnectionGlitches: GlitchesMonitor.defaultMaximumGlitches,
            maximumResetFrameCount: 200,
            resetFrameCounterWindow: .seconds(30),
            maximumStreamErrorCount: 200,
            streamErrorCounterWindow: .seconds(30),
            frameDelegate: nil
        )

    }

    /// Constructs a ``NIOHTTP2Handler``.
    ///
    /// - Parameters:
    ///   - mode: The mode for this handler, client or server.
    ///   - connectionConfiguration: The settings that will be used when establishing the connection.
    ///   - streamConfiguration: The settings that will be used when establishing new streams.
    public convenience init(
        mode: ParserMode,
        connectionConfiguration: ConnectionConfiguration = .init(),
        streamConfiguration: StreamConfiguration = .init()
    ) {
        self.init(
            mode: mode,
            frameDelegate: nil,
            connectionConfiguration: connectionConfiguration,
            streamConfiguration: streamConfiguration
        )
    }

    /// Constructs a ``NIOHTTP2Handler``.
    ///
    /// - Parameters:
    ///   - mode: The mode for this handler, client or server.
    ///   - frameDelegate: A delegate which is notified about frames being written.
    ///   - connectionConfiguration: The settings that will be used when establishing the connection.
    ///   - streamConfiguration: The settings that will be used when establishing new streams.
    public convenience init(
        mode: ParserMode,
        frameDelegate: NIOHTTP2FrameDelegate?,
        connectionConfiguration: ConnectionConfiguration = ConnectionConfiguration(),
        streamConfiguration: StreamConfiguration = StreamConfiguration()
    ) {
        self.init(
            mode: mode,
            eventLoop: nil,
            initialSettings: connectionConfiguration.initialSettings,
            headerBlockValidation: connectionConfiguration.headerBlockValidation,
            contentLengthValidation: connectionConfiguration.contentLengthValidation,
            maximumSequentialEmptyDataFrames: connectionConfiguration.maximumSequentialEmptyDataFrames,
            maximumBufferedControlFrames: connectionConfiguration.maximumBufferedControlFrames,
            maximumSequentialContinuationFrames: connectionConfiguration.maximumSequentialContinuationFrames,
            maximumRecentlyResetStreams: connectionConfiguration.maximumRecentlyResetStreams,
            maximumConnectionGlitches: connectionConfiguration.maximumConnectionGlitches,
            maximumResetFrameCount: streamConfiguration.streamResetFrameRateLimit.maximumCount,
            resetFrameCounterWindow: streamConfiguration.streamResetFrameRateLimit.windowLength,
            maximumStreamErrorCount: streamConfiguration.streamErrorRateLimit.maximumCount,
            streamErrorCounterWindow: streamConfiguration.streamErrorRateLimit.windowLength,
            frameDelegate: frameDelegate
        )
    }

    private init(
        mode: ParserMode,
        eventLoop: EventLoop?,
        initialSettings: HTTP2Settings,
        headerBlockValidation: ValidationState,
        contentLengthValidation: ValidationState,
        maximumSequentialEmptyDataFrames: Int,
        maximumBufferedControlFrames: Int,
        maximumSequentialContinuationFrames: Int,
        maximumRecentlyResetStreams: Int,
        maximumConnectionGlitches: Int,
        maximumResetFrameCount: Int,
        resetFrameCounterWindow: TimeAmount,
        maximumStreamErrorCount: Int,
        streamErrorCounterWindow: TimeAmount,
        frameDelegate: NIOHTTP2FrameDelegate?
    ) {
        self._eventLoop = eventLoop
        self.stateMachine = HTTP2ConnectionStateMachine(
            role: .init(mode),
            headerBlockValidation: .init(headerBlockValidation),
            contentLengthValidation: .init(contentLengthValidation),
            maxResetStreams: maximumRecentlyResetStreams
        )
        self.mode = mode
        self.initialSettings = initialSettings
        self.outboundBuffer = CompoundOutboundBuffer(
            mode: mode,
            initialMaxOutboundStreams: 100,
            maxBufferedControlFrames: maximumBufferedControlFrames
        )
        self.denialOfServiceValidator = DOSHeuristics(
            maximumSequentialEmptyDataFrames: maximumSequentialEmptyDataFrames,
            maximumResetFrameCount: maximumResetFrameCount,
            resetFrameCounterWindow: resetFrameCounterWindow,
            maximumStreamErrorCount: maximumStreamErrorCount,
            streamErrorCounterWindow: streamErrorCounterWindow
        )
        self.tolerateImpossibleStateTransitionsInDebugMode = false
        self.inboundStreamMultiplexerState = .uninitializedLegacy
        self.maximumSequentialContinuationFrames = maximumSequentialContinuationFrames
        self.glitchesMonitor = GlitchesMonitor(maximumGlitches: maximumConnectionGlitches)
        self.frameDelegate = frameDelegate
    }

    /// Constructs a ``NIOHTTP2Handler``.
    ///
    /// - Parameters:
    ///   - mode: The mode for this handler, client or server.
    ///   - initialSettings: The settings that will be advertised to the peer in the preamble. Defaults to ``nioDefaultSettings``.
    ///   - headerBlockValidation: Whether to validate sent and received HTTP/2 header blocks. Defaults to ``ValidationState/enabled``.
    ///   - contentLengthValidation: Whether to validate the content length of sent and received streams. Defaults to ``ValidationState/enabled``.
    ///   - maximumSequentialEmptyDataFrames: Controls the number of empty data frames this handler will tolerate receiving in a row before DoS protection
    ///         is triggered and the connection is terminated. Defaults to 1.
    ///   - maximumBufferedControlFrames: Controls the maximum buffer size of buffered outbound control frames. If we are unable to send control frames as
    ///         fast as we produce them we risk building up an unbounded buffer and exhausting our memory. To protect against this DoS vector, we put an
    ///         upper limit on the depth of this queue. Defaults to 10,000.
    ///   - maximumSequentialContinuationFrames: The maximum number of sequential CONTINUATION frames.
    ///   - tolerateImpossibleStateTransitionsInDebugMode: Whether impossible state transitions should be tolerated
    ///         in debug mode.
    ///   - maximumResetFrameCount: Controls the maximum permitted reset frames within a given time window. Too many may exhaust CPU resources. To protect
    ///         against this DoS vector we put an upper limit on this rate. Defaults to 200.
    ///   - resetFrameCounterWindow:  Controls the sliding window used to enforce the maximum permitted reset frames rate. Too many may exhaust CPU resources. To protect
    ///         against this DoS vector we put an upper limit on this rate. 30 seconds.
    ///   - maximumConnectionGlitches: Controls the maximum number of stream errors that can happen on a connection before the connection is reset. Defaults to 200.
    internal init(
        mode: ParserMode,
        initialSettings: HTTP2Settings = nioDefaultSettings,
        headerBlockValidation: ValidationState = .enabled,
        contentLengthValidation: ValidationState = .enabled,
        maximumSequentialEmptyDataFrames: Int = 1,
        maximumBufferedControlFrames: Int = 10000,
        maximumSequentialContinuationFrames: Int = NIOHTTP2Handler.defaultMaximumSequentialContinuationFrames,
        tolerateImpossibleStateTransitionsInDebugMode: Bool = false,
        maximumRecentlyResetStreams: Int = NIOHTTP2Handler.defaultMaximumRecentlyResetFrames,
        maximumResetFrameCount: Int = 200,
        resetFrameCounterWindow: TimeAmount = .seconds(30),
        maximumStreamErrorCount: Int = 200,
        streamErrorCounterWindow: TimeAmount = .seconds(30),
        maximumConnectionGlitches: Int = GlitchesMonitor.defaultMaximumGlitches,
        frameDelegate: NIOHTTP2FrameDelegate? = nil
    ) {
        self.stateMachine = HTTP2ConnectionStateMachine(
            role: .init(mode),
            headerBlockValidation: .init(headerBlockValidation),
            contentLengthValidation: .init(contentLengthValidation),
            maxResetStreams: maximumRecentlyResetStreams
        )
        self.mode = mode
        self._eventLoop = nil
        self.initialSettings = initialSettings
        self.outboundBuffer = CompoundOutboundBuffer(
            mode: mode,
            initialMaxOutboundStreams: 100,
            maxBufferedControlFrames: maximumBufferedControlFrames
        )
        self.denialOfServiceValidator = DOSHeuristics(
            maximumSequentialEmptyDataFrames: maximumSequentialEmptyDataFrames,
            maximumResetFrameCount: maximumResetFrameCount,
            resetFrameCounterWindow: resetFrameCounterWindow,
            maximumStreamErrorCount: maximumStreamErrorCount,
            streamErrorCounterWindow: streamErrorCounterWindow
        )
        self.tolerateImpossibleStateTransitionsInDebugMode = tolerateImpossibleStateTransitionsInDebugMode
        self.inboundStreamMultiplexerState = .uninitializedLegacy
        self.maximumSequentialContinuationFrames = maximumSequentialContinuationFrames
        self.glitchesMonitor = GlitchesMonitor(maximumGlitches: maximumConnectionGlitches)
        self.frameDelegate = frameDelegate
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.frameDecoder = HTTP2FrameDecoder(
            allocator: context.channel.allocator,
            expectClientMagic: self.mode == .server,
            maximumSequentialContinuationFrames: self.maximumSequentialContinuationFrames
        )
        self.frameEncoder = HTTP2FrameEncoder(allocator: context.channel.allocator)
        self.writeBuffer = context.channel.allocator.buffer(capacity: 128)
        self.inboundStreamMultiplexerState.initialize(context: context, http2Handler: self, mode: self.mode)

        if context.channel.isActive {
            // We jump immediately to activated here, as channelActive has probably already passed.
            if self.activationState != .idle {
                self.impossibleActivationStateTransition(
                    state: self.activationState,
                    activating: true,
                    context: context
                )
            }
            self.activationState = .activated
            self.writeAndFlushPreamble(context: context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        // Any frames we're buffering need to be dropped.
        self.outboundBuffer.invalidateBuffer()
        self.inboundStreamMultiplexer?.handlerRemovedReceived()
        self.inboundStreamMultiplexerState = .deinitialized
    }

    public func channelActive(context: ChannelHandlerContext) {
        // Check our activation state.
        switch self.activationState {
        case .idle:
            // This is our first channelActive. We're now activating.
            self.activationState = .activating
        case .activated:
            // This is a weird one, but it implies we "beat" the channelActive
            // call down the pipeline when we added in handlerAdded. That's ok!
            // We can safely ignore this.
            return
        case .inactive:
            // This means we received channelInactive already. This can happen, unfortunately, usually when
            // calling close() from within the completion of a channel connect promise. We tolerate this,
            // but fire an error to make sure it's fatal.
            context.fireChannelActive()
            context.fireErrorCaught(NIOHTTP2Errors.ActivationError(state: .inactive, activating: true))
            return
        case .activating, .inactiveWhileActivating:
            // All of these states are channel pipeline invariant violations, but conceptually possible.
            //
            // - .activating implies we got another channelActive while we were handling one. That would be
            //     a violation of pipeline invariants.
            // - .inactiveWhileActivating implies a sequence of channelActive, channelInactive, channelActive
            //     synchronously. This is not just unlikely, but also misuse of the handler or violation of
            //     channel pipeline invariants.
            //
            // We'll throw an error and then close. In debug builds, we crash.
            self.impossibleActivationStateTransition(
                state: self.activationState,
                activating: true,
                context: context
            )
            return
        }

        self.writeAndFlushPreamble(context: context)
        self.inboundStreamMultiplexer?.channelActiveReceived()

        // Ok, we progressed. Now we check our state again.
        switch self.activationState {
        case .activating:
            // This is the easy case: nothing exciting happened. We can activate and notify the pipeline.
            self.activationState = .activated
            context.fireChannelActive()
        case .inactiveWhileActivating:
            // This is awkward: we got a channelInactive during the above operation. We need to fire channelActive
            // and then re-issue the channelInactive call.
            self.activationState = .activated
            context.fireChannelActive()
            self.channelInactive(context: context)
        case .idle, .activated, .inactive:
            // These three states should be impossible.
            //
            // - .idle and .inactive somehow implies we didn't execute the code above.
            // - .activated implies that the above code didn't prevent us re-entrantly getting to this point.
            // - .inactive implies that somehow we hit channelInactive but didn't enter .inactiveWhileActivating.
            self.impossibleActivationStateTransition(
                state: self.activationState,
                activating: true,
                context: context
            )
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        switch self.activationState {
        case .activated:
            // This is the easy one. We were active, now we aren't.
            self.activationState = .inactive
            self.channelClosed = true
            self.inboundStreamMultiplexer?.channelInactiveReceived()
            context.fireChannelInactive()
        case .activating:
            // Huh, we got channelInactive during activation. We need to maintain
            // ordering, so we'll temporarily delay this.
            self.activationState = .inactiveWhileActivating
        case .idle:
            // This implies getting channelInactive before channelActive. This is uncommon, but not impossible.
            // We'll tolerate it here.
            self.activationState = .inactive
        case .inactiveWhileActivating, .inactive:
            // This is weird. This can only happen if we see channelInactive twice, which is probably an error.
            self.impossibleActivationStateTransition(state: self.activationState, activating: false, context: context)
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self.inboundStreamMultiplexer?.userInboundEventReceived(event)
        context.fireUserInboundEventTriggered(event)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        self.frameDecoder.append(bytes: data)

        // Before we go in here we need to deliver any pending user events. This is because
        // we may have been called re-entrantly.
        self.processPendingUserEvents(context: context)

        // We parse eagerly to attempt to give back buffers to the reading channel wherever possible.
        self.frameDecodeLoop(context: context)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        self.outboundBuffer.flushReceived()
        self.unbufferAndFlushAutomaticFrames(context: context)

        self.inboundStreamMultiplexer?.channelReadCompleteReceived()
        context.fireChannelReadComplete()
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.writeBufferedFrame(context: context, frame: frame, promise: promise)
    }

    public func flush(context: ChannelHandlerContext) {
        // We need to always flush here, so we'll pretend we wrote an automatic frame even if we didn't.
        self.outboundBuffer.flushReceived()
        self.unbufferAndFlushAutomaticFrames(context: context)
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        // Update the writability status. If the channel has become writeable, we can also attempt to unbuffer some frames here.
        self.channelWritable = context.channel.isWritable
        if self.channelWritable {
            self.unbufferAndFlushAutomaticFrames(context: context)
        }

        self.inboundStreamMultiplexer?.channelWritabilityChangedReceived()
        context.fireChannelWritabilityChanged()
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.inboundStreamMultiplexer?.errorCaughtReceived(error)
        context.fireErrorCaught(error)
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
            self.inboundConnectionErrorTriggered(
                context: context,
                underlyingError: NIOHTTP2Errors.unableToParseFrame(),
                reason: code,
                isMisbehavingPeer: false
            )
            return nil
        } catch is NIOHTTP2Errors.BadClientMagic {
            self.inboundConnectionErrorTriggered(
                context: context,
                underlyingError: NIOHTTP2Errors.badClientMagic(),
                reason: .protocolError,
                isMisbehavingPeer: false
            )
            return nil
        } catch is NIOHTTP2Errors.ExcessivelyLargeHeaderBlock {
            self.inboundConnectionErrorTriggered(
                context: context,
                underlyingError: NIOHTTP2Errors.excessivelyLargeHeaderBlock(),
                reason: .protocolError,
                isMisbehavingPeer: false
            )
            return nil
        } catch is NIOHTTP2Errors.ExcessiveContinuationFrames {
            self.inboundConnectionErrorTriggered(
                context: context,
                underlyingError: NIOHTTP2Errors.excessiveContinuationFrames(),
                reason: .enhanceYourCalm,
                isMisbehavingPeer: false
            )
            return nil
        } catch {
            self.inboundConnectionErrorTriggered(
                context: context,
                underlyingError: error,
                reason: .internalError,
                isMisbehavingPeer: false
            )
            return nil
        }
    }

    enum FrameProcessResult {
        case `continue`
        case stop
    }

    private func processFrame(
        _ frame: HTTP2Frame,
        flowControlledLength: Int,
        context: ChannelHandlerContext
    ) -> FrameProcessResult {
        // All frames have one basic processing step: do we send them on, or drop them?
        // Some frames have further processing steps, regarding triggering user events or other operations.
        // Here we centralise this processing.
        var result: StateMachineResultWithEffect

        switch frame.payload {
        case .alternativeService(let origin, let field):
            result = self.stateMachine.receiveAlternativeService(origin: origin, field: field)
        case .origin(let origins):
            result = self.stateMachine.receiveOrigin(origins: origins)
        case .data(let dataBody):
            result = self.stateMachine.receiveData(
                streamID: frame.streamID,
                contentLength: dataBody.data.readableBytes,
                flowControlledBytes: flowControlledLength,
                isEndStreamSet: dataBody.endStream
            )
        case .goAway(let lastStreamID, _, _):
            result = self.stateMachine.receiveGoaway(lastStreamID: lastStreamID)
        case .headers(let headerBody):
            result = self.stateMachine.receiveHeaders(
                streamID: frame.streamID,
                headers: headerBody.headers,
                isEndStreamSet: headerBody.endStream
            )

            // Apply a priority update if one is here. If this fails, it may cause a connection error.
            if let priorityData = headerBody.priorityData {
                do {
                    try self.outboundBuffer.priorityUpdate(streamID: frame.streamID, priorityData: priorityData)
                } catch {
                    result = StateMachineResultWithEffect(
                        result: .connectionError(underlyingError: error, type: .protocolError),
                        effect: nil
                    )
                }
            }

        case .ping(let pingData, let ack):
            let (stateMachineResult, postPingOperation) = self.stateMachine.receivePing(ackFlagSet: ack)
            result = stateMachineResult
            switch postPingOperation {
            case .nothing:
                break
            case .sendAck:
                let responseFrame = HTTP2Frame(streamID: frame.streamID, payload: .ping(pingData, ack: true))
                self.writeBufferedFrame(context: context, frame: responseFrame, promise: nil)
            }

        case .priority(let priorityData):
            result = self.stateMachine.receivePriority()

            // Apply a priority update if one is here. If this fails, it may cause a connection error.
            do {
                try self.outboundBuffer.priorityUpdate(streamID: frame.streamID, priorityData: priorityData)
            } catch {
                result = StateMachineResultWithEffect(
                    result: .connectionError(underlyingError: error, type: .protocolError),
                    effect: nil
                )
            }

        case .pushPromise(let pushedStreamData):
            result = self.stateMachine.receivePushPromise(
                originalStreamID: frame.streamID,
                childStreamID: pushedStreamData.pushedStreamID,
                headers: pushedStreamData.headers
            )
        case .rstStream(let reason):
            result = self.stateMachine.receiveRstStream(streamID: frame.streamID, reason: reason)
        case .settings(let newSettings):
            let (stateMachineResult, postSettingsOperation) = self.stateMachine.receiveSettings(
                newSettings,
                frameEncoder: &self.frameEncoder,
                frameDecoder: &self.frameDecoder
            )
            result = stateMachineResult
            switch postSettingsOperation {
            case .nothing:
                break
            case .sendAck:
                self.writeBufferedFrame(
                    context: context,
                    frame: HTTP2Frame(streamID: .rootStream, payload: .settings(.ack)),
                    promise: nil
                )
            }

        case .windowUpdate(let increment):
            result = self.stateMachine.receiveWindowUpdate(streamID: frame.streamID, windowIncrement: UInt32(increment))
        }

        self.processDoSRisk(frame, result: &result)
        self.processGlitches(result: &result)
        self.processStateChange(result.effect)

        let returnValue: FrameProcessResult
        switch result.result {
        case .succeed:
            // Frame is good, we can pass it on.
            self.inboundStreamMultiplexer?.receivedFrame(frame)
            returnValue = .continue
        case .ignoreFrame:
            // Frame is good but no action needs to be taken.
            returnValue = .continue
        case .connectionError(let underlyingError, let errorCode, let isMisbehavingPeer):
            // We should stop parsing on received connection errors, the connection is going away anyway.
            self.inboundConnectionErrorTriggered(
                context: context,
                underlyingError: underlyingError,
                reason: errorCode,
                isMisbehavingPeer: isMisbehavingPeer
            )
            returnValue = .stop
        case .streamError(let streamID, let underlyingError, let errorCode):
            // We can continue parsing on stream errors in most cases, the frame is just ignored.
            self.inboundStreamErrorTriggered(
                context: context,
                streamID: streamID,
                underlyingError: underlyingError,
                reason: errorCode
            )
            returnValue = .continue
        }

        // Before we return the loop we process any user events that are currently pending.
        // These will likely only be ones that were generated now.
        self.processPendingUserEvents(context: context)

        return returnValue
    }

    /// A connection error was hit while receiving a frame.
    private func inboundConnectionErrorTriggered(
        context: ChannelHandlerContext,
        underlyingError: Error,
        reason: HTTP2ErrorCode,
        isMisbehavingPeer: Bool
    ) {
        // A connection error brings the entire connection down. We attempt to write a GOAWAY frame, and then report this
        // error. It's possible that we'll be unable to write the GOAWAY frame, but that also just logs the error.
        // Because we don't know what data the user handled before we got this, we propose that they may have seen all of it.
        // The user may choose to fire a more specific error if they wish.

        // If the peer is misbehaving, set the stream ID to the minimum allowed value (0).
        // This will cause all open streams for this connection to be immediately terminated.
        let streamID = isMisbehavingPeer ? HTTP2StreamID(0) : .maxID
        let goAwayFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .goAway(lastStreamID: streamID, errorCode: reason, opaqueData: nil)
        )
        self.writeUnbufferedFrame(context: context, frame: goAwayFrame)
        self.flushIfNecessary(context: context)
        context.fireErrorCaught(underlyingError)
    }

    /// A stream error was hit while receiving a frame.
    private func inboundStreamErrorTriggered(
        context: ChannelHandlerContext,
        streamID: HTTP2StreamID,
        underlyingError: Error,
        reason: HTTP2ErrorCode
    ) {
        // A stream error brings down a single stream, causing a RST_STREAM frame. We attempt to write this, and then report
        // the error. It's possible that we'll be unable to write this, which will likely escalate this error, but that's
        // the user's issue.
        let rstStreamFrame = HTTP2Frame(streamID: streamID, payload: .rstStream(reason))
        self.writeBufferedFrame(context: context, frame: rstStreamFrame, promise: nil)
        self.flushIfNecessary(context: context)
        context.fireErrorCaught(underlyingError)
    }

    /// Emit any pending user events.
    private func processPendingUserEvents(context: ChannelHandlerContext) {
        for event in self.inboundEventBuffer {
            self.inboundStreamMultiplexer?.process(event: event)
        }
    }

    private func processDoSRisk(_ frame: HTTP2Frame, result: inout StateMachineResultWithEffect) {
        do {
            try self.denialOfServiceValidator.process(frame)
            switch result.result {
            case .streamError:
                try self.denialOfServiceValidator.processStreamError()
            case .succeed, .ignoreFrame, .connectionError:
                ()
            }
        } catch {
            result.result = StateMachineResult.connectionError(
                underlyingError: error,
                type: .enhanceYourCalm,
                isMisbehavingPeer: true
            )
            result.effect = nil
        }
    }

    private func processGlitches(result: inout StateMachineResultWithEffect) {
        do {
            switch result.result {
            case .streamError:
                try self.glitchesMonitor.processStreamError()
            case .succeed, .ignoreFrame, .connectionError:
                ()
            }
        } catch {
            result.result = .connectionError(
                underlyingError: error,
                type: .enhanceYourCalm,
                isMisbehavingPeer: true
            )
            result.effect = nil
        }
    }
}

extension NIOHTTP2Handler.InboundStreamMultiplexer {
    func process(event: InboundEventBuffer.BufferedHTTP2UserEvent) {
        switch event {
        case .streamCreated(let event):
            self.streamCreated(event: event)
        case .initialStreamWindowChanged(let event):
            self.initialStreamWindowChanged(event: event)
        case .streamWindowUpdated(let event):
            self.streamWindowUpdated(event: event)
        case .streamClosed(let event):
            self.streamClosed(event: event)
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

        let initialSettingsFrame = HTTP2Frame(
            streamID: .rootStream,
            payload: .settings(.settings(self.initialSettings))
        )
        self.writeUnbufferedFrame(context: context, frame: initialSettingsFrame)
        self.flushIfNecessary(context: context)
    }

    /// Write a frame that is allowed to be buffered (that is, that participates in the outbound frame buffer).
    private func writeBufferedFrame(context: ChannelHandlerContext, frame: HTTP2Frame, promise: EventLoopPromise<Void>?)
    {
        do {
            switch try self.outboundBuffer.processOutboundFrame(
                frame,
                promise: promise,
                channelWritable: self.channelWritable
            ) {
            case .nothing:
                // Nothing to do, got buffered.
                break
            case .forward:
                self.processOutboundFrame(context: context, frame: frame, promise: promise)
            case .forwardAndDrop(let framesToDrop, let error):
                // We need to forward this frame, and then fail these promises.
                self.processOutboundFrame(context: context, frame: frame, promise: promise)
                for (droppedFrame, promise) in framesToDrop {
                    self.inboundStreamMultiplexer?.processedFrame(droppedFrame)
                    promise?.fail(error)
                }
            case .succeedAndDrop(let framesToDrop, let error):
                // We need to succeed this frame promise and fail the others. We fail the others first to keep the
                // promises in order.
                for (droppedFrame, promise) in framesToDrop {
                    self.inboundStreamMultiplexer?.processedFrame(droppedFrame)
                    promise?.fail(error)
                }
                self.inboundStreamMultiplexer?.processedFrame(frame)
                promise?.succeed(())
            }
        } catch let error where error is NIOHTTP2Errors.ExcessiveOutboundFrameBuffering {
            self.inboundStreamMultiplexer?.processedFrame(frame)
            self.inboundConnectionErrorTriggered(
                context: context,
                underlyingError: error,
                reason: .enhanceYourCalm,
                isMisbehavingPeer: false
            )
        } catch {
            self.inboundStreamMultiplexer?.processedFrame(frame)
            promise?.fail(error)
        }
    }

    /// Write a frame that is not allowed to be buffered. These are usually GOAWAY frames, which must be urgently emitted as the connection
    /// is about to be lost. These frames may not have associated promises.
    private func writeUnbufferedFrame(context: ChannelHandlerContext, frame: HTTP2Frame) {
        self.processOutboundFrame(context: context, frame: frame, promise: nil)
    }

    private func processOutboundFrame(
        context: ChannelHandlerContext,
        frame: HTTP2Frame,
        promise: EventLoopPromise<Void>?
    ) {
        let result: StateMachineResultWithEffect

        switch frame.payload {
        case .alternativeService(let origin, let field):
            // Returns 'Never'; alt service frames are not currently handled.
            self.stateMachine.sendAlternativeService(origin: origin, field: field)
        case .origin(let origins):
            // Returns 'Never'; origin frames are not currently handled.
            self.stateMachine.sendOrigin(origins: origins)
        case .data(let data):
            // TODO(cory): Correctly account for padding data.
            result = self.stateMachine.sendData(
                streamID: frame.streamID,
                contentLength: data.data.readableBytes,
                flowControlledBytes: data.data.readableBytes,
                isEndStreamSet: data.endStream
            )
        case .goAway(let lastStreamID, _, _):
            result = self.stateMachine.sendGoaway(lastStreamID: lastStreamID)
        case .headers(let headerContent):
            result = self.stateMachine.sendHeaders(
                streamID: frame.streamID,
                headers: headerContent.headers,
                isEndStreamSet: headerContent.endStream
            )
        case .ping:
            result = self.stateMachine.sendPing()
        case .priority:
            result = self.stateMachine.sendPriority()
        case .pushPromise(let pushedContent):
            result = self.stateMachine.sendPushPromise(
                originalStreamID: frame.streamID,
                childStreamID: pushedContent.pushedStreamID,
                headers: pushedContent.headers
            )
        case .rstStream(let reason):
            result = self.stateMachine.sendRstStream(streamID: frame.streamID, reason: reason)
        case .settings(.settings(let newSettings)):
            result = self.stateMachine.sendSettings(newSettings)
        case .settings(.ack):
            // We do not allow sending SETTINGS ACK frames. However, we emit them automatically ourselves, so we
            // choose to tolerate it, even if users do the wrong thing.
            result = .init(result: .succeed, effect: nil)
        case .windowUpdate(let increment):
            result = self.stateMachine.sendWindowUpdate(streamID: frame.streamID, windowIncrement: UInt32(increment))
        }

        self.processStateChange(result.effect)

        // From this point on this will either error or go into `context.write`
        // Once the frame data is out of the HTTP2 handler we consider this 'written'
        self.inboundStreamMultiplexer?.processedFrame(frame)

        switch result.result {
        case .ignoreFrame:
            preconditionFailure("Cannot be asked to ignore outbound frames.")
        case .connectionError(let underlyingError, _, _):
            self.outboundConnectionErrorTriggered(context: context, promise: promise, underlyingError: underlyingError)
            return
        case .streamError(let streamID, let underlyingError, _):
            self.outboundStreamErrorTriggered(
                context: context,
                promise: promise,
                streamID: streamID,
                underlyingError: underlyingError
            )
            return
        case .succeed:
            self.writeBuffer.clear()
            self.encodeAndWriteFrame(context: context, frame: frame, promise: promise)
        }

        // This may have caused user events that need to be fired, so do so.
        self.processPendingUserEvents(context: context)
    }

    /// Encodes a frame and writes it to the network.
    private func encodeAndWriteFrame(
        context: ChannelHandlerContext,
        frame: HTTP2Frame,
        promise: EventLoopPromise<Void>?
    ) {
        let extraFrameData: IOData?

        do {
            extraFrameData = try self.frameEncoder.encode(frame: frame, to: &self.writeBuffer)
        } catch InternalError.codecError {
            self.outboundConnectionErrorTriggered(
                context: context,
                promise: promise,
                underlyingError: NIOHTTP2Errors.unableToSerializeFrame()
            )
            return
        } catch {
            self.outboundConnectionErrorTriggered(context: context, promise: promise, underlyingError: error)
            return
        }

        // Tell the delegate, if there is one.
        if let delegate = self.frameDelegate {
            delegate.wroteFrame(frame)
        }

        // Ok, if we got here we're good to send data. We want to attach the promise to the latest write, not
        // always the frame header.
        self.wroteFrame = true
        if let extraFrameData = extraFrameData {
            context.write(self.wrapOutboundOut(.byteBuffer(self.writeBuffer)), promise: nil)
            context.write(self.wrapOutboundOut(extraFrameData), promise: promise)
        } else {
            context.write(self.wrapOutboundOut(.byteBuffer(self.writeBuffer)), promise: promise)
        }
    }

    /// A connection error was hit while attempting to send a frame.
    private func outboundConnectionErrorTriggered(
        context: ChannelHandlerContext,
        promise: EventLoopPromise<Void>?,
        underlyingError: Error
    ) {
        promise?.fail(underlyingError)
        context.fireErrorCaught(underlyingError)
    }

    /// A stream error was hit while attempting to send a frame.
    private func outboundStreamErrorTriggered(
        context: ChannelHandlerContext,
        promise: EventLoopPromise<Void>?,
        streamID: HTTP2StreamID,
        underlyingError: Error
    ) {
        promise?.fail(underlyingError)
        self.inboundStreamMultiplexer?.streamError(streamID: streamID, error: underlyingError)
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
            self.outboundBuffer.connectionWindowSize = streamClosedData.localConnectionWindowSize
            self.inboundEventBuffer.pendingUserEvent(
                StreamClosedEvent(streamID: streamClosedData.streamID, reason: streamClosedData.reason)
            )
            self.inboundEventBuffer.pendingUserEvent(
                NIOHTTP2WindowUpdatedEvent(
                    streamID: .rootStream,
                    inboundWindowSize: streamClosedData.remoteConnectionWindowSize,
                    outboundWindowSize: streamClosedData.localConnectionWindowSize
                )
            )

            let droppedPromises = self.outboundBuffer.streamClosed(streamClosedData.streamID)
            self.failDroppedPromises(
                droppedPromises,
                streamID: streamClosedData.streamID,
                errorCode: streamClosedData.reason ?? .cancel
            )
        case .streamCreated(let streamCreatedData):
            self.outboundBuffer.streamCreated(
                streamCreatedData.streamID,
                initialWindowSize: streamCreatedData.localStreamWindowSize.map(UInt32.init) ?? 0
            )
            self.inboundEventBuffer.pendingUserEvent(
                NIOHTTP2StreamCreatedEvent(
                    streamID: streamCreatedData.streamID,
                    localInitialWindowSize: streamCreatedData.localStreamWindowSize.map(UInt32.init),
                    remoteInitialWindowSize: streamCreatedData.remoteStreamWindowSize.map(UInt32.init)
                )
            )
        case .bulkStreamClosure(let streamClosureData):
            for droppedStream in streamClosureData.closedStreams {
                self.inboundEventBuffer.pendingUserEvent(StreamClosedEvent(streamID: droppedStream, reason: .cancel))

                let droppedPromises = self.outboundBuffer.streamClosed(droppedStream)
                self.failDroppedPromises(droppedPromises, streamID: droppedStream, errorCode: .cancel)
            }
        case .flowControlChange(let change):
            self.outboundBuffer.connectionWindowSize = change.localConnectionWindowSize
            self.inboundEventBuffer.pendingUserEvent(
                NIOHTTP2WindowUpdatedEvent(
                    streamID: .rootStream,
                    inboundWindowSize: change.remoteConnectionWindowSize,
                    outboundWindowSize: change.localConnectionWindowSize
                )
            )
            if let streamSize = change.localStreamWindowSize {
                self.outboundBuffer.updateStreamWindow(
                    streamSize.streamID,
                    newSize: streamSize.localStreamWindowSize.map(Int32.init) ?? 0
                )
                self.inboundEventBuffer.pendingUserEvent(
                    NIOHTTP2WindowUpdatedEvent(
                        streamID: streamSize.streamID,
                        inboundWindowSize: streamSize.remoteStreamWindowSize,
                        outboundWindowSize: streamSize.localStreamWindowSize
                    )
                )
            }
        case .streamCreatedAndClosed(let cAndCData):
            self.outboundBuffer.streamCreated(cAndCData.streamID, initialWindowSize: 0)
            let droppedPromises = self.outboundBuffer.streamClosed(cAndCData.streamID)
            self.failDroppedPromises(droppedPromises, streamID: cAndCData.streamID, errorCode: .cancel)
        case .remoteSettingsChanged(let settingsChange):
            if settingsChange.streamWindowSizeChange != 0 {
                self.outboundBuffer.initialWindowSizeChanged(settingsChange.streamWindowSizeChange)
            }
            if let newMaxFrameSize = settingsChange.newMaxFrameSize {
                self.frameEncoder.maxFrameSize = newMaxFrameSize
                self.outboundBuffer.maxFrameSize = Int(newMaxFrameSize)
            }
            if let newMaxConcurrentStreams = settingsChange.newMaxConcurrentStreams {
                self.outboundBuffer.maxOutboundStreams = Int(newMaxConcurrentStreams)
            }
        case .localSettingsChanged(let settingsChange):
            if settingsChange.streamWindowSizeChange != 0 {
                self.inboundEventBuffer.pendingUserEvent(
                    NIOHTTP2BulkStreamWindowChangeEvent(delta: settingsChange.streamWindowSizeChange)
                )
            }
            if let newMaxFrameSize = settingsChange.newMaxFrameSize {
                self.frameDecoder.maxFrameSize = newMaxFrameSize
            }
            if let newMaxHeaderListSize = settingsChange.newMaxHeaderListSize {
                self.frameDecoder.headerDecoder.maxHeaderListSize = Int(newMaxHeaderListSize)
            }
        }
    }

    private func unbufferAndFlushAutomaticFrames(context: ChannelHandlerContext) {
        if self.isUnbufferingAndFlushingAutomaticFrames {
            // Don't allow infinite recursion through this method.
            return
        }

        self.isUnbufferingAndFlushingAutomaticFrames = true

        loop: while true {
            switch self.outboundBuffer.nextFlushedWritableFrame(channelWritable: self.channelWritable) {
            case .noFrame:
                break loop
            case .error(let promise, let error):
                promise?.fail(error)
            case .frame(let frame, let promise):
                self.processOutboundFrame(context: context, frame: frame, promise: promise)
            }
        }

        self.isUnbufferingAndFlushingAutomaticFrames = false
        self.flushIfNecessary(context: context)
    }

    /// Emits a flush if a frame has been written.
    private func flushIfNecessary(context: ChannelHandlerContext) {
        if self.wroteFrame {
            self.wroteFrame = false
            context.flush()
        }
    }

    /// Fails any promises in the given collection with a 'StreamClosed' error.
    private func failDroppedPromises(
        _ promises: CompoundOutboundBuffer.DroppedPromisesCollection,
        streamID: HTTP2StreamID,
        errorCode: HTTP2ErrorCode,
        file: String = #fileID,
        line: UInt = #line
    ) {
        // 'NIOHTTP2Errors.streamClosed' always allocates, if there are no promises then there's no
        // need to create the error.
        guard promises.contains(where: { $0 != nil }) else {
            return
        }

        let error = NIOHTTP2Errors.streamClosed(streamID: streamID, errorCode: errorCode, file: file, line: line)
        for promise in promises {
            promise?.fail(error)
        }
    }
}

extension HTTP2ConnectionStateMachine.ConnectionRole {
    fileprivate init(_ role: NIOHTTP2Handler.ParserMode) {
        switch role {
        case .client:
            self = .client
        case .server:
            self = .server
        }
    }
}

extension HTTP2ConnectionStateMachine.ValidationState {
    init(_ state: NIOHTTP2Handler.ValidationState) {
        switch state {
        case .enabled:
            self = .enabled
        case .disabled:
            self = .disabled
        }
    }
}

extension NIOHTTP2Handler: CustomStringConvertible {
    public var description: String {
        "NIOHTTP2Handler(mode: \(String(describing: self.mode)))"
    }
}

extension NIOHTTP2Handler: CustomDebugStringConvertible {
    public var debugDescription: String {
        """
        NIOHTTP2Handler(
            stateMachine: \(String(describing: self.stateMachine)),
            frameDecoder: \(String(describing: self.frameDecoder)),
            frameEncoder: \(String(describing: self.frameEncoder)),
            writeBuffer: \(String(describing: self.writeBuffer)),
            inboundEventBuffer: \(String(describing: self.inboundEventBuffer)),
            outboundBuffer: \(String(describing: self.outboundBuffer)),
            wroteFrame: \(String(describing: self.wroteFrame)),
            denialOfServiceValidator: \(String(describing: self.denialOfServiceValidator)),
            mode: \(String(describing: self.mode)),
            initialSettings: \(String(describing: self.initialSettings)),
            channelClosed: \(String(describing: self.channelClosed)),
            channelWritable: \(String(describing: self.channelWritable)),
            activationState: \(String(describing: self.activationState))
        )
        """
    }
}

extension NIOHTTP2Handler {
    /// Tracks the state of activation of the handler.
    enum ActivationState {
        /// The handler hasn't been activated yet.
        case idle

        /// The handler has received channelActive, but hasn't yet fired it on.
        case activating

        /// The handler was activating when it received channelInactive. The channel
        /// must go inactive after firing channel active.
        case inactiveWhileActivating

        /// The channel has received and fired channelActive.
        case activated

        /// The channel has received and fired channelActive and channelInactive.
        case inactive
    }

    fileprivate func impossibleActivationStateTransition(
        state: ActivationState,
        activating: Bool,
        context: ChannelHandlerContext
    ) {
        assert(self.tolerateImpossibleStateTransitionsInDebugMode, "Unexpected channelActive in state \(state)")
        context.fireErrorCaught(NIOHTTP2Errors.ActivationError(state: state, activating: activating))
        context.close(promise: nil)
    }
}

extension NIOHTTP2Handler {
    /// Exposes restricted API for use by the multiplexer
    internal struct OutboundView {
        private let http2Handler: NIOHTTP2Handler

        fileprivate init(http2Handler: NIOHTTP2Handler) {
            self.http2Handler = http2Handler
        }

        func flush(context: ChannelHandlerContext) {
            self.http2Handler.flush(context: context)
        }

        func write(context: ChannelHandlerContext, frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
            self.http2Handler.writeBufferedFrame(context: context, frame: frame, promise: promise)
        }
    }
}

extension NIOHTTP2Handler {
    /// The type of all `inboundStreamInitializer` callbacks which do not need to return data.
    public typealias StreamInitializer = NIOChannelInitializer
    /// The type of NIO Channel initializer callbacks which need to return untyped data.
    @usableFromInline
    internal typealias StreamInitializerWithAnyOutput = @Sendable (Channel) -> EventLoopFuture<any Sendable>

    /// Creates a new ``NIOHTTP2Handler`` with a local multiplexer. (i.e. using
    /// ``StreamMultiplexer``.)
    ///
    /// Frames on the root stream will continue to be passed down the main channel, whereas those intended for
    /// other streams will be forwarded to the appropriate child channel.
    ///
    /// To create streams using the local multiplexer, first obtain it via the computed property (`multiplexer`)
    /// and then invoke one of the `multiplexer.createStreamChannel` methods. If possible the multiplexer should be
    /// stored and used across multiple invocations because obtaining it requires synchronizing on the event loop.
    ///
    /// The optional `streamDelegate` will be notified of stream creation and
    /// close events.
    public convenience init(
        mode: ParserMode,
        eventLoop: EventLoop,
        connectionConfiguration: ConnectionConfiguration = .init(),
        streamConfiguration: StreamConfiguration = .init(),
        streamDelegate: NIOHTTP2StreamDelegate? = nil,
        inboundStreamInitializer: @escaping StreamInitializer
    ) {
        self.init(
            mode: mode,
            eventLoop: eventLoop,
            initialSettings: connectionConfiguration.initialSettings,
            headerBlockValidation: connectionConfiguration.headerBlockValidation,
            contentLengthValidation: connectionConfiguration.contentLengthValidation,
            maximumSequentialEmptyDataFrames: connectionConfiguration.maximumSequentialEmptyDataFrames,
            maximumBufferedControlFrames: connectionConfiguration.maximumBufferedControlFrames,
            maximumSequentialContinuationFrames: connectionConfiguration.maximumSequentialContinuationFrames,
            maximumRecentlyResetStreams: connectionConfiguration.maximumRecentlyResetStreams,
            maximumConnectionGlitches: connectionConfiguration.maximumConnectionGlitches,
            maximumResetFrameCount: streamConfiguration.streamResetFrameRateLimit.maximumCount,
            resetFrameCounterWindow: streamConfiguration.streamResetFrameRateLimit.windowLength,
            maximumStreamErrorCount: streamConfiguration.streamErrorRateLimit.maximumCount,
            streamErrorCounterWindow: streamConfiguration.streamErrorRateLimit.windowLength,
            frameDelegate: nil
        )

        self.inboundStreamMultiplexerState = .uninitializedInline(
            streamConfiguration,
            inboundStreamInitializer,
            streamDelegate
        )
    }

    @usableFromInline
    internal convenience init(
        mode: ParserMode,
        eventLoop: EventLoop,
        connectionConfiguration: ConnectionConfiguration = .init(),
        streamConfiguration: StreamConfiguration = .init(),
        streamDelegate: NIOHTTP2StreamDelegate? = nil,
        frameDelegate: NIOHTTP2FrameDelegate?,
        inboundStreamInitializerWithAnyOutput: @escaping StreamInitializerWithAnyOutput
    ) {
        self.init(
            mode: mode,
            eventLoop: eventLoop,
            initialSettings: connectionConfiguration.initialSettings,
            headerBlockValidation: connectionConfiguration.headerBlockValidation,
            contentLengthValidation: connectionConfiguration.contentLengthValidation,
            maximumSequentialEmptyDataFrames: connectionConfiguration.maximumSequentialEmptyDataFrames,
            maximumBufferedControlFrames: connectionConfiguration.maximumBufferedControlFrames,
            maximumSequentialContinuationFrames: connectionConfiguration.maximumSequentialContinuationFrames,
            maximumRecentlyResetStreams: connectionConfiguration.maximumRecentlyResetStreams,
            maximumConnectionGlitches: connectionConfiguration.maximumConnectionGlitches,
            maximumResetFrameCount: streamConfiguration.streamResetFrameRateLimit.maximumCount,
            resetFrameCounterWindow: streamConfiguration.streamResetFrameRateLimit.windowLength,
            maximumStreamErrorCount: streamConfiguration.streamErrorRateLimit.maximumCount,
            streamErrorCounterWindow: streamConfiguration.streamErrorRateLimit.windowLength,
            frameDelegate: frameDelegate
        )
        self.inboundStreamMultiplexerState = .uninitializedAsync(
            streamConfiguration,
            inboundStreamInitializerWithAnyOutput,
            streamDelegate
        )
    }

    /// Connection-level configuration.
    ///
    /// The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    /// handshake.
    public struct ConnectionConfiguration: Hashable, Sendable {
        public var initialSettings: HTTP2Settings = nioDefaultSettings
        public var headerBlockValidation: ValidationState = .enabled
        public var contentLengthValidation: ValidationState = .enabled
        public var maximumSequentialEmptyDataFrames: Int = 1
        public var maximumBufferedControlFrames: Int = 10000
        public var maximumSequentialContinuationFrames: Int = NIOHTTP2Handler.defaultMaximumSequentialContinuationFrames
        public var maximumRecentlyResetStreams: Int = NIOHTTP2Handler.defaultMaximumRecentlyResetFrames

        /// The maximum number of glitches that are allowed on a connection before it's forcefully closed.
        ///
        /// A glitch is defined as some suspicious event on a connection, i.e., similar to a DoS attack.
        /// A running count of the number of glitches occurring on each connection will be kept.
        /// When the number of glitches reaches this threshold, the connection will be closed.
        ///
        /// For more information, see the relevant presentation of the 2024 HTTP Workshop:
        /// https://github.com/HTTPWorkshop/workshop2024/blob/main/talks/1.%20Security/glitches.pdf
        public var maximumConnectionGlitches: Int = GlitchesMonitor.defaultMaximumGlitches

        public init() {}
    }

    /// Stream-level configuration.
    ///
    /// The settings that will be used when establishing new streams. These mainly pertain to flow control.
    public struct StreamConfiguration: Hashable, Sendable {
        public var targetWindowSize: Int = 65535
        public var outboundBufferSizeHighWatermark: Int = 8196
        public var outboundBufferSizeLowWatermark: Int = 4092
        public var streamResetFrameRateLimit: StreamResetFrameRateLimitConfiguration = .init()
        public var streamErrorRateLimit: StreamErrorRateLimitConfiguration = .init()
        public init() {}
    }

    /// Stream reset frame rate limit configuration.
    ///
    /// The settings that control the maximum permitted reset frames within a given time window. Too many may exhaust CPU resources.
    /// To protect against this DoS vector we put an upper limit on this rate.
    public struct StreamResetFrameRateLimitConfiguration: Hashable, Sendable {
        public var maximumCount: Int = 200
        public var windowLength: TimeAmount = .seconds(30)
        public init() {}
    }

    /// Stream error rate limit configuration.
    ///
    /// The settings that control the maximum permitted stream errors within a given time window.
    public struct StreamErrorRateLimitConfiguration: Hashable, Sendable {
        public var maximumCount: Int = 200
        public var windowLength: TimeAmount = .seconds(30)
        public init() {}
    }

    /// Overall connection and stream-level configuration.
    public struct Configuration: Hashable, Sendable {
        /// The settings that will be used when establishing the connection. These will be sent to the peer as part of the
        /// handshake.
        public var connection: ConnectionConfiguration
        /// The settings that will be used when establishing new streams. These mainly pertain to flow control.
        public var stream: StreamConfiguration

        public init() {
            self.connection = .init()
            self.stream = .init()
        }

        public init(connection: ConnectionConfiguration, stream: StreamConfiguration) {
            self.connection = connection
            self.stream = stream
        }
    }

    /// An `EventLoopFuture` which returns a ``StreamMultiplexer`` which can be used to create new outbound HTTP/2 streams.
    ///
    /// > Note: This is only safe to get if the ``NIOHTTP2Handler`` uses a local multiplexer,
    /// i.e. it was initialized with an `inboundStreamInitializer`.
    public var multiplexer: EventLoopFuture<StreamMultiplexer> {
        // We need to return a future here so that we can synchronize access on the underlying `self.inboundStreamMultiplexer`
        if self._eventLoop!.inEventLoop {
            return self._eventLoop!.makeCompletedFuture {
                try self.syncMultiplexer()
            }
        } else {
            let unsafeSelf = UnsafeTransfer(self)
            return self._eventLoop!.submit {
                try unsafeSelf.wrappedValue.syncMultiplexer()
            }
        }
    }

    /// Synchronously return a ``StreamMultiplexer`` which can be used to create new outbound HTTP/2 streams.
    ///
    /// > Note: This is only safe to call if both:
    /// > - The ``NIOHTTP2Handler`` uses a local multiplexer, i.e. it was initialized with an `inboundStreamInitializer`.
    /// > - The caller is already on the correct event loop.
    public func syncMultiplexer() throws -> StreamMultiplexer {
        self._eventLoop!.preconditionInEventLoop()
        guard let inboundStreamMultiplexer = self.inboundStreamMultiplexer else {
            throw NIOHTTP2Errors.missingMultiplexer()
        }

        switch inboundStreamMultiplexer {
        case let .inline(multiplexer):
            return StreamMultiplexer(multiplexer, eventLoop: self._eventLoop!)
        case .legacy:
            throw NIOHTTP2Errors.missingMultiplexer()
        }
    }

    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    internal func syncAsyncStreamMultiplexer<Output: Sendable>(
        continuation: any AnyContinuation,
        inboundStreamChannels: NIOHTTP2AsyncSequence<Output>
    ) throws -> AsyncStreamMultiplexer<Output> {
        self._eventLoop!.preconditionInEventLoop()
        guard let inboundStreamMultiplexer = self.inboundStreamMultiplexer else {
            throw NIOHTTP2Errors.missingMultiplexer()
        }

        switch inboundStreamMultiplexer {
        case let .inline(multiplexer):
            return AsyncStreamMultiplexer(
                multiplexer,
                eventLoop: self._eventLoop!,
                continuation: continuation,
                inboundStreamChannels: inboundStreamChannels
            )
        case .legacy:
            throw NIOHTTP2Errors.missingMultiplexer()
        }
    }
}
