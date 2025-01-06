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

import NIOHPACK
import NIOHTTP2
import XCTest

class HTTP2ErrorTests: XCTestCase {
    func testEquatableExcludesFileAndLine() throws {
        XCTAssertEqual(
            NIOHTTP2Errors.excessiveOutboundFrameBuffering(),
            NIOHTTP2Errors.excessiveOutboundFrameBuffering(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidALPNToken(),
            NIOHTTP2Errors.invalidALPNToken(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.noSuchStream(streamID: .rootStream),
            NIOHTTP2Errors.noSuchStream(streamID: .rootStream, file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.noSuchStream(streamID: 1),
            NIOHTTP2Errors.noSuchStream(streamID: 2)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.streamClosed(streamID: .rootStream, errorCode: .cancel),
            NIOHTTP2Errors.streamClosed(streamID: .rootStream, errorCode: .cancel, file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .cancel),
            NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .compressionError)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.streamClosed(streamID: 1, errorCode: .cancel),
            NIOHTTP2Errors.streamClosed(streamID: 2, errorCode: .cancel)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.badClientMagic(),
            NIOHTTP2Errors.badClientMagic(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.badStreamStateTransition(),
            NIOHTTP2Errors.badStreamStateTransition(file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.badStreamStateTransition(from: .closed),
            NIOHTTP2Errors.badStreamStateTransition()
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidFlowControlWindowSize(delta: 1, currentWindowSize: 2),
            NIOHTTP2Errors.invalidFlowControlWindowSize(delta: 1, currentWindowSize: 2, file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.invalidFlowControlWindowSize(delta: 1, currentWindowSize: 2),
            NIOHTTP2Errors.invalidFlowControlWindowSize(delta: 2, currentWindowSize: 2)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.invalidFlowControlWindowSize(delta: 1, currentWindowSize: 3),
            NIOHTTP2Errors.invalidFlowControlWindowSize(delta: 1, currentWindowSize: 2)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.flowControlViolation(),
            NIOHTTP2Errors.flowControlViolation(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidSetting(setting: .init(parameter: .maxConcurrentStreams, value: 1)),
            NIOHTTP2Errors.invalidSetting(setting: .init(parameter: .maxConcurrentStreams, value: 1), file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.invalidSetting(setting: .init(parameter: .maxConcurrentStreams, value: 1)),
            NIOHTTP2Errors.invalidSetting(setting: .init(parameter: .maxConcurrentStreams, value: 2))
        )

        XCTAssertEqual(
            NIOHTTP2Errors.ioOnClosedConnection(),
            NIOHTTP2Errors.ioOnClosedConnection(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.receivedBadSettings(),
            NIOHTTP2Errors.receivedBadSettings(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.maxStreamsViolation(),
            NIOHTTP2Errors.maxStreamsViolation(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.streamIDTooSmall(),
            NIOHTTP2Errors.streamIDTooSmall(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.missingPreface(),
            NIOHTTP2Errors.missingPreface(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.createdStreamAfterGoaway(),
            NIOHTTP2Errors.createdStreamAfterGoaway(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidStreamIDForPeer(),
            NIOHTTP2Errors.invalidStreamIDForPeer(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.raisedGoawayLastStreamID(),
            NIOHTTP2Errors.raisedGoawayLastStreamID(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidWindowIncrementSize(),
            NIOHTTP2Errors.invalidWindowIncrementSize(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.pushInViolationOfSetting(),
            NIOHTTP2Errors.pushInViolationOfSetting(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.unsupported(info: "info"),
            NIOHTTP2Errors.unsupported(info: "info", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.unsupported(info: "info"),
            NIOHTTP2Errors.unsupported(info: "notinfo")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.unableToSerializeFrame(),
            NIOHTTP2Errors.unableToSerializeFrame(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.unableToParseFrame(),
            NIOHTTP2Errors.unableToParseFrame(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.missingPseudoHeader("missing"),
            NIOHTTP2Errors.missingPseudoHeader("missing", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.missingPseudoHeader("missing"),
            NIOHTTP2Errors.missingPseudoHeader("notmissing")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.duplicatePseudoHeader("duplicate"),
            NIOHTTP2Errors.duplicatePseudoHeader("duplicate", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.duplicatePseudoHeader("duplicate"),
            NIOHTTP2Errors.duplicatePseudoHeader("notduplicate")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.pseudoHeaderAfterRegularHeader("after"),
            NIOHTTP2Errors.pseudoHeaderAfterRegularHeader("after", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.pseudoHeaderAfterRegularHeader("after"),
            NIOHTTP2Errors.pseudoHeaderAfterRegularHeader("notafter")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.unknownPseudoHeader("unknown"),
            NIOHTTP2Errors.unknownPseudoHeader("unknown", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.unknownPseudoHeader("unknown"),
            NIOHTTP2Errors.unknownPseudoHeader("notunknown")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidPseudoHeaders([:]),
            NIOHTTP2Errors.invalidPseudoHeaders([:], file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.invalidPseudoHeaders([:]),
            NIOHTTP2Errors.invalidPseudoHeaders(["not": "empty"])
        )

        XCTAssertEqual(
            NIOHTTP2Errors.missingHostHeader(),
            NIOHTTP2Errors.missingHostHeader(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.duplicateHostHeader(),
            NIOHTTP2Errors.duplicateHostHeader(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.emptyPathHeader(),
            NIOHTTP2Errors.emptyPathHeader(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidStatusValue("invalid"),
            NIOHTTP2Errors.invalidStatusValue("invalid", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.invalidStatusValue("invalid"),
            NIOHTTP2Errors.invalidStatusValue("notinvalid")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.priorityCycle(streamID: .rootStream),
            NIOHTTP2Errors.priorityCycle(streamID: .rootStream, file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.priorityCycle(streamID: .rootStream),
            NIOHTTP2Errors.priorityCycle(streamID: 1)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.trailersWithoutEndStream(streamID: .rootStream),
            NIOHTTP2Errors.trailersWithoutEndStream(streamID: .rootStream, file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.trailersWithoutEndStream(streamID: .rootStream),
            NIOHTTP2Errors.trailersWithoutEndStream(streamID: 1)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.invalidHTTP2HeaderFieldName("fieldName"),
            NIOHTTP2Errors.invalidHTTP2HeaderFieldName("fieldName", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.invalidHTTP2HeaderFieldName("fieldName"),
            NIOHTTP2Errors.invalidHTTP2HeaderFieldName("notFieldName")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.forbiddenHeaderField(name: "name", value: "value"),
            NIOHTTP2Errors.forbiddenHeaderField(name: "name", value: "value", file: "", line: 0)
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.forbiddenHeaderField(name: "name", value: "value"),
            NIOHTTP2Errors.forbiddenHeaderField(name: "notname", value: "value")
        )

        XCTAssertNotEqual(
            NIOHTTP2Errors.forbiddenHeaderField(name: "name", value: "value"),
            NIOHTTP2Errors.forbiddenHeaderField(name: "name", value: "notvalue")
        )

        XCTAssertEqual(
            NIOHTTP2Errors.contentLengthViolated(),
            NIOHTTP2Errors.contentLengthViolated(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.excessiveEmptyDataFrames(),
            NIOHTTP2Errors.excessiveEmptyDataFrames(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.excessivelyLargeHeaderBlock(),
            NIOHTTP2Errors.excessivelyLargeHeaderBlock(file: "", line: 0)
        )

        XCTAssertEqual(
            NIOHTTP2Errors.noStreamIDAvailable(),
            NIOHTTP2Errors.noStreamIDAvailable(file: "", line: 0)
        )
    }

    func testFitsInAnExistentialContainer() {
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.ExcessiveOutboundFrameBuffering>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidALPNToken>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.NoSuchStream>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.StreamClosed>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.BadClientMagic>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.BadStreamStateTransition>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidFlowControlWindowSize>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.FlowControlViolation>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidSetting>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.IOOnClosedConnection>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.ReceivedBadSettings>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.MaxStreamsViolation>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.StreamIDTooSmall>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.MissingPreface>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.CreatedStreamAfterGoaway>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidStreamIDForPeer>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.RaisedGoawayLastStreamID>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidWindowIncrementSize>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.PushInViolationOfSetting>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.Unsupported>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.UnableToSerializeFrame>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.UnableToParseFrame>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.MissingPseudoHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.DuplicatePseudoHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.PseudoHeaderAfterRegularHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.UnknownPseudoHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.UnsupportedPseudoHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidPseudoHeaders>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.MissingHostHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.DuplicateHostHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.EmptyPathHeader>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidStatusValue>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.PriorityCycle>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.TrailersWithoutEndStream>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.InvalidHTTP2HeaderFieldName>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.ForbiddenHeaderField>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.ContentLengthViolated>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.ExcessiveEmptyDataFrames>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.ExcessivelyLargeHeaderBlock>.size, 24)
        XCTAssertLessThanOrEqual(MemoryLayout<NIOHTTP2Errors.NoStreamIDAvailable>.size, 24)
    }
}
