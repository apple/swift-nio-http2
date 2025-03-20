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

final class StreamTeardownBenchmark: Benchmark {
    private let concurrentStreams: Int

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

    func setUp() {}

    func tearDown() {}

    func createChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()

        try channel.configureHTTP2Pipeline(mode: .server) { streamChannel -> EventLoopFuture<Void> in
            streamChannel.eventLoop.makeCompletedFuture {
                try streamChannel.pipeline.syncOperations.addHandler(DoNothingServer())
            }
        }.map { _ in }.wait()
        try channel.pipeline.syncOperations.addHandler(SendGoawayHandler(expectedStreams: self.concurrentStreams))

        try channel.connect(to: .init(unixDomainSocketPath: "/fake"), promise: nil)

        // Gotta do the handshake here.
        var initialBytes = ByteBuffer(string: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
        initialBytes.writeImmutableBuffer(self.emptySettings)
        initialBytes.writeImmutableBuffer(self.settingsACK)

        try channel.writeInbound(initialBytes)
        while try channel.readOutbound(as: ByteBuffer.self) != nil {}

        return channel
    }

    func destroyChannel(_ channel: EmbeddedChannel) throws {
        _ = try channel.finish()
    }

    func run() throws -> Int {
        var bodyByteCount = 0
        var completedIterations = 0
        while completedIterations < 10_000 {
            let channel = try self.createChannel()
            bodyByteCount &+= try self.sendInterleavedRequestsAndTerminate(self.concurrentStreams, channel)
            completedIterations += self.concurrentStreams
            try self.destroyChannel(channel)
        }
        return bodyByteCount
    }

    private func sendInterleavedRequestsAndTerminate(
        _ interleavedRequests: Int,
        _ channel: EmbeddedChannel
    ) throws -> Int {
        var streamID = HTTP2StreamID(1)

        for _ in 0..<interleavedRequests {
            self.headersFrame.setInteger(UInt32(Int32(streamID)), at: self.headersFrame.readerIndex + 5)
            try channel.writeInbound(self.headersFrame)
            streamID = streamID.advanced(by: 2)
        }

        var count = 0
        while let data = try channel.readOutbound(as: ByteBuffer.self) {
            count &+= data.readableBytes
            channel.embeddedEventLoop.run()
        }

        // We need to have got a GOAWAY back, precondition that the count is large enough.
        precondition(count == 17)
        return count
    }
}

private class DoNothingServer: ChannelInboundHandler {
    public typealias InboundIn = HTTP2Frame.FramePayload
    public typealias OutboundOut = HTTP2Frame.FramePayload
}

private class SendGoawayHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTP2Frame
    public typealias OutboundOut = HTTP2Frame

    private static let goawayFrame: HTTP2Frame = HTTP2Frame(
        streamID: .rootStream,
        payload: .goAway(lastStreamID: .rootStream, errorCode: .enhanceYourCalm, opaqueData: nil)
    )

    private let expectedStreams: Int
    private var seenStreams: Int

    init(expectedStreams: Int) {
        self.expectedStreams = expectedStreams
        self.seenStreams = 0
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is NIOHTTP2StreamCreatedEvent {
            self.seenStreams += 1
            if self.seenStreams == self.expectedStreams {
                // Send a GOAWAY to tear all streams down.
                context.writeAndFlush(self.wrapOutboundOut(SendGoawayHandler.goawayFrame), promise: nil)
            }
        }
    }
}
