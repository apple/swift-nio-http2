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
import NIOHTTP1
import NIOTLS

/// The supported ALPN protocol tokens for NIO's HTTP/2 abstraction layer.
///
/// These can be used to configure your TLS handler appropriately such that it
/// can negotiate HTTP/2 on secure connections. For example, using swift-nio-ssl,
/// you could configure the pipeline like this:
///
/// ```swift
/// let config = TLSConfiguration.forClient(applicationProtocols: NIOHTTP2SupportedALPNProtocols)
/// let context = try SSLContext(configuration: config)
/// channel.pipeline.add(handler: OpenSSLClientHandler(context: context, serverHostname: "example.com")).then {
///     channel.pipeline.configureHTTP2SecureUpgrade(...)
/// }
/// ```
///
/// Configuring for servers is very similar.
public let NIOHTTP2SupportedALPNProtocols = ["h2", "http/1.1"]

/// Legacy type of NIO Channel initializer callbacks which take `HTTP2StreamID` as a parameter.
public typealias NIOChannelInitializerWithStreamID = @Sendable (Channel, HTTP2StreamID) -> EventLoopFuture<Void>
/// The type of NIO Channel initializer callbacks which do not need to return data.
public typealias NIOChannelInitializer = @Sendable (Channel) -> EventLoopFuture<Void>
/// The type of NIO Channel initializer callbacks which need to return data.
public typealias NIOChannelInitializerWithOutput<Output> = @Sendable (Channel) -> EventLoopFuture<Output>

extension ChannelPipeline {
    /// Configures a channel pipeline to perform a HTTP/2 secure upgrade.
    ///
    /// HTTP/2 secure upgrade uses the Application Layer Protocol Negotiation TLS extension to
    /// negotiate the inner protocol as part of the TLS handshake. For this reason, until the TLS
    /// handshake is complete, the ultimate configuration of the channel pipeline cannot be known.
    ///
    /// This function configures the pipeline with a pair of callbacks that will handle the result
    /// of the negotiation. It explicitly **does not** configure a TLS handler to actually attempt
    /// to negotiate ALPN. The supported ALPN protocols are provided in
    /// `NIOHTTP2SupportedALPNProtocols`: please ensure that the TLS handler you are using for your
    /// pipeline is appropriately configured to perform this protocol negotiation.
    ///
    /// If negotiation results in an unexpected protocol, the pipeline will close the connection
    /// and no callback will fire.
    ///
    /// This configuration is acceptable for use on both client and server channel pipelines.
    ///
    /// - Parameters:
    ///   - h2PipelineConfigurator: A callback that will be invoked if HTTP/2 has been negotiated, and that
    ///         should configure the pipeline for HTTP/2 use. Must return a future that completes when the
    ///         pipeline has been fully mutated.
    ///   - http1PipelineConfigurator: A callback that will be invoked if HTTP/1.1 has been explicitly
    ///         negotiated, or if no protocol was negotiated. Must return a future that completes when the
    ///         pipeline has been fully mutated.
    /// - Returns: An `EventLoopFuture<Void>` that completes when the pipeline is ready to negotiate.
    @available(
        *,
        deprecated,
        renamed: "Channel.configureHTTP2SecureUpgrade(h2ChannelConfigurator:http1ChannelConfigurator:)"
    )
    @preconcurrency
    public func configureHTTP2SecureUpgrade(
        h2PipelineConfigurator: @escaping @Sendable (ChannelPipeline) -> EventLoopFuture<Void>,
        http1PipelineConfigurator: @escaping @Sendable (ChannelPipeline) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        @Sendable
        func makeALPNHandler() -> ApplicationProtocolNegotiationHandler {
            ApplicationProtocolNegotiationHandler { result in
                switch result {
                case .negotiated("h2"):
                    // Successful upgrade to HTTP/2. Let the user configure the pipeline.
                    return h2PipelineConfigurator(self)
                case .negotiated("http/1.1"), .fallback:
                    // Explicit or implicit HTTP/1.1 choice.
                    return http1PipelineConfigurator(self)
                case .negotiated:
                    // We negotiated something that isn't HTTP/1.1. This is a bad scene, and is a good indication
                    // of a user configuration error. We're going to close the connection directly.
                    return self.close().flatMap { self.eventLoop.makeFailedFuture(NIOHTTP2Errors.InvalidALPNToken()) }
                }
            }
        }

        if self.eventLoop.inEventLoop {
            return self.eventLoop.assumeIsolatedUnsafeUnchecked().makeCompletedFuture {
                try self.syncOperations.addHandler(makeALPNHandler())
            }
        } else {
            return self.eventLoop.submit {
                try self.syncOperations.addHandler(makeALPNHandler())
            }
        }
    }
}

extension Channel {
    /// Configures a `ChannelPipeline` to speak HTTP/2.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handlers required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Whenever possible use this function to setup a HTTP/2 server pipeline, as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - initialLocalSettings: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///   - position: The position in the pipeline into which to insert these handlers.
    ///   - inboundStreamStateInitializer: A closure that will be called whenever the remote peer initiates a new stream. This should almost always
    ///         be provided, especially on servers.
    /// - Returns: An `EventLoopFuture` containing the `HTTP2StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
    @available(
        *,
        deprecated,
        renamed: "configureHTTP2Pipeline(mode:initialLocalSettings:position:targetWindowSize:inboundStreamInitializer:)"
    )
    public func configureHTTP2Pipeline(
        mode: NIOHTTP2Handler.ParserMode,
        initialLocalSettings: [HTTP2Setting] = nioDefaultSettings,
        position: ChannelPipeline.Position = .last,
        inboundStreamStateInitializer: NIOChannelInitializerWithStreamID? = nil
    ) -> EventLoopFuture<HTTP2StreamMultiplexer> {
        self.configureHTTP2Pipeline(
            mode: mode,
            initialLocalSettings: initialLocalSettings,
            position: position,
            targetWindowSize: 65535,
            inboundStreamStateInitializer: inboundStreamStateInitializer
        )
    }

    /// Configures a `ChannelPipeline` to speak HTTP/2.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handlers required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Whenever possible use this function to setup a HTTP/2 server pipeline, as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - initialLocalSettings: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///   - position: The position in the pipeline into which to insert these handlers.
    ///   - targetWindowSize: The target size of the HTTP/2 flow control window.
    ///   - inboundStreamStateInitializer: A closure that will be called whenever the remote peer initiates a new stream. This should almost always
    ///         be provided, especially on servers.
    /// - Returns: An `EventLoopFuture` containing the `HTTP2StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
    @available(
        *,
        deprecated,
        renamed: "configureHTTP2Pipeline(mode:initialLocalSettings:position:targetWindowSize:inboundStreamInitializer:)"
    )
    public func configureHTTP2Pipeline(
        mode: NIOHTTP2Handler.ParserMode,
        initialLocalSettings: [HTTP2Setting] = nioDefaultSettings,
        position: ChannelPipeline.Position = .last,
        targetWindowSize: Int,
        inboundStreamStateInitializer: NIOChannelInitializerWithStreamID? = nil
    ) -> EventLoopFuture<HTTP2StreamMultiplexer> {
        @Sendable
        func configure() throws -> HTTP2StreamMultiplexer {
            let http2 = NIOHTTP2Handler(mode: mode, initialSettings: initialLocalSettings)
            let multiplexer = HTTP2StreamMultiplexer(
                mode: mode,
                channel: self,
                targetWindowSize: targetWindowSize,
                inboundStreamStateInitializer: inboundStreamStateInitializer
            )

            let handlers: [any ChannelHandler] = [http2, multiplexer]
            try self.pipeline.syncOperations.addHandlers(handlers, position: position)
            return multiplexer
        }

        if self.eventLoop.inEventLoop {
            return self.eventLoop.assumeIsolatedUnsafeUnchecked().makeCompletedFuture {
                try configure()
            }
        } else {
            return self.eventLoop.submit {
                try configure()
            }
        }
    }

    /// Configures a `ChannelPipeline` to speak HTTP/2.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handlers required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Whenever possible use this function to setup a HTTP/2 server pipeline, as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - initialLocalSettings: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///   - position: The position in the pipeline into which to insert these handlers.
    ///   - targetWindowSize: The target size of the HTTP/2 flow control window.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream. This should almost always
    ///         be provided, especially on servers.
    /// - Returns: An `EventLoopFuture` containing the `HTTP2StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
    public func configureHTTP2Pipeline(
        mode: NIOHTTP2Handler.ParserMode,
        initialLocalSettings: [HTTP2Setting] = nioDefaultSettings,
        position: ChannelPipeline.Position = .last,
        targetWindowSize: Int = 65535,
        inboundStreamInitializer: NIOChannelInitializer?
    ) -> EventLoopFuture<HTTP2StreamMultiplexer> {
        @Sendable
        func configure() throws -> HTTP2StreamMultiplexer {
            try self.pipeline.syncOperations.configureHTTP2Pipeline(
                mode: mode,
                channel: self,
                initialLocalSettings: initialLocalSettings,
                position: ChannelPipeline.SynchronousOperations.Position(position),
                targetWindowSize: targetWindowSize,
                inboundStreamInitializer: inboundStreamInitializer
            )
        }

        if self.eventLoop.inEventLoop {
            return self.eventLoop.assumeIsolatedUnsafeUnchecked().makeCompletedFuture {
                try configure()
            }
        } else {
            return self.eventLoop.submit {
                try configure()
            }
        }
    }

    /// Configures a `ChannelPipeline` to speak HTTP/2.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Whenever possible use this function to setup a HTTP/2 server pipeline, as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - connectionConfiguration: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///   - streamConfiguration: The settings that will be used when establishing new streams. These mainly pertain to flow control.
    ///   - streamDelegate: The delegate to be notified in the event of stream creation and close.
    ///   - position: The position in the pipeline into which to insert this handler.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    /// - Returns: An `EventLoopFuture` containing the `StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
    public func configureHTTP2Pipeline(
        mode: NIOHTTP2Handler.ParserMode,
        connectionConfiguration: NIOHTTP2Handler.ConnectionConfiguration,
        streamConfiguration: NIOHTTP2Handler.StreamConfiguration,
        streamDelegate: NIOHTTP2StreamDelegate? = nil,
        position: ChannelPipeline.Position = .last,
        inboundStreamInitializer: @escaping NIOChannelInitializer
    ) -> EventLoopFuture<NIOHTTP2Handler.StreamMultiplexer> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture {
                try self.pipeline.syncOperations.configureHTTP2Pipeline(
                    mode: mode,
                    connectionConfiguration: connectionConfiguration,
                    streamConfiguration: streamConfiguration,
                    streamDelegate: streamDelegate,
                    position: position,
                    inboundStreamInitializer: inboundStreamInitializer
                )
            }
        } else {
            return self.eventLoop.submit {
                try self.pipeline.syncOperations.configureHTTP2Pipeline(
                    mode: mode,
                    connectionConfiguration: connectionConfiguration,
                    streamConfiguration: streamConfiguration,
                    streamDelegate: streamDelegate,
                    position: position,
                    inboundStreamInitializer: inboundStreamInitializer
                )
            }
        }
    }

    /// Configures a channel to perform an HTTP/2 secure upgrade.
    ///
    /// HTTP/2 secure upgrade uses the Application Layer Protocol Negotiation TLS extension to
    /// negotiate the inner protocol as part of the TLS handshake. For this reason, until the TLS
    /// handshake is complete, the ultimate configuration of the channel pipeline cannot be known.
    ///
    /// This function configures the channel with a pair of callbacks that will handle the result
    /// of the negotiation. It explicitly **does not** configure a TLS handler to actually attempt
    /// to negotiate ALPN. The supported ALPN protocols are provided in
    /// `NIOHTTP2SupportedALPNProtocols`: please ensure that the TLS handler you are using for your
    /// pipeline is appropriately configured to perform this protocol negotiation.
    ///
    /// If negotiation results in an unexpected protocol, the pipeline will close the connection
    /// and no callback will fire.
    ///
    /// This configuration is acceptable for use on both client and server channel pipelines.
    ///
    /// - Parameters:
    ///   - h2ChannelConfigurator: A callback that will be invoked if HTTP/2 has been negotiated, and that
    ///         should configure the channel for HTTP/2 use. Must return a future that completes when the
    ///         channel has been fully mutated.
    ///   - http1ChannelConfigurator: A callback that will be invoked if HTTP/1.1 has been explicitly
    ///         negotiated, or if no protocol was negotiated. Must return a future that completes when the
    ///         channel has been fully mutated.
    /// - Returns: An `EventLoopFuture<Void>` that completes when the channel is ready to negotiate.
    public func configureHTTP2SecureUpgrade(
        h2ChannelConfigurator: @escaping NIOChannelInitializer,
        http1ChannelConfigurator: @escaping NIOChannelInitializer
    ) -> EventLoopFuture<Void> {
        @Sendable
        func makeALPNHandler() -> ApplicationProtocolNegotiationHandler {
            ApplicationProtocolNegotiationHandler { result in
                switch result {
                case .negotiated("h2"):
                    // Successful upgrade to HTTP/2. Let the user configure the pipeline.
                    return h2ChannelConfigurator(self)
                case .negotiated("http/1.1"), .fallback:
                    // Explicit or implicit HTTP/1.1 choice.
                    return http1ChannelConfigurator(self)
                case .negotiated:
                    // We negotiated something that isn't HTTP/1.1. This is a bad scene, and is a good indication
                    // of a user configuration error. We're going to close the connection directly.
                    return self.close().flatMap { self.eventLoop.makeFailedFuture(NIOHTTP2Errors.invalidALPNToken()) }
                }
            }
        }

        if self.eventLoop.inEventLoop {
            let alpnHandler = makeALPNHandler()
            return self.eventLoop.makeCompletedFuture {
                try self.pipeline.syncOperations.addHandler(alpnHandler)
            }
        } else {
            return self.eventLoop.submit {
                let alpnHandler = makeALPNHandler()
                try self.pipeline.syncOperations.addHandler(alpnHandler)
            }
        }
    }

    /// Configures a `ChannelPipeline` to speak either HTTP/1.1 or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2. Once the protocol to use for the channel has been negotiated, the
    /// provided callback will configure the application-specific handlers in a protocol-agnostic way.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - Parameters:
    ///   - h2ConnectionChannelConfigurator: An optional callback that will be invoked only
    ///         when the negotiated protocol is H2 to configure the connection channel.
    ///   - configurator: A callback that will be invoked after a protocol has been negotiated.
    ///         The callback only needs to add application-specific handlers and must return a future
    ///         that completes when the channel has been fully mutated.
    /// - Returns: `EventLoopFuture<Void>` that completes when the channel is ready.
    public func configureCommonHTTPServerPipeline(
        h2ConnectionChannelConfigurator: NIOChannelInitializer? = nil,
        _ configurator: @escaping NIOChannelInitializer
    ) -> EventLoopFuture<Void> {
        self.configureCommonHTTPServerPipeline(
            h2ConnectionChannelConfigurator: h2ConnectionChannelConfigurator,
            targetWindowSize: 65535,
            configurator
        )
    }

    /// Configures a `ChannelPipeline` to speak either HTTP/1.1 or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2. Once the protocol to use for the channel has been negotiated, the
    /// provided callback will configure the application-specific handlers in a protocol-agnostic way.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - Parameters:
    ///   - h2ConnectionChannelConfigurator: An optional callback that will be invoked only
    ///         when the negotiated protocol is H2 to configure the connection channel.
    ///   - targetWindowSize: The target size of the HTTP/2 flow control window.
    ///   - configurator: A callback that will be invoked after a protocol has been negotiated.
    ///         The callback only needs to add application-specific handlers and must return a future
    ///         that completes when the channel has been fully mutated.
    /// - Returns: `EventLoopFuture<Void>` that completes when the channel is ready.
    public func configureCommonHTTPServerPipeline(
        h2ConnectionChannelConfigurator: NIOChannelInitializer? = nil,
        targetWindowSize: Int,
        _ configurator: @escaping NIOChannelInitializer
    ) -> EventLoopFuture<Void> {
        self._commonHTTPServerPipeline(
            configurator: configurator,
            h2ConnectionChannelConfigurator: h2ConnectionChannelConfigurator
        ) { channel in
            channel.configureHTTP2Pipeline(
                mode: .server,
                targetWindowSize: targetWindowSize
            ) { streamChannel -> EventLoopFuture<Void> in
                do {
                    let sync = streamChannel.pipeline.syncOperations
                    try sync.addHandlers(HTTP2FramePayloadToHTTP1ServerCodec())
                } catch {
                    return streamChannel.eventLoop.makeFailedFuture(error)
                }

                return configurator(streamChannel)
            }.map { _ in () }
        }
    }

    /// Configures a `ChannelPipeline` to speak either HTTP/1.1 or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2. Once the protocol to use for the channel has been negotiated, the
    /// provided callback will configure the application-specific handlers in a protocol-agnostic way.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - Parameters:
    ///   - connectionConfiguration: The settings that will be used when establishing the HTTP/2 connection. These will be sent to the peer as part of the
    ///         handshake.
    ///   - streamConfiguration: The settings that will be used when establishing new HTTP/2 streams. These mainly pertain to flow control.
    ///   - streamDelegate: The delegate to be notified in the event of stream creation and close.
    ///   - h2ConnectionChannelConfigurator: An optional callback that will be invoked only
    ///         when the negotiated protocol is H2 to configure the connection channel.
    ///   - configurator: A callback that will be invoked after a protocol has been negotiated.
    ///         The callback only needs to add application-specific handlers and must return a future
    ///         that completes when the channel has been fully mutated.
    /// - Returns: `EventLoopFuture<Void>` that completes when the channel is ready.
    public func configureCommonHTTPServerPipeline(
        connectionConfiguration: NIOHTTP2Handler.ConnectionConfiguration,
        streamConfiguration: NIOHTTP2Handler.StreamConfiguration,
        streamDelegate: NIOHTTP2StreamDelegate? = nil,
        h2ConnectionChannelConfigurator: NIOChannelInitializer? = nil,
        configurator: @escaping NIOChannelInitializer
    ) -> EventLoopFuture<Void> {
        self._commonHTTPServerPipeline(
            configurator: configurator,
            h2ConnectionChannelConfigurator: h2ConnectionChannelConfigurator
        ) { channel in
            channel.configureHTTP2Pipeline(
                mode: .server,
                connectionConfiguration: connectionConfiguration,
                streamConfiguration: streamConfiguration,
                streamDelegate: streamDelegate
            ) { streamChannel -> EventLoopFuture<Void> in
                do {
                    let sync = streamChannel.pipeline.syncOperations
                    try sync.addHandlers(HTTP2FramePayloadToHTTP1ServerCodec())
                } catch {
                    return streamChannel.eventLoop.makeFailedFuture(error)
                }

                return configurator(streamChannel)
            }.map { _ in () }
        }
    }

    private func _commonHTTPServerPipeline(
        configurator: @escaping NIOChannelInitializer,
        h2ConnectionChannelConfigurator: NIOChannelInitializer?,
        configureHTTP2Pipeline: @escaping NIOChannelInitializer
    ) -> EventLoopFuture<Void> {
        let h2ChannelConfigurator: NIOChannelInitializer = { channel in
            configureHTTP2Pipeline(channel).flatMap { _ in
                if let h2ConnectionChannelConfigurator = h2ConnectionChannelConfigurator {
                    return h2ConnectionChannelConfigurator(channel)
                } else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
            }
        }
        let http1ChannelConfigurator: NIOChannelInitializer = { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
                configurator(channel)
            }
        }
        return self.configureHTTP2SecureUpgrade(
            h2ChannelConfigurator: h2ChannelConfigurator,
            http1ChannelConfigurator: http1ChannelConfigurator
        )
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Synchronously configures a `ChannelPipeline` to speak HTTP/2.
    ///
    /// This operation **must** be called on the event loop.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Whenever possible use this function to setup a HTTP/2 server pipeline, as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - connectionConfiguration: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///   - streamConfiguration: The settings that will be used when establishing new streams. These mainly pertain to flow control.
    ///   - streamDelegate: The delegate to be notified in the event of stream creation and close.
    ///   - position: The position in the pipeline into which to insert this handler.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    /// - Returns: The `StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
    public func configureHTTP2Pipeline(
        mode: NIOHTTP2Handler.ParserMode,
        connectionConfiguration: NIOHTTP2Handler.ConnectionConfiguration,
        streamConfiguration: NIOHTTP2Handler.StreamConfiguration,
        streamDelegate: NIOHTTP2StreamDelegate? = nil,
        position: ChannelPipeline.Position = .last,
        inboundStreamInitializer: @escaping NIOChannelInitializer
    ) throws -> NIOHTTP2Handler.StreamMultiplexer {
        let handler = NIOHTTP2Handler(
            mode: mode,
            eventLoop: self.eventLoop,
            connectionConfiguration: connectionConfiguration,
            streamConfiguration: streamConfiguration,
            streamDelegate: streamDelegate,
            inboundStreamInitializer: inboundStreamInitializer
        )

        try self.addHandler(handler, position: Position(position))

        // `multiplexer` will always be non-nil when we are initializing with an `inboundStreamInitializer`
        return try handler.syncMultiplexer()
    }

    /// Synchronously configures a `ChannelPipeline` to speak HTTP/2.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handlers required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Whenever possible use this function to setup a HTTP/2 server pipeline, as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - channel: to which the created``HTTP2StreamMultiplexer`` will belong.
    ///   - initialLocalSettings: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///   - position: The position in the pipeline into which to insert these handlers.
    ///   - targetWindowSize: The target size of the HTTP/2 flow control window.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream. This should almost always
    ///         be provided, especially on servers.
    /// - Returns: An `EventLoopFuture` containing the `HTTP2StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
    internal func configureHTTP2Pipeline(
        mode: NIOHTTP2Handler.ParserMode,
        channel: Channel,
        initialLocalSettings: [HTTP2Setting] = nioDefaultSettings,
        position: ChannelPipeline.SynchronousOperations.Position = .last,
        targetWindowSize: Int = 65535,
        inboundStreamInitializer: NIOChannelInitializer?
    ) throws -> HTTP2StreamMultiplexer {
        let http2Handler = NIOHTTP2Handler(mode: mode, initialSettings: initialLocalSettings)
        let multiplexer = HTTP2StreamMultiplexer(
            mode: mode,
            channel: channel,
            targetWindowSize: targetWindowSize,
            inboundStreamInitializer: inboundStreamInitializer
        )
        try self.addHandler(http2Handler, position: position)
        try self.addHandler(multiplexer, position: .after(http2Handler))

        return multiplexer
    }
}

// MARK: Async configurations

extension Channel {
    /// Configures a `ChannelPipeline` to speak HTTP/2 and sets up mapping functions so that it may be interacted with from concurrent code.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Use this function to setup a HTTP/2 pipeline if you wish to use async sequence abstractions over inbound and outbound streams.
    /// Using this rather than implementing a similar function yourself allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - configuration: The settings that will be used when establishing the connection and new streams.
    ///   - streamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    ///     be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTP2Pipeline<Output: Sendable>(
        mode: NIOHTTP2Handler.ParserMode,
        configuration: NIOHTTP2Handler.Configuration = .init(),
        streamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) -> EventLoopFuture<NIOHTTP2Handler.AsyncStreamMultiplexer<Output>> {
        self.configureAsyncHTTP2Pipeline(
            mode: mode,
            streamDelegate: nil,
            configuration: configuration,
            streamInitializer: streamInitializer
        )
    }

    /// Configures a `ChannelPipeline` to speak HTTP/2 and sets up mapping functions so that it may be interacted with from concurrent code.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Use this function to setup a HTTP/2 pipeline if you wish to use async sequence abstractions over inbound and outbound streams.
    /// Using this rather than implementing a similar function yourself allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - streamDelegate: A delegate which is called when streams are created and closed.
    ///   - configuration: The settings that will be used when establishing the connection and new streams.
    ///   - streamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    ///     be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTP2Pipeline<Output: Sendable>(
        mode: NIOHTTP2Handler.ParserMode,
        streamDelegate: NIOHTTP2StreamDelegate?,
        configuration: NIOHTTP2Handler.Configuration = NIOHTTP2Handler.Configuration(),
        streamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) -> EventLoopFuture<NIOHTTP2Handler.AsyncStreamMultiplexer<Output>> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture {
                try self.pipeline.syncOperations.configureAsyncHTTP2Pipeline(
                    mode: mode,
                    streamDelegate: streamDelegate,
                    configuration: configuration,
                    streamInitializer: streamInitializer
                )
            }
        } else {
            return self.eventLoop.submit {
                try self.pipeline.syncOperations.configureAsyncHTTP2Pipeline(
                    mode: mode,
                    streamDelegate: streamDelegate,
                    configuration: configuration,
                    streamInitializer: streamInitializer
                )
            }
        }
    }

    /// Configures a channel to perform an HTTP/2 secure upgrade with typed negotiation results.
    ///
    /// HTTP/2 secure upgrade uses the Application Layer Protocol Negotiation TLS extension to
    /// negotiate the inner protocol as part of the TLS handshake. For this reason, until the TLS
    /// handshake is complete, the ultimate configuration of the channel pipeline cannot be known.
    ///
    /// This function configures the channel with a pair of callbacks that will handle the result
    /// of the negotiation. It explicitly **does not** configure a TLS handler to actually attempt
    /// to negotiate ALPN. The supported ALPN protocols are provided in
    /// `NIOHTTP2SupportedALPNProtocols`: please ensure that the TLS handler you are using for your
    /// pipeline is appropriately configured to perform this protocol negotiation.
    ///
    /// If negotiation results in an unexpected protocol, the pipeline will close the connection
    /// and no callback will fire.
    ///
    /// This configuration is acceptable for use on both client and server channel pipelines.
    ///
    /// - Parameters:
    ///   - http1ConnectionInitializer: A callback that will be invoked if HTTP/1.1 has been explicitly
    ///         negotiated, or if no protocol was negotiated. Must return a future that completes when the
    ///         channel has been fully mutated.
    ///   - http2ConnectionInitializer: A callback that will be invoked if HTTP/2 has been negotiated, and that
    ///         should configure the channel for HTTP/2 use. Must return a future that completes when the
    ///         channel has been fully mutated.
    /// - Returns: An `EventLoopFuture` of an `EventLoopFuture` containing the `NIOProtocolNegotiationResult` that completes when the channel
    ///     is ready to negotiate.
    @inlinable
    public func configureHTTP2AsyncSecureUpgrade<HTTP1Output: Sendable, HTTP2Output: Sendable>(
        http1ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP1Output>,
        http2ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2Output>
    ) -> EventLoopFuture<EventLoopFuture<NIONegotiatedHTTPVersion<HTTP1Output, HTTP2Output>>> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture {
                self.pipeline.syncOperations.configureHTTP2AsyncSecureUpgrade(
                    on: self,
                    http1ConnectionInitializer: http1ConnectionInitializer,
                    http2ConnectionInitializer: http2ConnectionInitializer
                )
            }
        } else {
            return self.eventLoop.submit {
                self.pipeline.syncOperations.configureHTTP2AsyncSecureUpgrade(
                    on: self,
                    http1ConnectionInitializer: http1ConnectionInitializer,
                    http2ConnectionInitializer: http2ConnectionInitializer
                )
            }
        }
    }

    /// Configures a `ChannelPipeline` to speak either HTTP/1.1 or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - Parameters:
    ///   - http2Configuration: The settings that will be used when establishing the HTTP/2 connections and new HTTP/2 streams.
    ///   - http1ConnectionInitializer: An optional callback that will be invoked only when the negotiated protocol
    ///     is HTTP/1.1 to configure the connection channel.
    ///   - http2ConnectionInitializer: An optional callback that will be invoked only when the negotiated protocol
    ///     is HTTP/2 to configure the connection channel. The channel has an `ChannelOutboundHandler/OutboundIn` type of ``HTTP2Frame``.
    ///   - http2StreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing a `NIOTypedApplicationProtocolNegotiationHandler` that completes when the channel
    ///     is ready to negotiate. This can then be used to access the `NIOProtocolNegotiationResult` which may itself
    ///     be waited on to retrieve the result of the negotiation.
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTPServerPipeline<
        HTTP1ConnectionOutput: Sendable,
        HTTP2ConnectionOutput: Sendable,
        HTTP2StreamOutput: Sendable
    >(
        http2Configuration: NIOHTTP2Handler.Configuration = .init(),
        http1ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP1ConnectionOutput>,
        http2ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2ConnectionOutput>,
        http2StreamInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2StreamOutput>
    ) -> EventLoopFuture<
        EventLoopFuture<
            NIONegotiatedHTTPVersion<
                HTTP1ConnectionOutput,
                (HTTP2ConnectionOutput, NIOHTTP2Handler.AsyncStreamMultiplexer<HTTP2StreamOutput>)
            >
        >
    > {
        self.configureAsyncHTTPServerPipeline(
            streamDelegate: nil,
            http2Configuration: http2Configuration,
            http1ConnectionInitializer: http1ConnectionInitializer,
            http2ConnectionInitializer: http2ConnectionInitializer,
            http2StreamInitializer: http2StreamInitializer
        )
    }

    /// Configures a `ChannelPipeline` to speak either HTTP/1.1 or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - Parameters:
    ///   - streamDelegate: A delegate which is called when streams are created and closed.
    ///   - http2Configuration: The settings that will be used when establishing the HTTP/2 connections and new HTTP/2 streams.
    ///   - http1ConnectionInitializer: An optional callback that will be invoked only when the negotiated protocol
    ///     is HTTP/1.1 to configure the connection channel.
    ///   - http2ConnectionInitializer: An optional callback that will be invoked only when the negotiated protocol
    ///     is HTTP/2 to configure the connection channel. The channel has an `ChannelOutboundHandler/OutboundIn` type of ``HTTP2Frame``.
    ///   - http2StreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing a `NIOTypedApplicationProtocolNegotiationHandler` that completes when the channel
    ///     is ready to negotiate. This can then be used to access the `NIOProtocolNegotiationResult` which may itself
    ///     be waited on to retrieve the result of the negotiation.
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTPServerPipeline<
        HTTP1ConnectionOutput: Sendable,
        HTTP2ConnectionOutput: Sendable,
        HTTP2StreamOutput: Sendable
    >(
        streamDelegate: NIOHTTP2StreamDelegate?,
        http2Configuration: NIOHTTP2Handler.Configuration = .init(),
        http1ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP1ConnectionOutput>,
        http2ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2ConnectionOutput>,
        http2StreamInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2StreamOutput>
    ) -> EventLoopFuture<
        EventLoopFuture<
            NIONegotiatedHTTPVersion<
                HTTP1ConnectionOutput,
                (HTTP2ConnectionOutput, NIOHTTP2Handler.AsyncStreamMultiplexer<HTTP2StreamOutput>)
            >
        >
    > {
        let http2ConnectionInitializer:
            NIOChannelInitializerWithOutput<
                (HTTP2ConnectionOutput, NIOHTTP2Handler.AsyncStreamMultiplexer<HTTP2StreamOutput>)
            > = { channel in
                channel.configureAsyncHTTP2Pipeline(
                    mode: .server,
                    streamDelegate: streamDelegate,
                    configuration: http2Configuration,
                    streamInitializer: http2StreamInitializer
                ).flatMap { multiplexer in
                    http2ConnectionInitializer(channel).map { connectionChannel in
                        (connectionChannel, multiplexer)
                    }
                }
            }
        let http1ConnectionInitializer: NIOChannelInitializerWithOutput<HTTP1ConnectionOutput> = { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
                http1ConnectionInitializer(channel)
            }
        }
        return self.configureHTTP2AsyncSecureUpgrade(
            http1ConnectionInitializer: http1ConnectionInitializer,
            http2ConnectionInitializer: http2ConnectionInitializer
        )
    }
}

extension ChannelPipeline.SynchronousOperations {
    /// Configures a `ChannelPipeline` to speak HTTP/2 and sets up mapping functions so that it may be interacted with from concurrent code.
    ///
    /// This operation **must** be called on the event loop.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Use this function to setup a HTTP/2 pipeline if you wish to use async sequence abstractions over inbound and outbound streams,
    /// as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - configuration: The settings that will be used when establishing the connection and new streams.
    ///   - streamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    /// be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTP2Pipeline<Output: Sendable>(
        mode: NIOHTTP2Handler.ParserMode,
        configuration: NIOHTTP2Handler.Configuration = .init(),
        streamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) throws -> NIOHTTP2Handler.AsyncStreamMultiplexer<Output> {
        try self.configureAsyncHTTP2Pipeline(
            mode: mode,
            streamDelegate: nil,
            configuration: configuration,
            streamInitializer: streamInitializer
        )
    }

    /// Configures a `ChannelPipeline` to speak HTTP/2 and sets up mapping functions so that it may be interacted with from concurrent code.
    ///
    /// This operation **must** be called on the event loop.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Use this function to setup a HTTP/2 pipeline if you wish to use async sequence abstractions over inbound and outbound streams,
    /// as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - streamDelegate: A delegate which is called when streams are created and closed.
    ///   - configuration: The settings that will be used when establishing the connection and new streams.
    ///   - streamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    /// be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTP2Pipeline<Output: Sendable>(
        mode: NIOHTTP2Handler.ParserMode,
        streamDelegate: NIOHTTP2StreamDelegate?,
        configuration: NIOHTTP2Handler.Configuration = NIOHTTP2Handler.Configuration(),
        streamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) throws -> NIOHTTP2Handler.AsyncStreamMultiplexer<Output> {
        try self.configureAsyncHTTP2Pipeline(
            mode: mode,
            streamDelegate: streamDelegate,
            frameDelegate: nil,
            configuration: configuration,
            streamInitializer: streamInitializer
        )
    }

    /// Configures a `ChannelPipeline` to speak HTTP/2 and sets up mapping functions so that it may be interacted with from concurrent code.
    ///
    /// This operation **must** be called on the event loop.
    ///
    /// In general this is not entirely useful by itself, as HTTP/2 is a negotiated protocol. This helper does not handle negotiation.
    /// Instead, this simply adds the handler required to speak HTTP/2 after negotiation has completed, or when agreed by prior knowledge.
    /// Use this function to setup a HTTP/2 pipeline if you wish to use async sequence abstractions over inbound and outbound streams,
    /// as it allows that pipeline to evolve without breaking your code.
    ///
    /// - Parameters:
    ///   - mode: The mode this pipeline will operate in, server or client.
    ///   - streamDelegate: A delegate which is called when streams are created and closed.
    ///   - frameDelegate: A delegate which is called when frames are written to the network.
    ///   - configuration: The settings that will be used when establishing the connection and new streams.
    ///   - streamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    ///     The output of this closure is the element type of the returned multiplexer
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    /// be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func configureAsyncHTTP2Pipeline<Output: Sendable>(
        mode: NIOHTTP2Handler.ParserMode,
        streamDelegate: NIOHTTP2StreamDelegate?,
        frameDelegate: NIOHTTP2FrameDelegate?,
        configuration: NIOHTTP2Handler.Configuration = NIOHTTP2Handler.Configuration(),
        streamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) throws -> NIOHTTP2Handler.AsyncStreamMultiplexer<Output> {
        let handler = NIOHTTP2Handler(
            mode: mode,
            eventLoop: self.eventLoop,
            connectionConfiguration: configuration.connection,
            streamConfiguration: configuration.stream,
            streamDelegate: streamDelegate,
            frameDelegate: frameDelegate,
            inboundStreamInitializerWithAnyOutput: { channel in
                streamInitializer(channel).map { $0 }
            }
        )

        try self.addHandler(handler)

        let (inboundStreamChannels, continuation) = NIOHTTP2AsyncSequence.initialize(
            inboundStreamInitializerOutput: Output.self
        )

        return try handler.syncAsyncStreamMultiplexer(
            continuation: continuation,
            inboundStreamChannels: inboundStreamChannels
        )
    }

    @inlinable
    func configureHTTP2AsyncSecureUpgrade<HTTP1Output: Sendable, HTTP2Output: Sendable>(
        on channel: any Channel,
        http1ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP1Output>,
        http2ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2Output>
    ) -> EventLoopFuture<NIONegotiatedHTTPVersion<HTTP1Output, HTTP2Output>> {
        let alpnHandler = NIOTypedApplicationProtocolNegotiationHandler<
            NIONegotiatedHTTPVersion<HTTP1Output, HTTP2Output>
        > { result in
            switch result {
            case .negotiated("h2"):
                // Successful upgrade to HTTP/2. Let the user configure the pipeline.
                return http2ConnectionInitializer(channel).map { http2Output in .http2(http2Output) }
            case .negotiated("http/1.1"), .fallback:
                // Explicit or implicit HTTP/1.1 choice.
                return http1ConnectionInitializer(channel).map { http1Output in .http1_1(http1Output) }
            case .negotiated:
                // We negotiated something that isn't HTTP/1.1. This is a bad scene, and is a good indication
                // of a user configuration error. We're going to close the connection directly.
                return channel.close().flatMap { channel.eventLoop.makeFailedFuture(NIOHTTP2Errors.invalidALPNToken()) }
            }
        }

        do {
            try self.addHandler(alpnHandler)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }

        return alpnHandler.protocolNegotiationResult
    }
}

/// `NIONegotiatedHTTPVersion` is a generic negotiation result holder for HTTP/1.1 and HTTP/2
public enum NIONegotiatedHTTPVersion<HTTP1Output: Sendable, HTTP2Output: Sendable>: Sendable {
    /// Protocol negotiation resulted in the connection using HTTP/1.1.
    case http1_1(HTTP1Output)
    /// Protocol negotiation resulted in the connection using HTTP/2.
    case http2(HTTP2Output)
}
