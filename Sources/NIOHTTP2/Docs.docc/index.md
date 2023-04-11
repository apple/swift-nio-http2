# ``NIOHTTP2``

This project contains HTTP/2 support for Swift projects using SwiftNIO.

## Overview

### Getting Started

``NIOHTTP2`` provides a number of types that make working with HTTP/2 practical using SwiftNIO. The simplest way to get started is to use the helpers provided to configure a HTTP/2 `ChannelPipeline`. As an example, to configure a HTTP/2 server, you can use `Channel.configureHTTP2Pipeline`:

```swift
channel.configureHTTP2Pipeline(mode: .server) { streamChannel -> EventLoopFuture<Void> in
    // This closure will be called once for each new HTTP/2 stream on a given connection
}
```

HTTP/2 implementations generally require a TLS handshake to negotiate, using ALPN. SwiftNIO has a number of TLS implementations available that are suitable for this purpose. As an example using [`swift-nio-ssl`](https://github.com/apple/swift-nio-ssl):

```swift
var serverConfig = TLSConfiguration.makeServerConfiguration(certificateChain: certificateChain, privateKey: sslPrivateKey)
serverConfig.applicationProtocols = NIOHTTP2SupportedALPNProtocols
// Configure the SSL context that is used by all SSL handlers.

let sslContext = try! NIOSSLContext(configuration: serverConfig)
channel.addHandler(NIOSSLServerHandler(context: sslContext).flatMap {
    channel.configureHTTP2Pipeline(mode: .server) { streamChannel -> EventLoopFuture<Void> in
        // This closure will be called once for each new HTTP/2 stream on a given connection
    }
}
```

A number of other helpers are available for configuring pipelines.

## Topics

### Core Channel Handlers

- ``NIOHTTP2Handler``
- ``HTTP2StreamMultiplexer``

### HTTP/2 and HTTP/1.1 compatibility

- ``HTTP2FramePayloadToHTTP1ClientCodec``
- ``HTTP2FramePayloadToHTTP1ServerCodec``
- ``HTTP2ToHTTP1ClientCodec``
- ``HTTP2ToHTTP1ServerCodec``

### Frames and Frame Payloads

- ``HTTP2Frame``
- ``HTTP2PingData``
- ``HTTP2StreamID``
- ``HTTP2Settings``
- ``HTTP2Setting``
- ``HTTP2SettingsParameter``
- ``HTTP2ErrorCode``

### User Inbound Events

- ``NIOHTTP2StreamCreatedEvent``
- ``NIOHTTP2WindowUpdatedEvent``
- ``NIOHTTP2BulkStreamWindowChangeEvent``
- ``StreamClosedEvent``

### Stream Channel Options

- ``HTTP2StreamChannelOptions``
- ``StreamIDOption``

### Errors

- ``NIOHTTP2Errors``
- ``NIOHTTP2Error``
- ``NIOHTTP2StreamState``

### Default Values

- ``NIOHTTP2SupportedALPNProtocols``
- ``nioDefaultSettings``
