//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP2

final class ServerOnly10KRequestsBenchmark: Benchmark {
    private let concurrentStreams: Int

    var channel: EmbeddedChannel?

    // This offset is preserved across runs.
    var streamID = HTTP2StreamID(1)

    // A manually constructed data frame.
    private var dataFrame: ByteBuffer = {
        var buffer = ByteBuffer(repeating: 0xff, count: 1024 + 9)

        // UInt24 length, is 1024 bytes.
        buffer.setInteger(UInt8(0), at: buffer.readerIndex)
        buffer.setInteger(UInt16(1024), at: buffer.readerIndex + 1)

        // Type
        buffer.setInteger(UInt8(0x00), at: buffer.readerIndex + 3)

        // Flags, turn on end-stream.
        buffer.setInteger(UInt8(0x01), at: buffer.readerIndex + 4)

        // 4 byte stream identifier, set to zero for now as we update it later.
        buffer.setInteger(UInt32(0), at: buffer.readerIndex + 5)

        return buffer
    }()

    // A manually constructed headers frame.
    private var headersFrame: ByteBuffer = {
        var headers = HPACKHeaders()
        headers.add(name: ":method", value: "GET", indexing: .indexable)
        headers.add(name: ":authority", value: "localhost", indexing: .nonIndexable)
        headers.add(name: ":path", value: "/", indexing: .indexable)
        headers.add(name: ":scheme", value: "https", indexing: .indexable)
        headers.add(
            name: "user-agent",
            value:
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.169 Safari/537.36",
            indexing: .nonIndexable
        )
        headers.add(name: "accept-encoding", value: "gzip, deflate", indexing: .indexable)

        var hpackEncoder = HPACKEncoder(allocator: .init())
        var buffer = ByteBuffer()
        buffer.writeRepeatingByte(0, count: 9)
        buffer.moveReaderIndex(forwardBy: 9)
        try! hpackEncoder.encode(headers: headers, to: &buffer)
        let encodedLength = buffer.readableBytes
        buffer.moveReaderIndex(to: buffer.readerIndex - 9)

        // UInt24 length
        buffer.setInteger(UInt8(0), at: buffer.readerIndex)
        buffer.setInteger(UInt16(encodedLength), at: buffer.readerIndex + 1)

        // Type
        buffer.setInteger(UInt8(0x01), at: buffer.readerIndex + 3)

        // Flags, turn on END_HEADERs.
        buffer.setInteger(UInt8(0x04), at: buffer.readerIndex + 4)

        // 4 byte stream identifier, set to zero for now as we update it later.
        buffer.setInteger(UInt32(0), at: buffer.readerIndex + 5)

        return buffer
    }()

    private let emptySettings: ByteBuffer = {
        var buffer = ByteBuffer()
        buffer.reserveCapacity(9)

        // UInt24 length, is 0 bytes.
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(0))

        // Type
        buffer.writeInteger(UInt8(0x04))

        // Flags, none.
        buffer.writeInteger(UInt8(0x00))

        // 4 byte stream identifier, set to zero.
        buffer.writeInteger(UInt32(0))

        return buffer
    }()

    private var settingsACK: ByteBuffer {
        // Copy the empty SETTINGS and add the ACK flag
        var settingsCopy = self.emptySettings
        settingsCopy.setInteger(UInt8(0x01), at: settingsCopy.readerIndex + 4)
        return settingsCopy
    }

    init(concurrentStreams: Int) {
        self.concurrentStreams = concurrentStreams
    }

    func setUp() throws {
        let channel = EmbeddedChannel()

        try channel.configureHTTP2Pipeline(mode: .server) { streamChannel -> EventLoopFuture<Void> in
            streamChannel.eventLoop.makeCompletedFuture {
                try streamChannel.pipeline.syncOperations.addHandler(TestServer())
            }
        }.map { _ in }.wait()

        try channel.connect(to: .init(unixDomainSocketPath: "/fake"), promise: nil)

        // Gotta do the handshake here.
        var initialBytes = ByteBuffer(string: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        initialBytes.writeImmutableBuffer(self.emptySettings)
        initialBytes.writeImmutableBuffer(self.settingsACK)

        try channel.writeInbound(initialBytes)
        while try channel.readOutbound(as: ByteBuffer.self) != nil {}

        self.channel = channel
    }

    func tearDown() {
        _ = try! self.channel!.finish()
        self.channel = nil
    }

    func run() throws -> Int {
        var bodyByteCount = 0
        var completedIterations = 0
        while completedIterations < 10_000 {
            bodyByteCount &+= try self.sendInterleavedRequests(self.concurrentStreams)
            completedIterations += self.concurrentStreams
        }
        return bodyByteCount
    }

    private func sendInterleavedRequests(_ interleavedRequests: Int) throws -> Int {
        var streamID = self.streamID

        for _ in 0..<interleavedRequests {
            self.headersFrame.setInteger(UInt32(Int32(streamID)), at: self.headersFrame.readerIndex + 5)
            try self.channel!.writeInbound(self.headersFrame)
            streamID = streamID.advanced(by: 2)
        }

        streamID = self.streamID

        for _ in 0..<interleavedRequests {
            self.dataFrame.setInteger(UInt32(Int32(streamID)), at: self.dataFrame.readerIndex + 5)
            try self.channel!.writeInbound(self.dataFrame)
            streamID = streamID.advanced(by: 2)
        }

        self.channel!.embeddedEventLoop.run()

        self.streamID = streamID

        var count = 0
        while let data = try self.channel!.readOutbound(as: ByteBuffer.self) {
            count &+= data.readableBytes
            self.channel!.embeddedEventLoop.run()
        }
        return count
    }
}

private class TestServer: ChannelInboundHandler {
    public typealias InboundIn = HTTP2Frame.FramePayload
    public typealias OutboundOut = HTTP2Frame.FramePayload

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = self.unwrapInboundIn(data)

        switch payload {
        case .headers(let headers) where headers.endStream:
            self.sendResponse(context: context)
        case .data(let data) where data.endStream:
            self.sendResponse(context: context)
        default:
            ()
        }
    }

    private func sendResponse(context: ChannelHandlerContext) {
        let responseHeaders = HPACKHeaders([(":status", "200"), ("server", "test-benchmark")])
        let response = HTTP2Frame.FramePayload.headers(.init(headers: responseHeaders, endStream: false))
        let responseData = HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer()), endStream: true))
        context.write(self.wrapOutboundOut(response), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(responseData), promise: nil)
    }
}
