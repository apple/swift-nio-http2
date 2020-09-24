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
import NIOTLS

/// The supported ALPN protocol tokens for NIO's HTTP/2 abstraction layer.
///
/// These can be used to configure your TLS handler appropriately such that it
/// can negotiate HTTP/2 on secure connections. For example, using swift-nio-ssl,
/// you could configure the pipeline like this:
///
///     let config = TLSConfiguration.forClient(applicationProtocols: NIOHTTP2SupportedALPNProtocols)
///     let context = try SSLContext(configuration: config)
///     channel.pipeline.add(handler: OpenSSLClientHandler(context: context, serverHostname: "example.com")).then {
///         channel.pipeline.configureHTTP2SecureUpgrade(...)
///     }
///
/// Configuring for servers is very similar, but is left as an exercise for the reader.
public let NIOHTTP2SupportedALPNProtocols = ["h2", "http/1.1"]

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
    /// - parameters:
    ///     - h2PipelineConfigurator: A callback that will be invoked if HTTP/2 has been negogiated, and that
    ///         should configure the pipeline for HTTP/2 use. Must return a future that completes when the
    ///         pipeline has been fully mutated.
    ///     - http1PipelineConfigurator: A callback that will be invoked if HTTP/1.1 has been explicitly
    ///         negotiated, or if no protocol was negotiated. Must return a future that completes when the
    ///         pipeline has been fully mutated.
    /// - returns: An `EventLoopFuture<Void>` that completes when the pipeline is ready to negotiate.
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
    /// - parameters:
    ///     - mode: The mode this pipeline will operate in, server or client.
    ///     - initialLocalSettings: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///     - position: The position in the pipeline into which to insert these handlers.
    ///     - inboundStreamStateInitializer: A closure that will be called whenever the remote peer initiates a new stream. This should almost always
    ///         be provided, especially on servers.
    /// - returns: An `EventLoopFuture` containing the `HTTP2StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
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
    /// - parameters:
    ///     - mode: The mode this pipeline will operate in, server or client.
    ///     - initialLocalSettings: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///     - position: The position in the pipeline into which to insert these handlers.
    ///     - targetWindowSize: The target size of the HTTP/2 flow control window.
    ///     - inboundStreamStateInitializer: A closure that will be called whenever the remote peer initiates a new stream. This should almost always
    ///         be provided, especially on servers.
    /// - returns: An `EventLoopFuture` containing the `HTTP2StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
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
    /// - parameters:
    ///     - mode: The mode this pipeline will operate in, server or client.
    ///     - initialLocalSettings: The settings that will be used when establishing the connection. These will be sent to the peer as part of the
    ///         handshake.
    ///     - position: The position in the pipeline into which to insert these handlers.
    ///     - targetWindowSize: The target size of the HTTP/2 flow control window.
    ///     - inboundStreamInitializer: A closure that will be called whenever the remote peer initiates a new stream. This should almost always
    ///         be provided, especially on servers.
    /// - returns: An `EventLoopFuture` containing the `HTTP2StreamMultiplexer` inserted into this pipeline, which can be used to initiate new streams.
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

    /// Configures a channel to perform a HTTP/2 secure upgrade.
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
    /// - parameters:
    ///     - h2ChannelConfigurator: A callback that will be invoked if HTTP/2 has been negogiated, and that
    ///         should configure the channel for HTTP/2 use. Must return a future that completes when the
    ///         channel has been fully mutated.
    ///     - http1ChannelConfigurator: A callback that will be invoked if HTTP/1.1 has been explicitly
    ///         negotiated, or if no protocol was negotiated. Must return a future that completes when the
    ///         channel has been fully mutated.
    /// - returns: An `EventLoopFuture<Void>` that completes when the channel is ready to negotiate.
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

    /// Configures a `ChannelPipeline` to speak either HTTP or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2. Once the protocol to use for the channel has been negotiated, the
    /// provided callback will configure the application-specific handlers in a protocol-agnostic way.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - parameters:
    ///     - h2ConnectionChannelConfigurator: An optional callback that will be invoked only
    ///         when the negotiated protocol is H2 to configure the connection channel.
    ///     - configurator: A callback that will be invoked after a protocol has been negotiated.
    ///         The callback only needs to add application-specific handlers and must return a future
    ///         that completes when the channel has been fully mutated.
    /// - returns: `EventLoopFuture<Void>` that completes when the channel is ready.
    public func configureCommonHTTPServerPipeline(
        h2ConnectionChannelConfigurator: ((Channel) -> EventLoopFuture<Void>)? = nil,
        _ configurator: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        return self.configureCommonHTTPServerPipeline(h2ConnectionChannelConfigurator: h2ConnectionChannelConfigurator, targetWindowSize: 65535, configurator)
    }
    
    /// Configures a `ChannelPipeline` to speak either HTTP or HTTP/2 according to what can be negotiated with the client.
    ///
    /// This helper takes care of configuring the server pipeline such that it negotiates whether to
    /// use HTTP/1.1 or HTTP/2. Once the protocol to use for the channel has been negotiated, the
    /// provided callback will configure the application-specific handlers in a protocol-agnostic way.
    ///
    /// This function doesn't configure the TLS handler. Callers of this function need to add a TLS
    /// handler appropriately configured to perform protocol negotiation.
    ///
    /// - parameters:
    ///     - h2ConnectionChannelConfigurator: An optional callback that will be invoked only
    ///         when the negotiated protocol is H2 to configure the connection channel.
    ///     - targetWindowSize: The target size of the HTTP/2 flow control window.
    ///     - configurator: A callback that will be invoked after a protocol has been negotiated.
    ///         The callback only needs to add application-specific handlers and must return a future
    ///         that completes when the channel has been fully mutated.
    /// - returns: `EventLoopFuture<Void>` that completes when the channel is ready.
    public func configureCommonHTTPServerPipeline(
        h2ConnectionChannelConfigurator: ((Channel) -> EventLoopFuture<Void>)? = nil,
        targetWindowSize: Int,
        _ configurator: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        let h2ChannelConfigurator = { (channel: Channel) -> EventLoopFuture<Void> in
            channel.configureHTTP2Pipeline(mode: .server, targetWindowSize: targetWindowSize) { streamChannel -> EventLoopFuture<Void> in
                streamChannel.pipeline.addHandler(HTTP2FramePayloadToHTTP1ServerCodec()).flatMap { () -> EventLoopFuture<Void> in
                    configurator(streamChannel)
                }
            }.flatMap { (_: HTTP2StreamMultiplexer) in
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
