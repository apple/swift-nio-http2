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
/// Configuring for servers is very similar, but is left as an example for the reader.
public let NIOHTTP2SupportedALPNProtocols = ["h2", "http/1.1"]

public extension ChannelPipeline {
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
    func configureHTTP2SecureUpgrade(h2PipelineConfigurator: @escaping (ChannelPipeline) -> EventLoopFuture<Void>,
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
                return self.close().then { self.eventLoop.newFailedFuture(error: NIOHTTP2Errors.InvalidALPNToken()) }
            }
        }

        return self.add(handler: alpnHandler)
    }
}
