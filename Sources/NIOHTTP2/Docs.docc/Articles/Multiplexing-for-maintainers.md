# Multiplexing for maintainers

The term "multiplexer" appears in many types across ``NIOHTTP2``. This article
explains the different ways stream multiplexing is achieved and how the pieces
fit together.

The intended audience is _library maintainers_ although users may find it
helpful too. It is not meant to be a comprehensive guide and assumes you have at
least a high-level understanding of how the library is structured.

There are two high-level approaches to multiplexing in ``NIOHTTP2``:

1. _Legacy_ multiplexing is implemented as a separate `ChannelHandler`.
2. _Inline_ multiplexing is implemented within the ``NIOHTTP2Handler``.

## Legacy

The _legacy_ multiplexer is a separate `ChannelHandler` which maintains the set
of open child channels keyed by their stream ID. It is implemented as the
``HTTP2StreamMultiplexer``. The handler receives frames and various channel
events from the ``NIOHTTP2Handler`` which are acted upon or propagated to the
appropriate child channel or forwarded down the connection channel. This
approach makes heavy use of user-inbound events to pass additional information
between the ``NIOHTTP2Handler`` and the ``HTTP2StreamMultiplexer``.

The child channels are wrapped up as `MultiplexerAbstractChannel`s: this is a
wrapper around an `HTTP2StreamChannel` operating in one of two possible modes.
The modes correspond to the type of data passed between the connection channel
and the stream channels:

1. ``HTTP2Frame/FramePayload``
2. ``HTTP2Frame``. All paths leading to this mode of operation are deprecated,
   see [Issue 214](https://github.com/apple/swift-nio-http2/issues/214) for more
   context.

## Inline

`_Inline_` multiplexing is the newer way of multiplexing streams and is
implemented inline in the ``NIOHTTP2Handler``. It was created to reduce the cost
of multiplexing incurred by the legacy multiplexer by removing the out-of-band
passing of information as user-inbound events. Like the legacy multiplexer, it
maintains a set of open stream channels and propagates events to them directly.
This is implemented as the `NIOHTTP2Handler.InlineStreamMultiplexer`.

## How they fit together

Both methods are supported which goes some of the way to explaining why there
are so many types with the word "multiplexer" in their name.

The ``NIOHTTP2Handler`` makes it possible to use either approach by abstracting
them away behind the `HTTP2StreamMultiplexer` protocol. The two implementations
(`LegacyInboundStreamMultiplexer` and `InlineStreamMultiplexer`) are wrapped up
in an `enum` called `HTTP2InboundStreamMultiplexer` held by the
``NIOHTTP2Handler``.

The `LegacyInboundStreamMultiplexer` just forwards events down the channel
pipeline to the ``HTTP2StreamMultiplexer`` `ChannelHandler` which in turn calls
into the `HTTP2CommonInboundStreamMultiplexer`.

The `NIOHTTP2Handler.InboundStreamMultiplexer` calls the
`HTTP2CommonInboundStreamMultiplexer` directly.

The ``NIOHTTP2Handler`` propagates events to `HTTP2InboundStreamMultiplexer` but
_also_ forwards events down the channel pipeline. Because of this, and to avoid
events being delivered twice, some events on the
`LegacyInboundStreamMultiplexer` are no-ops.

## The relevant pieces, briefly(-ish)

- **``NIOHTTP2Handler``**: a `public` `ChannelHandler` which decodes bytes to
  ``HTTP2Frame``s (and vice versa). When operating in the 'inline' mode outbound
  streams can be _created_ (via ``NIOHTTP2Handler/StreamMultiplexer``). Inbound
  streams are demultiplexed via the `NIOHTTP2Handler.InboundStreamMultiplexer`.
- **`HTTP2InboundStreamMultiplexer`**: an `internal` `protocol` which
  demuiltiplexes various inbound events (receiving frames, errors, etc.) into
  streams.
- **`NIOHTTP2Handler.InboundStreamMultiplexer`**: an `internal` `enum` with two
  cases conforming to `HTTP2InboundStreamMultiplexer`. The `NIOHTTP2Handler`
  holds an instance of this internally.
- **``NIOHTTP2Handler/StreamMultiplexer``**: a `public` `struct` which wraps
  `HTTP2InboundStreamMultiplexer` to provide API for creating outbound streams.
- **``HTTP2StreamMultiplexer``**: a `public` `ChannelHandler` used for _legacy_
  multiplexing. which also allows you to _create_ outbound streams. Most of its
  internals call through to the `HTTP2CommonInboundStreamMultiplexer`.
- **`LegacyInboundStreamMultiplexer`**: an `internal` `struct` which conforms to
  `HTTP2InboundStreamMultiplexer` and forwards various events down the channel
  pipeline (to the `HTTP2StreamMultiplexer` handler). One of the two cases of
  the `NIOHTTP2Handler.InboundStreamMultiplexer`.
- **`HTTP2CommonInboundStreamMultiplexer`**: an `internal` `struct` which
  actually holds the set of open streams keyed by their ID and is responsible
  for propagating events to them.
- **`InlineStreamMultiplexer`**: an `internal` `struct` which conforms to
  `HTTP2InboundStreamMultiplexer` and forwards events directly to the
  `HTTP2CommonInboundStreamMultiplexer`. The second case of the
  `NIOHTTP2Handler.InboundStreamMultiplexer`.
- **`MultiplexerAbstractChannel`**: an `internal` `enum` with two cases which
  wraps an `HTTP2StreamChannel`. The two cases correspond to the type of data
  passed into the stream (``HTTP2Frame`` vs. ``HTTP2Frame/FramePayload``).
