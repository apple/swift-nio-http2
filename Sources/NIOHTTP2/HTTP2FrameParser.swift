//
//  HTTP2NativeParser.swift
//  NIOHTTP2
//
//  Created by Jim Dovey on 11/14/18.
//

import NIO
import NIOHPACK

/// HTTP/2 Connection Preface
///
/// In HTTP/2, each endpoint is required to send a connection preface as a final confirmation of the protocol in
/// use and to establish the initial settings for the HTTP/2 connection. The client and server each send a different
/// connection preface.
///
/// The client connection preface starts with a sequence of 24 octets, which in hex notation is:
///
/// ```
/// 0x505249202a20485454502f322e300d0a0d0a534d0d0a0d0a
/// ```
///
/// That is, the connection preface starts with the string PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n). This sequence MUST be
/// followed by a SETTINGS frame (Section 6.5), which MAY be empty. The client sends the client connection preface
/// immediately upon receipt of a 101 (Switching Protocols) response (indicating a successful upgrade) or as the first
/// application data octets of a TLS connection. If starting an HTTP/2 connection with prior knowledge of server
/// support for the protocol, the client connection preface is sent upon connection establishment.
fileprivate let HTTP2ConnectionPreface: StaticString = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

private extension HPACKHeaders {
    /// Whether this `HTTPHeaders` corresponds to a final response or not.
    ///
    /// This property is only valid if called on a response header block. If the :status header
    /// is not present, this will crash.
    var isInformationalResponse: Bool {
        return self.first { $0.name == ":status" }!.value.first == "1"
    }
}

/// A state machine that keeps track of the header blocks sent or received and that determines the type of any
/// new header block.
struct NIOHTTP2HeadersStateMachine {
    /// The list of possible header frame types.
    ///
    /// This is used in combination with introspection of the HTTP header blocks to determine what HTTP header block
    /// a certain HTTP header is.
    enum HeaderType {
        /// A request header block.
        case requestHead
        
        /// An informational response header block. These can be sent zero or more times.
        case informationalResponseHead
        
        /// A final response header block.
        case finalResponseHead
        
        /// A trailer block. Once this is sent no further header blocks are acceptable.
        case trailer
    }
    
    /// The previous header block.
    private var previousHeader: HeaderType?
    
    /// The mode of this connection: client or server.
    private let mode: HTTP2NativeParser.ParserMode
    
    init(mode: HTTP2NativeParser.ParserMode) {
        self.mode = mode
    }
    
    /// Called when about to process a HTTP headers block to determine its type.
    mutating func newHeaders(block: HPACKHeaders) -> HeaderType {
        let newType: HeaderType
        
        switch (self.mode, self.previousHeader) {
        case (.client, .none):
            // The first header block on a client mode stream must be a request block.
            newType = .requestHead
        case (.server, .none),
             (.server, .some(.informationalResponseHead)):
            // The first header block on a server mode stream may be either informational or final,
            // depending on the value of the :status pseudo-header. Alternatively, if the previous
            // header block was informational, the same possibilities apply.
            newType = block.isInformationalResponse ? .informationalResponseHead : .finalResponseHead
        case (.client, .some(.requestHead)),
             (.server, .some(.finalResponseHead)):
            // If the client has already sent a request head, or the server has already sent a final response,
            // this is a trailer block.
            newType = .trailer
        case (.client, .some(.informationalResponseHead)),
             (.client, .some(.finalResponseHead)),
             (.server, .some(.requestHead)):
            // These states should not be reachable!
            preconditionFailure("Invalid internal state!")
        case (.client, .some(.trailer)),
             (.server, .some(.trailer)):
            // TODO(cory): This should probably throw, as this can happen in malformed programs without the world ending.
            preconditionFailure("Sending too many header blocks.")
        }
        
        self.previousHeader = newType
        return newType
    }
}

// TODO: Move this to another file when we branch this out
final class NIOHTTP2Stream {
    /// The stream ID for this stream.
    let streamID: HTTP2StreamID
    
    /// Whether this stream is still active on the connection. Streams that are not active on the connection are
    /// safe to prune.
    var active: Bool = false
    
    /// The headers state machine for outbound headers.
    ///
    /// Currently we do not maintain one of these for inbound headers because nghttp2 doesn't require it of us, but
    /// in the future we may want to do so.
    private var outboundHeaderStateMachine: NIOHTTP2HeadersStateMachine
    
    let allocator: ByteBufferAllocator
    var encoder: HPACKEncoder
    var decoder: HPACKDecoder
    
    init(allocator: ByteBufferAllocator, mode: HTTP2NativeParser.ParserMode, streamID: HTTP2StreamID) {
        self.outboundHeaderStateMachine = NIOHTTP2HeadersStateMachine(mode: mode)
        self.streamID = streamID
        self.encoder = HPACKEncoder(allocator: allocator)
        self.decoder = HPACKDecoder(allocator: allocator)
        self.allocator = allocator
    }
    
    /// Called to determine the type of a new outbound header block, so as to manage it appropriately.
    func newOutboundHeaderBlock(block: HPACKHeaders) throws -> (NIOHTTP2HeadersStateMachine.HeaderType, ByteBuffer) {
        precondition(self.active)
        let type = self.outboundHeaderStateMachine.newHeaders(block: block)
        
        try self.encoder.beginEncoding(allocator: self.allocator)
        try self.encoder.append(headers: block)
        let buf = try self.encoder.endEncoding()
        
        return (type, buf)
    }
}

/// Parses HTTP/2 data from the
public class HTTP2NativeParser : ChannelInboundHandler, ChannelOutboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTP2Frame
    public typealias OutboundOut = IOData
    public typealias OutboundIn = HTTP2Frame
    
    /// The mode in which this parser operates.
    public enum ParserMode {
        /// Client mode.
        case client
        
        /// Server mode.
        case server
    }
    
    private enum ParserState {
        case inactive
        case idle
        case accumulatingFrame
        case coalescingHeaders(HPACKHeaders)
        case accumulatingData(ByteBuffer)
    }
    
    private let mode: ParserMode
    private let initialSettings: [HTTP2Setting]
    private let maxCachedClosedStreams: Int
    
    private var state: ParserState = .inactive
    private var parseBuffer: ByteBuffer!
    private var scratchBuffer: ByteBuffer!
    
    /// Create a `HTTP2NativeParser`.
    ///
    /// - parameters:
    ///     - mode: The mode for the parser to operate in: server or client.
    ///     - initialSettings: The initial settings used for the connection, to be sent in the
    ///         connection preamble.
    ///     - maxCachedClosedStreams: The maximum number of streams for which metadata will be preserved
    ///         to handle delayed frames (e.g. DATA frames that were already in flight after stream reset
    ///         or GOAWAY).
    public init(mode: ParserMode, initialSettings: [HTTP2Setting] = nioDefaultSettings, maxCachedClosedStreams: Int = 1024) {
        self.mode = mode
        self.initialSettings = initialSettings
        self.maxCachedClosedStreams = maxCachedClosedStreams
    }
    
    public func channelActive(ctx: ChannelHandlerContext) {
        self.parseBuffer = ctx.channel.allocator.buffer(capacity: 1024 * 16)
        self.scratchBuffer = ctx.channel.allocator.buffer(capacity: 1024)
        self.state = .idle
        self.flushPreamble(ctx: ctx)
        ctx.fireChannelActive()
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) {
        // do what?
    }
    
    private func flushPreamble(ctx: ChannelHandlerContext) {
        let frame = HTTP2Frame(streamID: .rootStream, payload: .settings(initialSettings))
        scratchBuffer.clear()
        scratchBuffer.write(staticString: HTTP2ConnectionPreface)
        self.encode(frame: frame, to: &scratchBuffer)
        
    }
    
    private func encode(frame: HTTP2Frame, to buf: inout ByteBuffer) {
        // note our starting point
        let start = buf.writerIndex
        
//      +-----------------------------------------------+
//      |                 Length (24)                   |
//      +---------------+---------------+---------------+
//      |   Type (8)    |   Flags (8)   |
//      +-+-------------+---------------+-------------------------------+
//      |R|                 Stream Identifier (31)                      |
//      +=+=============================================================+
//      |                   Frame Payload (0...)                      ...
//      +---------------------------------------------------------------+
        
        // skip 24-bit length for now, we'll fill that in later
        buf.moveWriterIndex(forwardBy: 3)
        
        // 8-bit type
        buf.write(integer: frame.payload.code)
        // 8-bit flags
        buf.write(integer: frame.flags.rawValue)
        // 32-bit stream identifier -- ensuring the top bit is empty
        buf.write(integer: frame.streamID.safeNetworkStreamID ?? 0)
        
        func writePayloadSize(_ size: Int) {
            var bytes: (UInt8, UInt8, UInt8)
            bytes.0 = UInt8((size & 0xff_00_00) >> 16)
            bytes.1 = UInt8((size & 0x00_ff_00) >>  8)
            bytes.2 = UInt8( size & 0x00_00_ff)
            withUnsafeBytes(of: bytes) { ptr in
                _ = buf.set(bytes: ptr, at: start)
            }
        }
        
        // frame payload follows, which depends on the frame type itself
        switch frame.payload {
        case .data(let data):
            // we push the data in a separate write to the channel
            writePayloadSize(data.readableBytes)
        case .headers(let headers):
            // HPACK-encoded data. Find the stream and its associated encoder/decoder
            
        }
    }
}
