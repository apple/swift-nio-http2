//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
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
import NIOHTTP1
import Testing

@testable import NIOHTTP2

struct HTTP2FramePayloadToHTTP1CodecCRLFTests {

    // MARK: - Validation tests: pseudo-header values with control characters

    struct PseudoHeaderInjection {
        var pseudoHeaderName: String
        var maliciousValue: String
        var label: String
    }

    static let requestPseudoHeaderInjections: [PseudoHeaderInjection] = [
        .init(pseudoHeaderName: ":path", maliciousValue: "/legit\r\nInjected: evil", label: "CRLF"),
        .init(pseudoHeaderName: ":path", maliciousValue: "/legit\rInjected", label: "lone CR"),
        .init(pseudoHeaderName: ":path", maliciousValue: "/legit\nInjected", label: "lone LF"),
        .init(pseudoHeaderName: ":path", maliciousValue: "/legit\0Injected", label: "NUL"),
        .init(
            pseudoHeaderName: ":path",
            maliciousValue: "/legit\r\nInjected: evil\r\n\r\nGET /admin HTTP/1.1\r\nHost: internal-backend",
            label: "smuggling payload"
        ),
        .init(pseudoHeaderName: ":authority", maliciousValue: "example.com\r\nInjected: evil", label: "CRLF"),
        .init(pseudoHeaderName: ":scheme", maliciousValue: "https\r\nInjected: evil", label: "CRLF"),
        .init(pseudoHeaderName: ":method", maliciousValue: "GET\r\nInjected: evil", label: "CRLF"),
    ]

    @Test(
        "invalid pseudo-headers are rejected",
        arguments: requestPseudoHeaderInjections.map(\.maliciousValue)
    ) func invalidPseudoHeaderValue(value: String) {
        #expect(!HPACKHeaders.isValidPseudoHeaderValue(value))
    }

    @Test(
        "invalid pseudo-headers are accepted",
        arguments: Self.validPaths + ["200"]
    ) func validPseudoHeaderValue(value: String) {
        #expect(HPACKHeaders.isValidPseudoHeaderValue(value))
    }

    @Test(
        "Request validation rejects control characters in pseudo-headers",
        arguments: requestPseudoHeaderInjections
    )
    func requestValidationRejectsControlCharacters(injection: PseudoHeaderInjection) {
        let headers = HPACKHeaders([
            (":method", injection.pseudoHeaderName == ":method" ? injection.maliciousValue : "GET"),
            (":path", injection.pseudoHeaderName == ":path" ? injection.maliciousValue : "/"),
            (":scheme", injection.pseudoHeaderName == ":scheme" ? injection.maliciousValue : "https"),
            (":authority", injection.pseudoHeaderName == ":authority" ? injection.maliciousValue : "example.com"),
        ])
        let error = #expect(throws: NIOHTTP2Errors.InvalidPseudoHeaderValue.self) {
            try headers.validateRequestBlock(supportsExtendedConnect: false)
        }
        #expect(error?.name == injection.pseudoHeaderName && error?.value == injection.maliciousValue)
    }

    @Test("Response validation rejects control characters in :status")
    func responseValidationRejectsCRLFInStatus() {
        let maliciousStatus = "200\r\nInjected: evil"
        let headers = HPACKHeaders([
            (":status", maliciousStatus)
        ])
        #expect {
            try headers.validateResponseBlock()
        } throws: { error in
            let typedError = error as? NIOHTTP2Errors.InvalidPseudoHeaderValue
            return typedError?.name == ":status" && typedError?.value == maliciousStatus
        }
    }

    // MARK: - Validation tests: valid paths pass

    static let validPaths = ["/", "/foo/bar", "/foo?q=1&r=2", "/foo#fragment", "*", "/foo%20bar"]

    @Test("Normal paths pass validation", arguments: validPaths)
    func normalPathsPassValidation(path: String) throws {
        let headers = HPACKHeaders([
            (":method", "GET"),
            (":path", path),
            (":scheme", "https"),
            (":authority", "example.com"),
        ])
        #expect(throws: Never.self) {
            try headers.validateRequestBlock(supportsExtendedConnect: false)
        }
    }

    // MARK: - Validation tests: connection-specific headers are rejected (RFC 9113 § 8.2.2)

    // The five connection-specific header fields that a conformant HTTP/2 endpoint must treat as malformed.
    // `te` is policed separately (it is permitted with the single value "trailers"), so it is not in this list.
    static let connectionSpecificHeaders = [
        "connection", "proxy-connection", "keep-alive", "transfer-encoding", "upgrade",
    ]

    @Test(
        "Request validation rejects connection-specific headers",
        arguments: connectionSpecificHeaders
    )
    func requestValidationRejectsConnectionSpecificHeaders(name: String) {
        let headers = HPACKHeaders([
            (":method", "GET"),
            (":path", "/"),
            (":scheme", "https"),
            (":authority", "example.com"),
            (name, "some-value"),
        ])
        let error = #expect(throws: NIOHTTP2Errors.ForbiddenHeaderField.self) {
            try headers.validateRequestBlock(supportsExtendedConnect: false)
        }
        #expect(error?.name == name && error?.value == "some-value")
    }

    @Test(
        "Response validation rejects connection-specific headers",
        arguments: connectionSpecificHeaders
    )
    func responseValidationRejectsConnectionSpecificHeaders(name: String) {
        let headers = HPACKHeaders([
            (":status", "200"),
            (name, "some-value"),
        ])
        let error = #expect(throws: NIOHTTP2Errors.ForbiddenHeaderField.self) {
            try headers.validateResponseBlock()
        }
        #expect(error?.name == name && error?.value == "some-value")
    }

    // MARK: - Server codec tests: rejects control characters in pseudo-headers

    @Test(
        "Server codec rejects control characters in pseudo-headers",
        arguments: requestPseudoHeaderInjections
    )
    func serverCodecRejectsControlCharacters(injection: PseudoHeaderInjection) throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())

        let requestHeaders = HPACKHeaders([
            (":method", injection.pseudoHeaderName == ":method" ? injection.maliciousValue : "GET"),
            (":path", injection.pseudoHeaderName == ":path" ? injection.maliciousValue : "/"),
            (":scheme", injection.pseudoHeaderName == ":scheme" ? injection.maliciousValue : "https"),
            (":authority", injection.pseudoHeaderName == ":authority" ? injection.maliciousValue : "example.com"),
        ])
        let error = #expect(throws: NIOHTTP2Errors.InvalidPseudoHeaderValue.self) {
            try channel.writeInbound(
                HTTP2Frame.FramePayload.headers(.init(headers: requestHeaders, endStream: true))
            )
        }
        #expect(error?.name == injection.pseudoHeaderName && error?.value == injection.maliciousValue)
    }

    // MARK: - Client codec tests: rejects control characters in :status

    static let maliciousStatusValues: [(value: String, label: String)] = [
        ("200\r\nInjected: evil", "CRLF"),
        ("200\nInjected: evil", "lone LF"),
        ("200\0evil", "NUL"),
    ]

    @Test(
        "Client codec rejects control characters in response :status",
        arguments: maliciousStatusValues
    )
    func clientCodecRejectsControlCharactersInStatus(
        maliciousStatus: (value: String, label: String)
    ) throws {
        let handler = HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
        let channel = EmbeddedChannel(handlers: [handler])

        // Send a valid request first so the codec is in a state to receive a response.
        let http1Head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: ["host": "example.org"]
        )
        channel.write(HTTPClientRequestPart.head(http1Head), promise: nil)
        channel.write(HTTPClientRequestPart.end(nil), promise: nil)
        channel.flush()

        let maliciousResponseHeaders = HPACKHeaders([
            (":status", maliciousStatus.value)
        ])
        let error = #expect(throws: NIOHTTP2Errors.InvalidPseudoHeaderValue.self) {
            try channel.writeInbound(
                HTTP2Frame.FramePayload.headers(.init(headers: maliciousResponseHeaders, endStream: true))
            )
        }
        #expect(error?.name == ":status" && error?.value == maliciousStatus.value)
    }
}
