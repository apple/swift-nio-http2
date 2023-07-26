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

@_spi(AsyncChannel) import NIOCore
@_spi(AsyncChannel) import NIOTLS

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

#if swift(>=5.7)
/// The type of NIO Channel initializer callbacks which do not need to return data.
public typealias NIOChannelInitializer = @Sendable (Channel) -> EventLoopFuture<Void>
/// The type of NIO Channel initializer callbacks which need to return data.
public typealias NIOChannelInitializerWithOutput<Output> = @Sendable (Channel) -> EventLoopFuture<Output>
#else
/// The type of NIO Channel initializer callbacks which do not need to return data.
public typealias NIOChannelInitializer = (Channel) -> EventLoopFuture<Void>
/// The type of NIO Channel initializer callbacks which need to return data.
public typealias NIOChannelInitializerWithOutput<Output> = (Channel) -> EventLoopFuture<Output>
#endif

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
    @available(*, deprecated, renamed: "Channel.configureHTTP2SecureUpgrade(h2ChannelConfigurator:http1ChannelConfigurator:)")
    public func configureHTTP2SecureUpgrade(h2PipelineConfigurator: @escaping (ChannelPipeline) -> EventLoopFuture<Void>,
                                            http1PipelineConfigurator: @escaping (ChannelPipeline) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        let alpnHandler = ApplicationProtocolNegotiationHandler { result in
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

        return self.addHandler(alpnHandler)
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
    @available(*, deprecated, renamed: "configureHTTP2Pipeline(mode:initialLocalSettings:position:targetWindowSize:inboundStreamInitializer:)")
    public func configureHTTP2Pipeline(mode: NIOHTTP2Handler.ParserMode,
                                       initialLocalSettings: [HTTP2Setting] = nioDefaultSettings,
                                       position: ChannelPipeline.Position = .last,
                                       inboundStreamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)? = nil) -> EventLoopFuture<HTTP2StreamMultiplexer> {
        return self.configureHTTP2Pipeline(mode: mode, initialLocalSettings: initialLocalSettings, position: position, targetWindowSize: 65535, inboundStreamStateInitializer: inboundStreamStateInitializer)
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
    @available(*, deprecated, renamed: "configureHTTP2Pipeline(mode:initialLocalSettings:position:targetWindowSize:inboundStreamInitializer:)")
    public func configureHTTP2Pipeline(mode: NIOHTTP2Handler.ParserMode,
                                       initialLocalSettings: [HTTP2Setting] = nioDefaultSettings,
                                       position: ChannelPipeline.Position = .last,
                                       targetWindowSize: Int,
                                       inboundStreamStateInitializer: ((Channel, HTTP2StreamID) -> EventLoopFuture<Void>)? = nil) -> EventLoopFuture<HTTP2StreamMultiplexer> {
        var handlers = [ChannelHandler]()
        handlers.reserveCapacity(2)  // Update this if we need to add more handlers, to avoid unnecessary reallocation.
        handlers.append(NIOHTTP2Handler(mode: mode, initialSettings: initialLocalSettings))
        let multiplexer = HTTP2StreamMultiplexer(mode: mode, channel: self, targetWindowSize: targetWindowSize, inboundStreamStateInitializer: inboundStreamStateInitializer)
        handlers.append(multiplexer)

        return self.pipeline.addHandlers(handlers, position: position).map { multiplexer }
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
    public func configureHTTP2Pipeline(mode: NIOHTTP2Handler.ParserMode,
                                       initialLocalSettings: [HTTP2Setting] = nioDefaultSettings,
                                       position: ChannelPipeline.Position = .last,
                                       targetWindowSize: Int = 65535,
                                       inboundStreamInitializer: ((Channel) -> EventLoopFuture<Void>)?) -> EventLoopFuture<HTTP2StreamMultiplexer> {
        var handlers = [ChannelHandler]()
        handlers.reserveCapacity(2)  // Update this if we need to add more handlers, to avoid unnecessary reallocation.
        handlers.append(NIOHTTP2Handler(mode: mode, initialSettings: initialLocalSettings))
        let multiplexer = HTTP2StreamMultiplexer(mode: mode, channel: self, targetWindowSize: targetWindowSize, inboundStreamInitializer: inboundStreamInitializer)
        handlers.append(multiplexer)

        return self.pipeline.addHandlers(handlers, position: position).map { multiplexer }
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
    public func configureHTTP2Pipeline(mode: NIOHTTP2Handler.ParserMode,
                                       connectionConfiguration: NIOHTTP2Handler.ConnectionConfiguration,
                                       streamConfiguration: NIOHTTP2Handler.StreamConfiguration,
                                       streamDelegate: NIOHTTP2StreamDelegate? = nil,
                                       position: ChannelPipeline.Position = .last,
                                       inboundStreamInitializer: @escaping NIOChannelInitializer) -> EventLoopFuture<NIOHTTP2Handler.StreamMultiplexer> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture {
                return try self.pipeline.syncOperations.configureHTTP2Pipeline(
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
                return try self.pipeline.syncOperations.configureHTTP2Pipeline(
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
    public func configureHTTP2SecureUpgrade(h2ChannelConfigurator: @escaping (Channel) -> EventLoopFuture<Void>,
                                            http1ChannelConfigurator: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        let alpnHandler = ApplicationProtocolNegotiationHandler { result in
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

        return self.pipeline.addHandler(alpnHandler)
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
        h2ConnectionChannelConfigurator: ((Channel) -> EventLoopFuture<Void>)? = nil,
        _ configurator: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        return self.configureCommonHTTPServerPipeline(h2ConnectionChannelConfigurator: h2ConnectionChannelConfigurator, targetWindowSize: 65535, configurator)
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
        h2ConnectionChannelConfigurator: ((Channel) -> EventLoopFuture<Void>)? = nil,
        targetWindowSize: Int,
        _ configurator: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        return self._commonHTTPServerPipeline(configurator: configurator, h2ConnectionChannelConfigurator: h2ConnectionChannelConfigurator) { channel in
            channel.configureHTTP2Pipeline(mode: .server, targetWindowSize: targetWindowSize) { streamChannel -> EventLoopFuture<Void> in
                streamChannel.pipeline.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()).flatMap { () -> EventLoopFuture<Void> in
                    configurator(streamChannel)
                }
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
        h2ConnectionChannelConfigurator: ((Channel) -> EventLoopFuture<Void>)? = nil,
        configurator: @escaping NIOChannelInitializer
    ) -> EventLoopFuture<Void> {
        return self._commonHTTPServerPipeline(configurator: configurator, h2ConnectionChannelConfigurator: h2ConnectionChannelConfigurator) { channel in
            channel.configureHTTP2Pipeline(
                mode: .server,
                connectionConfiguration: connectionConfiguration,
                streamConfiguration: streamConfiguration,
                streamDelegate: streamDelegate
            ) { streamChannel -> EventLoopFuture<Void> in
                streamChannel.pipeline.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()).flatMap { () -> EventLoopFuture<Void> in
                    configurator(streamChannel)
                }
            }.map { _ in () }
        }
    }

    private func _commonHTTPServerPipeline(
        configurator: @escaping (Channel) -> EventLoopFuture<Void>,
        h2ConnectionChannelConfigurator: ((Channel) -> EventLoopFuture<Void>)?,
        configureHTTP2Pipeline: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let h2ChannelConfigurator = { (channel: Channel) -> EventLoopFuture<Void> in
            configureHTTP2Pipeline(channel).flatMap { _ in
                if let h2ConnectionChannelConfigurator = h2ConnectionChannelConfigurator {
                    return h2ConnectionChannelConfigurator(channel)
                } else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
            }
        }
        let http1ChannelConfigurator = { (channel: Channel) -> EventLoopFuture<Void> in
            channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
                configurator(channel)
            }
        }
        return self.configureHTTP2SecureUpgrade(h2ChannelConfigurator: h2ChannelConfigurator,
                                                http1ChannelConfigurator: http1ChannelConfigurator)
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
    public func configureHTTP2Pipeline(mode: NIOHTTP2Handler.ParserMode,
                                       connectionConfiguration: NIOHTTP2Handler.ConnectionConfiguration,
                                       streamConfiguration: NIOHTTP2Handler.StreamConfiguration,
                                       streamDelegate: NIOHTTP2StreamDelegate? = nil,
                                       position: ChannelPipeline.Position = .last,
                                       inboundStreamInitializer: @escaping NIOChannelInitializer) throws -> NIOHTTP2Handler.StreamMultiplexer {
        let handler = NIOHTTP2Handler(
            mode: mode,
            eventLoop: self.eventLoop,
            connectionConfiguration: connectionConfiguration,
            streamConfiguration: streamConfiguration,
            streamDelegate: streamDelegate,
            inboundStreamInitializer: inboundStreamInitializer
        )

        try self.addHandler(handler, position: position)

        // `multiplexer` will always be non-nil when we are initializing with an `inboundStreamInitializer`
        return try handler.syncMultiplexer()
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
    ///   - position: The position in the pipeline into which to insert this handler.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    ///     be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    @_spi(AsyncChannel)
    public func configureAsyncHTTP2Pipeline<Output>(
        mode: NIOHTTP2Handler.ParserMode,
        configuration: NIOHTTP2Handler.Configuration = .init(),
        position: ChannelPipeline.Position = .last,
        inboundStreamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) -> EventLoopFuture<NIOHTTP2Handler.AsyncStreamMultiplexer<Output>> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture {
                return try self.pipeline.syncOperations.configureAsyncHTTP2Pipeline(
                    mode: mode,
                    configuration: configuration,
                    position: position,
                    inboundStreamInitializer: inboundStreamInitializer
                )
            }
        } else {
            return self.eventLoop.submit {
                return try self.pipeline.syncOperations.configureAsyncHTTP2Pipeline(
                    mode: mode,
                    configuration: configuration,
                    position: position,
                    inboundStreamInitializer: inboundStreamInitializer
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
    internal func configureHTTP2AsyncSecureUpgrade<HTTP1Output, HTTP2Output>(
        http1ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP1Output>,
        http2ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2Output>
    ) -> EventLoopFuture<EventLoopFuture<NIOProtocolNegotiationResult<NIONegotiatedHTTPVersion<HTTP1Output, HTTP2Output>>>> {
        let alpnHandler = NIOTypedApplicationProtocolNegotiationHandler<NIONegotiatedHTTPVersion<HTTP1Output, HTTP2Output>>(eventLoop: self.eventLoop) { result in
            switch result {
            case .negotiated("h2"):
                // Successful upgrade to HTTP/2. Let the user configure the pipeline.
                return http2ConnectionInitializer(self).map { http2Output in .init(result: .http2(http2Output)) }
            case .negotiated("http/1.1"), .fallback:
                // Explicit or implicit HTTP/1.1 choice.
                return http1ConnectionInitializer(self).map { http1Output in .init(result: .http1_1(http1Output)) }
            case .negotiated:
                // We negotiated something that isn't HTTP/1.1. This is a bad scene, and is a good indication
                // of a user configuration error. We're going to close the connection directly.
                return self.close().flatMap { self.eventLoop.makeFailedFuture(NIOHTTP2Errors.invalidALPNToken()) }
            }
        }

        return self.pipeline
            .addHandler(alpnHandler)
            .map { _ in
                alpnHandler.protocolNegotiationResult
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
    ///     is HTTP/2 to configure the connection channel.
    ///   - http2InboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    /// - Returns: An `EventLoopFuture` containing a ``NIOTypedApplicationProtocolNegotiationHandler`` that completes when the channel
    ///     is ready to negotiate. This can then be used to access the ``NIOProtocolNegotiationResult`` which may itself
    ///     be waited on to retrieve the result of the negotiation.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    @_spi(AsyncChannel)
    public func configureAsyncHTTPServerPipeline<HTTP1ConnectionOutput, HTTP2ConnectionOutput, HTTP2StreamOutput>(
        http2Configuration: NIOHTTP2Handler.Configuration = .init(),
        http1ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP1ConnectionOutput>,
        http2ConnectionInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2ConnectionOutput>,
        http2InboundStreamInitializer: @escaping NIOChannelInitializerWithOutput<HTTP2StreamOutput>
    ) -> EventLoopFuture<EventLoopFuture<NIOProtocolNegotiationResult<NIONegotiatedHTTPVersion<
            HTTP1ConnectionOutput,
            (HTTP2ConnectionOutput, NIOHTTP2Handler.AsyncStreamMultiplexer<HTTP2StreamOutput>)
        >>>> {
        let http2ConnectionInitializer: NIOChannelInitializerWithOutput<(HTTP2ConnectionOutput, NIOHTTP2Handler.AsyncStreamMultiplexer<HTTP2StreamOutput>)> = { channel in
            channel.configureAsyncHTTP2Pipeline(
                mode: .server,
                configuration: http2Configuration,
                inboundStreamInitializer: http2InboundStreamInitializer
            ).flatMap { multiplexer in
                return http2ConnectionInitializer(channel).map { connectionChannel in
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
    ///   - position: The position in the pipeline into which to insert this handler.
    ///   - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream.
    /// - Returns: An `EventLoopFuture` containing the `AsyncStreamMultiplexer` inserted into this pipeline, which can
    /// be used to initiate new streams and iterate over inbound HTTP/2 stream channels.
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    @_spi(AsyncChannel)
    public func configureAsyncHTTP2Pipeline<Output>(
        mode: NIOHTTP2Handler.ParserMode,
        configuration: NIOHTTP2Handler.Configuration = .init(),
        position: ChannelPipeline.Position = .last,
        inboundStreamInitializer: @escaping NIOChannelInitializerWithOutput<Output>
    ) throws -> NIOHTTP2Handler.AsyncStreamMultiplexer<Output> {
        let handler = NIOHTTP2Handler(
            mode: mode,
            eventLoop: self.eventLoop,
            connectionConfiguration: configuration.connection,
            streamConfiguration: configuration.stream,
            inboundStreamInitializer: { channel in channel.eventLoop.makeSucceededVoidFuture() }
        )

        try self.addHandler(handler, position: position)

        let (continuation, inboundStreamChannels) = StreamChannelContinuation.initialize(with: inboundStreamInitializer)

        return try handler.syncAsyncStreamMultiplexer(continuation: continuation, inboundStreamChannels: inboundStreamChannels)
    }
}

/// `NIONegotiatedHTTPVersion` is a generic negotiation result holder for HTTP/1.1 and HTTP/2
@_spi(AsyncChannel)
public enum NIONegotiatedHTTPVersion<HTTP1Output: Sendable, HTTP2Output: Sendable> {
    case http1_1(HTTP1Output)
    case http2(HTTP2Output)
}
