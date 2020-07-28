//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
@testable import NIOHTTP2
import XCTest

final class HTTP2FrameConvertibleTests: XCTestCase {
    func testHTTP2FrameConvertible() {
        func checkConversion<Convertible: HTTP2FrameConvertible>(from convertible: Convertible, line: UInt = #line) {
            let frame = convertible.makeHTTP2Frame(streamID: 42)

            XCTAssertEqual(frame.streamID, 42)
            switch frame.payload {
            case .settings(.ack):
                ()  // Expected
            default:
                XCTFail("Unexpected frame payload '\(frame.payload)'", line: line)
            }
        }

        // Boring case: frame from a frame.
        let frame = HTTP2Frame(streamID: 42, payload: .settings(.ack))
        checkConversion(from: frame)

        // Marginally less boring: frame from a payload.
        let payload = HTTP2Frame.FramePayload.settings(.ack)
        checkConversion(from: payload)
    }

    func testHTTP2FramePayloadConvertible() {
        func checkConversion<Convertible: HTTP2FramePayloadConvertible>(from convertible: Convertible, line: UInt = #line) {
            let payload = convertible.payload

            switch payload {
            case .settings(.ack):
                ()  // Expected
            default:
                XCTFail("Unexpected frame payload '\(payload)'", line: line)
            }
        }

        // Boring case: payload from a payload.
        let payload = HTTP2Frame.FramePayload.settings(.ack)
        checkConversion(from: payload)

        // Marginally less boring: payload from a frame.
        let frame = HTTP2Frame(streamID: 42, payload: .settings(.ack))
        checkConversion(from: frame)
    }
}
