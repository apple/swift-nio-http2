//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

import NIO
import NIOHPACK
import NIOHTTP2

/// A simple channel handler that can be inserted in a pipeline to ensure that it never sees a write.
///
/// Fails if it receives a write call.
class FailOnWriteHandler: ChannelOutboundHandler {
    typealias OutboundIn = Never
    typealias OutboundOut = Never

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        XCTFail("Write received")
        context.write(data, promise: promise)
    }
}

class ConfiguringPipelineTests: XCTestCase {
    var clientChannel: EmbeddedChannel!
    var serverChannel: EmbeddedChannel!

    override func setUp() {
        self.clientChannel = EmbeddedChannel()
        self.serverChannel = EmbeddedChannel()
    }

    override func tearDown() {
        self.clientChannel = nil
        self.serverChannel = nil
    }

    func testBasicPipelineCommunicates() throws {
        let serverRecorder = FrameRecorderHandler()
        let clientHandler = try assertNoThrowWithValue(self.clientChannel.configureHTTP2Pipeline(mode: .client).wait())
        XCTAssertNoThrow(try self.serverChannel.configureHTTP2Pipeline(mode: .server) { channel, streamID in
            return channel.pipeline.addHandler(serverRecorder)
        }.wait())

        XCTAssertNoThrow(try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))

        // Let's try sending a request.
        let requestPromise = self.clientChannel.eventLoop.makePromise(of: Void.self)
        let reqFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([(":method", "GET"), (":authority", "localhost"), (":scheme", "https"), (":path", "/")]), endStream: true)))

        clientHandler.createStreamChannel(promise: nil) { channel, streamID in
            XCTAssertEqual(streamID, HTTP2StreamID(1))
            channel.writeAndFlush(reqFrame).whenComplete { _ in channel.close(promise: requestPromise) }
            return channel.eventLoop.makeSucceededFuture(())
        }

        // In addition to interacting in memory, we need two loop spins. The first is to execute `createStreamChannel`.
        // The second is to execute the close promise callback, after the interaction is complete.
        (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()
        self.interactInMemory(self.clientChannel, self.serverChannel)
        (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()
        do {
            try requestPromise.futureResult.wait()
            XCTFail("Did not throw")
        } catch is NIOHTTP2Errors.StreamClosed {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // We should have received a HEADERS and a RST_STREAM frame.
        // The RST_STREAM frame is from closing an incomplete stream on the client side.
        let rstStreamFrame = HTTP2Frame(streamID: 1, payload: .rstStream(.cancel))
        serverRecorder.receivedFrames.assertFramesMatch([reqFrame, rstStreamFrame])
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testPipelineRespectsPositionRequest() throws {
        XCTAssertNoThrow(try self.clientChannel.pipeline.addHandler(FailOnWriteHandler()).wait())
        XCTAssertNoThrow(try self.clientChannel.configureHTTP2Pipeline(mode: .client, position: .first).wait())
        XCTAssertNoThrow(try self.serverChannel.configureHTTP2Pipeline(mode: .server).wait())

        XCTAssertNoThrow(try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))

        // It's hard to see this, but if we got this far without a failure there is no failure. It means there were no writes
        // passing through the FailOnWriteHandler, which is what we expect, as we asked for the handlers to be inserted in
        // front of it. Now we just clean up.
        self.clientChannel.assertNoFramesReceived()
        self.serverChannel.assertNoFramesReceived()

        XCTAssertNoThrow(try self.clientChannel.finish())
        XCTAssertNoThrow(try self.serverChannel.finish())
    }

    func testPreambleGetsWrittenOnce() throws {
        // This test checks that the preamble sent by NIOHTTP2Handler is only written once. There are two paths
        // to sending the preamble, in handlerAdded(context:) (if the channel is active) and in channelActive(context:),
        // we want to hit both of these.
        let connectionPromise: EventLoopPromise<Void> = self.serverChannel.eventLoop.makePromise()

        // Register the callback on the promise so we run it as it succeeds (i.e. before fireChannelActive is called).
        let handlerAdded = connectionPromise.futureResult.flatMap {
            // Use .server to avoid sending client magic.
            self.serverChannel.configureHTTP2Pipeline(mode: .server)
        }

        self.serverChannel.connect(to: try SocketAddress(unixDomainSocketPath: "/fake"), promise: connectionPromise)
        XCTAssertNoThrow(try handlerAdded.wait())

        let initialSettingsData: IOData? = try self.serverChannel.readOutbound()
        XCTAssertNotNil(initialSettingsData)

        guard case .some(.byteBuffer(let initialSettingsBuffer)) = initialSettingsData else {
            XCTFail("Expected ByteBuffer containing the initial SETTINGS frame")
            return
        }

        XCTAssertGreaterThanOrEqual(initialSettingsBuffer.readableBytes, 9)
        // The 4-th byte contains the frame type (4 for SETTINGS).
        XCTAssertEqual(initialSettingsBuffer.getInteger(at: initialSettingsBuffer.readerIndex + 3, as: UInt8.self), 4)
        // Bytes 6-9 contain the stream ID; this should be the root stream, 0.
        XCTAssertEqual(initialSettingsBuffer.getInteger(at: initialSettingsBuffer.readerIndex + 6, as: UInt32.self), 0)

        // We don't expect anything else at this point.
        XCTAssertNil(try self.serverChannel.readOutbound(as: IOData.self))
    }

    func testClosingParentChannelClosesStreamChannel() throws {
        /// A channel handler that succeeds a promise when the channel becomes inactive.
        final class InactiveHandler: ChannelInboundHandler {
            typealias InboundIn = Any

            let inactivePromise: EventLoopPromise<Void>

            init(inactivePromise: EventLoopPromise<Void>) {
                self.inactivePromise = inactivePromise
            }

            func channelInactive(context: ChannelHandlerContext) {
                inactivePromise.succeed(())
            }
        }

        let clientMultiplexer = try assertNoThrowWithValue(self.clientChannel.configureHTTP2Pipeline(mode: .client).wait())
        XCTAssertNoThrow(try self.serverChannel.configureHTTP2Pipeline(mode: .server).wait())

        XCTAssertNoThrow(try self.assertDoHandshake(client: self.clientChannel, server: self.serverChannel))

        let inactivePromise: EventLoopPromise<Void> = self.clientChannel.eventLoop.makePromise()
        let streamChannelPromise: EventLoopPromise<Channel> = self.clientChannel.eventLoop.makePromise()

        clientMultiplexer.createStreamChannel(promise: streamChannelPromise) { channel, _ in
            return channel.pipeline.addHandler(InactiveHandler(inactivePromise: inactivePromise))
        }

        (self.clientChannel.eventLoop as! EmbeddedEventLoop).run()

        let streamChannel = try assertNoThrowWithValue(try streamChannelPromise.futureResult.wait())
        // Close the parent channel, not the stream channel.
        XCTAssertNoThrow(try self.clientChannel.close().wait())

        XCTAssertNoThrow(try inactivePromise.futureResult.wait())
        XCTAssertFalse(streamChannel.isActive)

        XCTAssertThrowsError(try self.clientChannel.finish()) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }
        XCTAssertNoThrow(try self.serverChannel.finish())
    }
}
