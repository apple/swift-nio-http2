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
import NIOHPACK

public protocol NIOHTTP2Error: Equatable, Error { }

/// Errors that NIO raises when handling HTTP/2 connections.
public enum NIOHTTP2Errors {
    public static func excessiveOutboundFrameBuffering(file: String = #file, line: UInt = #line) -> ExcessiveOutboundFrameBuffering {
        return ExcessiveOutboundFrameBuffering(file: file, line: line)
    }

    public static func invalidALPNToken(file: String = #file, line: UInt = #line) -> InvalidALPNToken {
        return InvalidALPNToken(file: file, line: line)
    }

    public static func noSuchStream(streamID: HTTP2StreamID, file: String = #file, line: UInt = #line) -> NoSuchStream {
        return NoSuchStream(streamID: streamID, file: file, line: line)
    }

    public static func streamClosed(streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, file: String = #file, line: UInt = #line) -> StreamClosed {
        return StreamClosed(streamID: streamID, errorCode: errorCode, file: file, line: line)
    }

    public static func badClientMagic(file: String = #file, line: UInt = #line) -> BadClientMagic {
        return BadClientMagic(file: file, line: line)
    }

    public static func badStreamStateTransition(from state: NIOHTTP2StreamState? = nil, file: String = #file, line: UInt = #line) -> BadStreamStateTransition {
        return BadStreamStateTransition(from: state, file: file, line: line)
    }

    public static func invalidFlowControlWindowSize(delta: Int, currentWindowSize: Int, file: String = #file, line: UInt = #line) -> InvalidFlowControlWindowSize {
        return InvalidFlowControlWindowSize(delta: delta, currentWindowSize: currentWindowSize, file: file, line: line)
    }

    public static func flowControlViolation(file: String = #file, line: UInt = #line) -> FlowControlViolation {
        return FlowControlViolation(file: file, line: line)
    }

    public static func invalidSetting(setting: HTTP2Setting, file: String = #file, line: UInt = #line) -> InvalidSetting {
        return InvalidSetting(setting: setting, file: file, line: line)
    }

    public static func ioOnClosedConnection(file: String = #file, line: UInt = #line) -> IOOnClosedConnection {
        return IOOnClosedConnection(file: file, line: line)
    }

    public static func receivedBadSettings(file: String = #file, line: UInt = #line) -> ReceivedBadSettings {
        return ReceivedBadSettings(file: file, line: line)
    }

    public static func maxStreamsViolation(file: String = #file, line: UInt = #line) -> MaxStreamsViolation {
        return MaxStreamsViolation(file: file, line: line)
    }

    public static func streamIDTooSmall(file: String = #file, line: UInt = #line) -> StreamIDTooSmall {
        return StreamIDTooSmall(file: file, line: line)
    }

    public static func missingPreface(file: String = #file, line: UInt = #line) -> MissingPreface {
        return MissingPreface(file: file, line: line)
    }

    public static func createdStreamAfterGoaway(file: String = #file, line: UInt = #line) -> CreatedStreamAfterGoaway {
        return CreatedStreamAfterGoaway(file: file, line: line)
    }

    public static func invalidStreamIDForPeer(file: String = #file, line: UInt = #line) -> InvalidStreamIDForPeer {
        return InvalidStreamIDForPeer(file: file, line: line)
    }

    public static func raisedGoawayLastStreamID(file: String = #file, line: UInt = #line) -> RaisedGoawayLastStreamID {
        return RaisedGoawayLastStreamID(file: file, line: line)
    }

    public static func invalidWindowIncrementSize(file: String = #file, line: UInt = #line) -> InvalidWindowIncrementSize {
        return InvalidWindowIncrementSize(file: file, line: line)
    }

    public static func pushInViolationOfSetting(file: String = #file, line: UInt = #line) -> PushInViolationOfSetting {
        return PushInViolationOfSetting(file: file, line: line)
    }

    public static func unsupported(info: String, file: String = #file, line: UInt = #line) -> Unsupported {
        return Unsupported(info: info, file: file, line: line)
    }

    public static func unableToSerializeFrame(file: String = #file, line: UInt = #line) -> UnableToSerializeFrame {
        return UnableToSerializeFrame(file: file, line: line)
    }

    public static func unableToParseFrame(file: String = #file, line: UInt = #line) -> UnableToParseFrame {
        return UnableToParseFrame(file: file, line: line)
    }

    public static func missingPseudoHeader(_ name: String, file: String = #file, line: UInt = #line) -> MissingPseudoHeader {
        return MissingPseudoHeader(name, file: file, line: line)
    }

    public static func duplicatePseudoHeader(_ name: String, file: String = #file, line: UInt = #line) -> DuplicatePseudoHeader {
        return DuplicatePseudoHeader(name, file: file, line: line)
    }

    public static func pseudoHeaderAfterRegularHeader(_ name: String, file: String = #file, line: UInt = #line) -> PseudoHeaderAfterRegularHeader {
        return PseudoHeaderAfterRegularHeader(name, file: file, line: line)
    }

    public static func unknownPseudoHeader(_ name: String, file: String = #file, line: UInt = #line) -> UnknownPseudoHeader {
        return UnknownPseudoHeader(name, file: file, line: line)
    }

    public static func invalidPseudoHeaders(_ block: HPACKHeaders, file: String = #file, line: UInt = #line) -> InvalidPseudoHeaders {
        return InvalidPseudoHeaders(block, file: file, line: line)
    }

    public static func missingHostHeader(file: String = #file, line: UInt = #line) -> MissingHostHeader {
        return MissingHostHeader(file: file, line: line)
    }

    public static func duplicateHostHeader(file: String = #file, line: UInt = #line) -> DuplicateHostHeader {
        return DuplicateHostHeader(file: file, line: line)
    }

    public static func emptyPathHeader(file: String = #file, line: UInt = #line) -> EmptyPathHeader {
        return EmptyPathHeader(file: file, line: line)
    }

    public static func invalidStatusValue(_ value: String, file: String = #file, line: UInt = #line) -> InvalidStatusValue {
        return InvalidStatusValue(value, file: file, line: line)
    }

    public static func priorityCycle(streamID: HTTP2StreamID, file: String = #file, line: UInt = #line) -> PriorityCycle {
        return PriorityCycle(streamID: streamID, file: file, line: line)
    }

    public static func trailersWithoutEndStream(streamID: HTTP2StreamID, file: String = #file, line: UInt = #line) -> TrailersWithoutEndStream {
        return TrailersWithoutEndStream(streamID: streamID, file: file, line: line)
    }

    public static func invalidHTTP2HeaderFieldName(_ fieldName: String, file: String = #file, line: UInt = #line) -> InvalidHTTP2HeaderFieldName {
        return InvalidHTTP2HeaderFieldName(fieldName, file: file, line: line)
    }

    public static func forbiddenHeaderField(name: String, value: String, file: String = #file, line: UInt = #line) -> ForbiddenHeaderField {
        return ForbiddenHeaderField(name: name, value: value, file: file, line: line)
    }

    public static func contentLengthViolated(file: String = #file, line: UInt = #line) -> ContentLengthViolated {
        return ContentLengthViolated(file: file, line: line)
    }

    public static func excessiveEmptyDataFrames(file: String = #file, line: UInt = #line) -> ExcessiveEmptyDataFrames {
        return ExcessiveEmptyDataFrames(file: file, line: line)
    }

    public static func excessivelyLargeHeaderBlock(file: String = #file, line: UInt = #line) -> ExcessivelyLargeHeaderBlock {
        return ExcessivelyLargeHeaderBlock(file: file, line: line)
    }

    public static func noStreamIDAvailable(file: String = #file, line: UInt = #line) -> NoStreamIDAvailable {
        return NoStreamIDAvailable(file: file, line: line)
    }

    /// The outbound frame buffers have become filled, and it is not possible to buffer
    /// further outbound frames. This occurs when the remote peer is generating work
    /// faster than they are consuming the result. Additional buffering runs the risk of
    /// memory exhaustion.
    public struct ExcessiveOutboundFrameBuffering: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "excessiveOutboundFrameBuffering")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: ExcessiveOutboundFrameBuffering, rhs: ExcessiveOutboundFrameBuffering) -> Bool {
            return true
        }
    }

    /// NIO's upgrade handler encountered a successful upgrade to a protocol that it
    /// does not recognise.
    public struct InvalidALPNToken: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "invalidALPNToken")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: InvalidALPNToken, rhs: InvalidALPNToken) -> Bool {
            return true
        }
    }

    /// An attempt was made to issue a write on a stream that does not exist.
    public struct NoSuchStream: NIOHTTP2Error {
        /// The stream ID that was used that does not exist.
        public var streamID: HTTP2StreamID

        /// The location where the error was thrown.
        public let location: String

        @available(*, deprecated, renamed: "noSuchStream")
        public init(streamID: HTTP2StreamID) {
            self.init(streamID: streamID, file: #file, line: #line)
        }

        fileprivate init(streamID: HTTP2StreamID, file: String, line: UInt) {
            self.streamID = streamID
            self.location = _location(file: file, line: line)
        }

        public static func ==(lhs: NoSuchStream, rhs: NoSuchStream) -> Bool {
            return lhs.streamID == rhs.streamID
        }
    }

    /// A stream was closed.
    public struct StreamClosed: NIOHTTP2Error {
        /// The stream ID that was closed.
        public var streamID: HTTP2StreamID

        /// The error code associated with the closure.
        public var errorCode: HTTP2ErrorCode

        /// The file and line where the error was created.
        public let location: String

        @available(*, deprecated, renamed: "streamClosed")
        public init(streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode) {
            self.init(streamID: streamID, errorCode: errorCode, file: #file, line: #line)
        }

        fileprivate init(streamID: HTTP2StreamID, errorCode: HTTP2ErrorCode, file: String, line: UInt) {
            self.streamID = streamID
            self.errorCode = errorCode
            self.location = _location(file: file, line: line)
        }

        public static func ==(lhs: StreamClosed, rhs: StreamClosed) -> Bool {
            return lhs.streamID == rhs.streamID && lhs.errorCode == rhs.errorCode
        }
    }

    public struct BadClientMagic: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "badClientMagic")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: BadClientMagic, rhs: BadClientMagic) -> Bool {
            return true
        }
    }

    /// A stream state transition was attempted that was not valid.
    public struct BadStreamStateTransition: NIOHTTP2Error, CustomStringConvertible {
        public let fromState: NIOHTTP2StreamState?

        /// The location where the error was thrown.
        public let location: String

        public var description: String {
            let stateName = self.fromState != nil ? "\(self.fromState!)" : "unknown state"
            return "BadStreamStateTransition(fromState: \(stateName), location: \(self.location))"
        }

        fileprivate init(from state: NIOHTTP2StreamState?, file: String, line: UInt) {
            self.fromState = state
            self.location = _location(file: file, line: line)
        }

        @available(*, deprecated, renamed: "badStreamStateTransition")
        public init() {
            self.init(from: nil, file: #file, line: #line)
        }

        public static func ==(lhs: BadStreamStateTransition, rhs: BadStreamStateTransition) -> Bool {
            return lhs.fromState == rhs.fromState
        }
    }

    /// An attempt was made to change the flow control window size, either via
    /// SETTINGS or WINDOW_UPDATE, but this change would move the flow control
    /// window size out of bounds.
    public struct InvalidFlowControlWindowSize: NIOHTTP2Error, CustomStringConvertible {
        private var storage: Storage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        private final class Storage: Equatable {
            var delta: Int
            var currentWindowSize: Int
            var file: String
            var line: UInt

            var location: String {
                return _location(file: self.file, line: self.line)
            }

            init(delta: Int, currentWindowSize: Int, file: String, line: UInt) {
                self.delta = delta
                self.currentWindowSize = currentWindowSize
                self.file = file
                self.line = line
            }

            func copy() -> Storage {
                return Storage(delta: self.delta, currentWindowSize: self.currentWindowSize, file: self.file, line: self.line)
            }

            static func ==(lhs: Storage, rhs: Storage) -> Bool {
                return lhs.delta == rhs.delta && lhs.currentWindowSize == rhs.currentWindowSize
            }
        }

        /// The delta being applied to the flow control window.
        public var delta: Int {
            get {
                return self.storage.delta
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.delta = newValue
            }
        }

        /// The size of the flow control window before the delta was applied.
        public var currentWindowSize: Int {
            get {
                return self.storage.currentWindowSize
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.currentWindowSize = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "InvalidFlowControlWindowSize(delta: \(self.delta), currentWindowSize: \(self.currentWindowSize), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "invalidFlowControlWindowSize")
        public init(delta: Int, currentWindowSize: Int) {
            self.init(delta: delta, currentWindowSize: currentWindowSize, file: #file, line: #line)
        }

        fileprivate init(delta: Int, currentWindowSize: Int, file: String, line: UInt) {
            self.storage = Storage(delta: delta, currentWindowSize: currentWindowSize, file: file, line: line)
        }
    }

    /// A frame was sent or received that violates HTTP/2 flow control rules.
    public struct FlowControlViolation: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "flowControlViolation")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: FlowControlViolation, rhs: FlowControlViolation) -> Bool {
            return true
        }
    }

    /// A SETTINGS frame was sent or received with an invalid setting.
    public struct InvalidSetting: NIOHTTP2Error {
        /// The invalid setting.
        public var setting: HTTP2Setting

        /// The location where the error was thrown.
        public let location: String

        @available(*, deprecated, renamed: "invalidSetting")
        public init(setting: HTTP2Setting) {
            self.init(setting: setting, file: #file, line: #line)
        }

        fileprivate init(setting: HTTP2Setting, file: String, line: UInt) {
            self.setting = setting
            self.location = _location(file: file, line: line)
        }

        public static func ==(lhs: InvalidSetting, rhs: InvalidSetting) -> Bool {
            return lhs.setting == rhs.setting
        }
    }

    /// An attempt to perform I/O was made on a connection that is already closed.
    public struct IOOnClosedConnection: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "ioOnClosedConnection")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: IOOnClosedConnection, rhs: IOOnClosedConnection) -> Bool {
            return true
        }
    }

    /// A SETTINGS frame was received that is invalid.
    public struct ReceivedBadSettings: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "receivedBadSettings")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: ReceivedBadSettings, rhs: ReceivedBadSettings) -> Bool {
            return true
        }
    }

    /// A violation of SETTINGS_MAX_CONCURRENT_STREAMS occurred.
    public struct MaxStreamsViolation: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "maxStreamsViolation")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: MaxStreamsViolation, rhs: MaxStreamsViolation) -> Bool {
            return true
        }
    }

    /// An attempt was made to use a stream ID that is too small.
    public struct StreamIDTooSmall: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "streamIDTooSmall")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: StreamIDTooSmall, rhs: StreamIDTooSmall) -> Bool {
            return true
        }
    }

    /// An attempt was made to send a frame without having previously sent a connection preface!
    public struct MissingPreface: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "missingPreface")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: MissingPreface, rhs: MissingPreface) -> Bool {
            return true
        }
    }

    /// An attempt was made to create a stream after a GOAWAY frame has forbidden further
    /// stream creation.
    public struct CreatedStreamAfterGoaway: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "createdStreamAfterGoaway")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: CreatedStreamAfterGoaway, rhs: CreatedStreamAfterGoaway) -> Bool {
            return true
        }
    }

    /// A peer has attempted to create a stream with a stream ID it is not permitted to use.
    public struct InvalidStreamIDForPeer: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "invalidStreamIDForPeer")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: InvalidStreamIDForPeer, rhs: InvalidStreamIDForPeer) -> Bool {
            return true
        }
    }

    /// An attempt was made to send a new GOAWAY frame whose lastStreamID is higher than the previous value.
    public struct RaisedGoawayLastStreamID: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "raisedGoawayLastStreamID")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: RaisedGoawayLastStreamID, rhs: RaisedGoawayLastStreamID) -> Bool {
            return true
        }
    }

    /// The size of the window increment is invalid.
    public struct InvalidWindowIncrementSize: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "invalidWindowIncrementSize")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: InvalidWindowIncrementSize, rhs: InvalidWindowIncrementSize) -> Bool {
            return true
        }
    }

    /// An attempt was made to push a stream, even though the settings forbid it.
    public struct PushInViolationOfSetting: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "pushInViolationOfSetting")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: PushInViolationOfSetting, rhs: PushInViolationOfSetting) -> Bool {
            return true
        }
    }

    /// An attempt was made to use a currently unsupported feature.
    public struct Unsupported: NIOHTTP2Error, CustomStringConvertible {
        private var storage: StringAndLocationStorage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        public var info: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "Unsupported(info: \(self.info), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "unsupported")
        public init(info: String) {
            self.init(info: info, file: #file, line: #line)
        }

        fileprivate init(info: String, file: String, line: UInt) {
            self.storage = .init(info, file: file, line: line)
        }
    }

    public struct UnableToSerializeFrame: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "unableToSerializeFrame")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: UnableToSerializeFrame, rhs: UnableToSerializeFrame) -> Bool {
            return true
        }
    }

    public struct UnableToParseFrame: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "unableToParseFrame")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: UnableToParseFrame, rhs: UnableToParseFrame) -> Bool {
            return true
        }
    }

    /// A pseudo-header field is missing.
    public struct MissingPseudoHeader: NIOHTTP2Error, CustomStringConvertible {
        private var storage: StringAndLocationStorage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        public var name: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "MissingPseudoHeader(name: \(self.name), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "missingPseudoHeader")
        public init(_ name: String) {
            self.init(name, file: #file, line: #line)
        }

        fileprivate init(_ name: String, file: String, line: UInt) {
            self.storage = .init(name, file: file, line: line)
        }
    }

    /// A pseudo-header field has been duplicated.
    public struct DuplicatePseudoHeader: NIOHTTP2Error, CustomStringConvertible {
        private var storage: StringAndLocationStorage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        public var name: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "DuplicatePseudoHeader(name: \(self.name), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "duplicatePseudoHeader")
        public init(_ name: String) {
            self.init(name, file: #file, line: #line)
        }

        fileprivate init(_ name: String, file: String, line: UInt) {
            self.storage = .init(name, file: file, line: line)
        }
    }

    /// A header block contained a pseudo-header after a regular header.
    public struct PseudoHeaderAfterRegularHeader: NIOHTTP2Error, CustomStringConvertible {
        private var storage: StringAndLocationStorage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        public var name: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "PseudoHeaderAfterRegularHeader(name: \(self.name), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "pseudoHeaderAfterRegularHeader")
        public init(_ name: String) {
            self.init(name, file: #file, line: #line)
        }

        fileprivate init(_ name: String, file: String, line: UInt) {
            self.storage = .init(name, file: file, line: line)
        }
    }

    /// An unknown pseudo-header was received.
    public struct UnknownPseudoHeader: NIOHTTP2Error, CustomStringConvertible {
        private var storage: StringAndLocationStorage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        public var name: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "UnknownPseudoHeader(name: \(self.name), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "unknownPseudoHeader")
        public init(_ name: String) {
            self.init(name, file: #file, line: #line)
        }

        fileprivate init(_ name: String, file: String, line: UInt) {
            self.storage = .init(name, file: file, line: line)
        }
    }

    /// A header block was received with an invalid set of pseudo-headers for the block type.
    public struct InvalidPseudoHeaders: NIOHTTP2Error {
        public var headerBlock: HPACKHeaders

        /// The location where the error was thrown.
        public let location: String

        @available(*, deprecated, renamed: "invalidPseudoHeaders")
        public init(_ block: HPACKHeaders) {
            self.init(block, file: #file, line: #line)
        }

        fileprivate init(_ block: HPACKHeaders, file: String, line: UInt) {
            self.headerBlock = block
            self.location = _location(file: file, line: line)
        }

        public static func ==(lhs: InvalidPseudoHeaders, rhs: InvalidPseudoHeaders) -> Bool {
            return lhs.headerBlock == rhs.headerBlock
        }
    }

    /// An outbound request was about to be sent, but does not contain a Host header.
    public struct MissingHostHeader: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "missingHostHeader")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: MissingHostHeader, rhs: MissingHostHeader) -> Bool {
            return true
        }
    }

    /// An outbound request was about to be sent, but it contains a duplicated Host header.
    public struct DuplicateHostHeader: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "duplicateHostHeader")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: DuplicateHostHeader, rhs: DuplicateHostHeader) -> Bool {
            return true
        }
    }

    /// A HTTP/2 header block was received with an empty :path header.
    public struct EmptyPathHeader: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "emptyPathHeader")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: EmptyPathHeader, rhs: EmptyPathHeader) -> Bool {
            return true
        }
    }

    /// A :status header was received with an invalid value.
    public struct InvalidStatusValue: NIOHTTP2Error, CustomStringConvertible {
        private var storage: StringAndLocationStorage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        public var value: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "InvalidStatusValue(value: \(self.value), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "invalidStatusValue")
        public init(_ value: String) {
            self.init(value, file: #file, line: #line)
        }

        fileprivate init(_ value: String, file: String, line: UInt) {
            self.storage = .init(value, file: file, line: line)
        }
    }

    /// A priority update was received that would create a PRIORITY cycle.
    public struct PriorityCycle: NIOHTTP2Error {
        /// The affected stream ID.
        public var streamID: HTTP2StreamID

        /// The location where the error was thrown.
        public let location: String

        @available(*, deprecated, renamed: "priorityCycle")
        public init(streamID: HTTP2StreamID) {
            self.init(streamID: streamID, file: #file, line: #line)
        }

        fileprivate init(streamID: HTTP2StreamID, file: String, line: UInt) {
            self.streamID = streamID
            self.location = _location(file: file, line: line)
        }

        public static func ==(lhs: PriorityCycle, rhs: PriorityCycle) -> Bool {
            return lhs.streamID == rhs.streamID
        }
    }

    /// An attempt was made to send trailers without setting END_STREAM on them.
    public struct TrailersWithoutEndStream: NIOHTTP2Error {
        /// The affected stream ID.
        public var streamID: HTTP2StreamID

        /// The location where the error was thrown.
        public let location: String

        @available(*, deprecated, renamed: "trailersWithoutEndStream")
        public init(streamID: HTTP2StreamID) {
            self.init(streamID: streamID, file: #file, line: #line)
        }

        fileprivate init(streamID: HTTP2StreamID, file: String, line: UInt) {
            self.streamID = streamID
            self.location = _location(file: file, line: line)
        }

        public static func ==(lhs: TrailersWithoutEndStream, rhs: TrailersWithoutEndStream) -> Bool {
            return lhs.streamID == rhs.streamID
        }
    }

    /// An attempt was made to send a header field with a field name that is not valid in HTTP/2.
    public struct InvalidHTTP2HeaderFieldName: NIOHTTP2Error, CustomStringConvertible {
        private var storage: StringAndLocationStorage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        public var fieldName: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "InvalidHTTP2HeaderFieldName(fieldName: \(self.fieldName), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "invalidHTTP2HeaderFieldName")
        public init(_ name: String) {
            self.init(name, file: #file, line: #line)
        }

        fileprivate init(_ name: String, file: String, line: UInt) {
            self.storage = .init(name, file: file, line: line)
        }
    }

    /// Connection-specific header fields are forbidden in HTTP/2: this error is raised when one is
    /// sent or received.
    public struct ForbiddenHeaderField: NIOHTTP2Error, CustomStringConvertible {
        private var storage: Storage

        private mutating func copyStorageIfNotUniquelyReferenced() {
            if !isKnownUniquelyReferenced(&self.storage) {
                self.storage = self.storage.copy()
            }
        }

        private final class Storage: Equatable {
            var name: String
            var value: String
            var file: String
            var line: UInt

            var location: String {
                return _location(file: self.file, line: self.line)
            }

            init(name: String, value: String, file: String, line: UInt) {
                self.name = name
                self.value = value
                self.file = file
                self.line = line
            }

            func copy() -> Storage {
                return Storage(name: self.name, value: self.value, file: self.file, line: self.line)
            }

            static func ==(lhs: Storage, rhs: Storage) -> Bool {
                return lhs.name == rhs.name && lhs.value == rhs.value
            }
        }

        public var name: String {
            get {
                return self.storage.name
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.name = newValue
            }
        }

        public var value: String {
            get {
                return self.storage.value
            }
            set {
                self.copyStorageIfNotUniquelyReferenced()
                self.storage.value = newValue
            }
        }

        /// The file and line where the error was created.
        public var location: String {
            get {
                return self.storage.location
            }
        }

        public var description: String {
            return "ForbiddenHeaderField(name: \(self.name), value: \(self.value), location: \(self.location))"
        }

        @available(*, deprecated, renamed: "forbiddenHeaderField")
        public init(name: String, value: String) {
            self.init(name: name, value: value, file: #file, line: #line)
        }

        fileprivate init(name: String, value: String, file: String, line: UInt) {
            self.storage = Storage(name: name, value: value, file: file, line: line)
        }
    }

    /// A request or response has violated the expected content length, either exceeding or falling beneath it.
    public struct ContentLengthViolated: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "contentLengthViolated")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: ContentLengthViolated, rhs: ContentLengthViolated) -> Bool {
            return true
        }
    }

    /// The remote peer has sent an excessive number of empty DATA frames, which looks like a denial of service
    /// attempt, so the connection has been closed.
    public struct ExcessiveEmptyDataFrames: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "excessiveEmptyDataFrames")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: ExcessiveEmptyDataFrames, rhs: ExcessiveEmptyDataFrames) -> Bool {
            return true
        }
    }

    /// The remote peer has sent a header block so large that NIO refuses to buffer any more data than that.
    public struct ExcessivelyLargeHeaderBlock: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "excessivelyLargeHeaderBlock")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: ExcessivelyLargeHeaderBlock, rhs: ExcessivelyLargeHeaderBlock) -> Bool {
            return true
        }
    }

    /// The channel does not yet have a stream ID, as it has not reached the network yet.
    public struct NoStreamIDAvailable: NIOHTTP2Error {
        private let file: String
        private let line: UInt

        /// The location where the error was thrown.
        public var location: String {
            return _location(file: self.file, line: self.line)
        }

        @available(*, deprecated, renamed: "noStreamIDAvailable")
        public init() {
            self.init(file: #file, line: #line)
        }

        fileprivate init(file: String, line: UInt) {
            self.file = file
            self.line = line
        }

        public static func ==(lhs: NoStreamIDAvailable, rhs: NoStreamIDAvailable) -> Bool {
            return true
        }
    }
}


/// This enum covers errors that are thrown internally for messaging reasons. These should
/// not leak.
internal enum InternalError: Error {
    case attemptedToCreateStream

    case codecError(code: HTTP2ErrorCode)
}

extension InternalError: Hashable { }

private func _location(file: String, line: UInt) -> String {
    return "\(file):\(line)"
}

private final class StringAndLocationStorage: Equatable {
    var value: String
    var file: String
    var line: UInt

    var location: String {
        return _location(file: self.file, line: self.line)
    }

    init(_ value: String, file: String, line: UInt) {
        self.value = value
        self.file = file
        self.line = line
    }

    func copy() -> StringAndLocationStorage {
        return StringAndLocationStorage(self.value, file: self.file, line: self.line)
    }

    static func ==(lhs: StringAndLocationStorage, rhs: StringAndLocationStorage) -> Bool {
        // Only compare the value. The 'file' is not relevant here.
        return lhs.value == rhs.value
    }
}
