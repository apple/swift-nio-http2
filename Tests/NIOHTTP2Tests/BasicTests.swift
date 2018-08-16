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

import XCTest

import NIO
import CNIONghttp2

@testable import NIOHTTP2

class BasicTests: XCTestCase {
    func testCanInitializeInnerSession() {
        let x = NGHTTP2Session(mode: .server,
                               allocator: ByteBufferAllocator(),
                               maxCachedStreamIDs: 1024,
                               frameReceivedHandler: { _ in },
                               sendFunction: { _, _ in },
                               userEventFunction: { _ in })
        XCTAssertNotNil(x)
    }

    func testThrowsErrorOnBasicProtocolViolation() {
        let session = NGHTTP2Session(mode: .server,
                                     allocator: ByteBufferAllocator(),
                                     maxCachedStreamIDs: 1024,
                                     frameReceivedHandler: { XCTFail("shouldn't have received frame \($0)") },
                                     sendFunction: { XCTFail("send(\($0), \($1.debugDescription)) shouldn't have been called") },
                                     userEventFunction: { XCTFail("userEventFunction(\($0)) shouldn't have been called") })
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.write(staticString: "GET / HTTP/1.1\r\nHost: apple.com\r\n\r\n")
        XCTAssertThrowsError(try session.feedInput(buffer: &buffer)) { error in
            switch error {
            case _ as NIOHTTP2Errors.BadClientMagic:
                // ok
                ()
            default:
                XCTFail("wrong error \(error) thrown")
            }
        }
    }
}
