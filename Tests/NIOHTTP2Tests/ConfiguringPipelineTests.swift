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
        let reqFrame = HTTP2Frame(streamID: 1, payload: .headers(.init(headers: HPACKHeaders([]), endStream: true)))

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
}
