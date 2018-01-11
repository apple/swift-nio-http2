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

import NIO
import NIOHTTP1
import CNIONghttp2

/// A helper function that manages the lifetime of a pointer to an `nghttp2_option` structure.
private func withSessionOptions<T>(fn: (OpaquePointer) throws -> T) rethrows -> T {
    var optionPtr: OpaquePointer?
    let rc = nghttp2_option_new(&optionPtr)
    precondition(rc == 0 && optionPtr != nil, "Initialization of nghttp2 options failed")
    defer {
        nghttp2_option_del(optionPtr)
    }

    // Disable auto window updates, and provide an initial
    // default outbound concurrent stream limit of 100.
    nghttp2_option_set_no_auto_window_update(optionPtr, 1)
    nghttp2_option_set_peer_max_concurrent_streams(optionPtr, 100)
    return try fn(optionPtr!)
}

/// A helper function that manages the lifetime of a pointer to an `nghttp2_session_callbacks` structure.
private func withCallbacks<T>(fn: (OpaquePointer) throws -> T) rethrows -> T {
    var nghttp2Callbacks: OpaquePointer?
    nghttp2_session_callbacks_new(&nghttp2Callbacks)
    precondition(nghttp2Callbacks != nil, "Unable to allocate nghttp2 callbacks structure")
    defer {
        nghttp2_session_callbacks_del(nghttp2Callbacks)
    }

    nghttp2_session_callbacks_set_error_callback(nghttp2Callbacks, errorCallback)
    nghttp2_session_callbacks_set_on_frame_recv_callback(nghttp2Callbacks, onFrameRecvCallback)
    nghttp2_session_callbacks_set_on_begin_frame_callback(nghttp2Callbacks, onBeginFrameCallback)
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(nghttp2Callbacks, onDataChunkRecvCallback)
    nghttp2_session_callbacks_set_on_stream_close_callback(nghttp2Callbacks, onStreamCloseCallback)
    nghttp2_session_callbacks_set_on_begin_headers_callback(nghttp2Callbacks, onBeginHeadersCallback)
    nghttp2_session_callbacks_set_on_header_callback(nghttp2Callbacks, onHeaderCallback)
    return try fn(nghttp2Callbacks!)
}

private func evacuateSession(_ userData: UnsafeMutableRawPointer) -> NGHTTP2Session {
    return Unmanaged.fromOpaque(userData).takeUnretainedValue()
}

/// The global nghttp2 error callback.
///
/// In this early version of the codebase, this callback defaults to just calling print().
private func errorCallback(session: OpaquePointer?, msg: UnsafePointer<CChar>?, len: Int, userData: UnsafeMutableRawPointer?) -> Int32 {
    let errorString = msg != nil ? String(cString: msg!) : ""
    print("nghttp2 error: \(errorString)")
    return 0
}

/// The global nghttp2 frame begin callback.
///
/// Responsible for recording the frame's type etc.
private func onBeginFrameCallback(session: OpaquePointer?, frameHeader: UnsafePointer<nghttp2_frame_hd>?, userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let frameHeader = frameHeader, let userData = userData else {
        fatalError("Invalid pointers provided to onBeginFrameCallback")
    }

    let nioSession = evacuateSession(userData)
    do {
        try nioSession.onBeginFrameCallback(frameHeader: frameHeader)
        return 0
    } catch {
        return NGHTTP2_ERR_CALLBACK_FAILURE.rawValue
    }
}

/// The global nghttp2 frame receive callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift value in order to dispatch the frame for
/// further processing.
private func onFrameRecvCallback(session: OpaquePointer?, frame: UnsafePointer<nghttp2_frame>?, userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let frame = frame, let userData = userData else {
        fatalError("Invalid pointers provided to onFrameRecvCallback")
    }

    let nioSession = evacuateSession(userData)
    do {
        try nioSession.onFrameReceiveCallback(frame: frame)
        return 0
    } catch {
        return NGHTTP2_ERR_CALLBACK_FAILURE.rawValue
    }
}

/// The global nghttp2 data chunk receive callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift class in order to dispatch the data
/// for further processing. Also responsible for converting pointers + length into buffer pointers for ease of use.
private func onDataChunkRecvCallback(session: OpaquePointer?,
                                     flags: UInt8,
                                     streamID: Int32,
                                     data: UnsafePointer<UInt8>?,
                                     len: Int,
                                     userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let data = data, let userData = userData else {
        fatalError("Invalid pointers provided to onDataChunkRecvCallback")
    }
    let dataBufferPointer = UnsafeBufferPointer(start: data, count: len)

    let nioSession = evacuateSession(userData)
    do {
        try nioSession.onDataChunkRecvCallback(flags: flags, streamID: streamID, data: dataBufferPointer)
        return 0
    } catch {
        return NGHTTP2_ERR_CALLBACK_FAILURE.rawValue
    }
}

/// The global nghttp2 stream close callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift class in order to dispatch the error
/// for further processing.
private func onStreamCloseCallback(session: OpaquePointer?, streamID: Int32, errorCode: UInt32, userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let userData = userData else {
        fatalError("Invalid pointer provided to onStreamCloseCallback")
    }

    let nioSession = evacuateSession(userData)
    do {
        try nioSession.onStreamCloseCallback(streamID: streamID, errorCode: errorCode)
        return 0
    } catch {
        return NGHTTP2_ERR_CALLBACK_FAILURE.rawValue
    }
}

/// The global nghttp2 begin headers callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift class in order to dispatch the frame
/// for further processing.
private func onBeginHeadersCallback(session: OpaquePointer?, frame: UnsafePointer<nghttp2_frame>?, userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let userData = userData, let frame = frame else {
        fatalError("Invalid pointers provided to onBeginHeadersCallback")
    }

    let nioSession = evacuateSession(userData)
    do {
        try nioSession.onBeginHeadersCallback(frame: frame)
        return 0
    } catch {
        return NGHTTP2_ERR_CALLBACK_FAILURE.rawValue
    }
}

/// The global nghttp2 per-header callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift class in order to dispatch the headers
/// for further processing. Also responsible for converting pointers + length into buffer pointers for ease of use.
private func onHeaderCallback(session: OpaquePointer?,
                              frame: UnsafePointer<nghttp2_frame>?,
                              name: UnsafePointer<UInt8>?,
                              nameLen: Int,
                              value: UnsafePointer<UInt8>?,
                              valueLen: Int,
                              flags: UInt8,
                              userData: UnsafeMutableRawPointer?) -> Int32 {
    guard let frame = frame, let name = name, let value = value, let userData = userData else {
        fatalError("Invalid pointers provided to onHeaderCallback")
    }
    let nameBufferPointer = UnsafeBufferPointer(start: name, count: nameLen)
    let valueBufferPointer = UnsafeBufferPointer(start: value, count: valueLen)

    let nioSession = evacuateSession(userData)
    do {
        try nioSession.onHeaderCallback(frame: frame, name: nameBufferPointer, value: valueBufferPointer, flags: flags)
        return 0
    } catch {
        return NGHTTP2_ERR_CALLBACK_FAILURE.rawValue
    }
}

public struct HTTP2Frame {
    public var header: FrameHeader
    public var payload: FramePayload

    public struct FrameHeader {
        var storage: nghttp2_frame_hd
        public var flags: UInt8 {
            return self.storage.flags
        }
        public var streamID: Int32 {
            return self.storage.stream_id
        }
    }

    public enum FramePayload {
        case data
        case headers(HTTP2HeadersCategory, HTTPHeaders)
        case priority
        case rstStream
        case settings([(Int32, UInt32)])
        case pushPromise
        case ping
        case goAway
        case windowUpdate(windowSizeIncrement: Int)
        case continuation
        case alternativeService
    }
}

public enum HTTP2HeadersCategory {
    case request
    case response
    case pushResponse
    case headers
}

extension nghttp2_headers_category {
    init(headersCategory: HTTP2HeadersCategory) {
        switch headersCategory {
        case .request:
            self = NGHTTP2_HCAT_REQUEST
        case .response:
            self = NGHTTP2_HCAT_RESPONSE
        case .pushResponse:
            self = NGHTTP2_HCAT_PUSH_RESPONSE
        case .headers:
            self = NGHTTP2_HCAT_HEADERS
        }
    }
}

extension HTTPHeaders {
    func withNGHTTP2Headers(allocator: ByteBufferAllocator,
                            headersCategory: HTTP2HeadersCategory,
                            headers: HTTPHeaders,
                            _ body: (UnsafePointer<nghttp2_priority_spec>, UnsafePointer<nghttp2_nv>, Int) -> Void) {
        var bla: [nghttp2_nv] = []
        var allHeaderStorage: ByteBuffer = allocator.buffer(capacity: 1024)
        var allHeadersIndices: [(Int, Int, Int, Int)] = []
        bla.reserveCapacity(headers.underestimatedCount)
        for header in headers {
            let headerNameBegin = allHeaderStorage.writerIndex
            let headerNameLen = allHeaderStorage.write(string: header.name)!
            let headerValueBegin = allHeaderStorage.writerIndex
            let headerValueLen = allHeaderStorage.write(string: header.value)!
            allHeadersIndices.append((headerNameBegin, headerNameLen, headerValueBegin, headerValueLen))
        }
        var nghttpNVs: [nghttp2_nv] = []
        nghttpNVs.reserveCapacity(allHeadersIndices.count)
        allHeaderStorage.withUnsafeMutableReadableBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for (hnBegin, hnLen, hvBegin, hvLen) in allHeadersIndices {
                nghttpNVs.append(nghttp2_nv(name: base + hnBegin,
                                            value: base + hvBegin,
                                            namelen: hnLen,
                                            valuelen: hvLen,
                                            flags: 0))
            }
            nghttpNVs.withUnsafeMutableBufferPointer { ptr in
                var prio = nghttp2_priority_spec()
                nghttp2_priority_spec_default_init(&prio)
                body(&prio, ptr.baseAddress!, ptr.count)
            }
        }
    }
}

private extension HTTPHeaders {
    init(nghttp2Headers: nghttp2_headers) {
        var headers: [(String, String)] = []
        headers.reserveCapacity(nghttp2Headers.nvlen)

        for idx in 0..<nghttp2Headers.nvlen {
            let nva = nghttp2Headers.nva[idx]
            let namePtr = UnsafeBufferPointer<UInt8>(start: nva.name, count: nva.namelen)
            let valuePtr = UnsafeBufferPointer<UInt8>(start: nva.value, count: nva.valuelen)
            headers.append((String(decoding: namePtr, as: UTF8.self), String(decoding: valuePtr, as: UTF8.self)))
        }

        self = HTTPHeaders(headers)
    }
}

private extension HTTP2Frame.FrameHeader {
    init(nghttp2FrameHeader: nghttp2_frame_hd) {
        self.storage = nghttp2FrameHeader
    }
}


/// An object that wraps a single nghttp2 session object.
///
/// Each HTTP/2 connection is represented inside nghttp2 by using a `nghttp2_session` object. This
/// object is represented in C by a pointer to an opaque structure, which is safe to use from only
/// one thread. In order to manage the initialization state of this structure, we wrap it in a
/// Swift class that can be used to ensure that the `nghttp2_session` object has its lifetime
/// managed appropriately.
class NGHTTP2Session {
    /// The mode of operation used by this connection: client or server.
    enum Mode {
        case server
    }

    /// The reference to the nghttp2 session.
    ///
    /// Sadly, this has to be an implicitly-unwrapped-optional, even though this can never
    /// really be nil. That's because nghttp2 requires that we pass our user data pointer
    /// when we construct the `nghttp2_session`, which we want to do during initialization. The only
    /// way Swift will let us do that is if it thinks we're fully initialized, which if this was
    /// non-option we can only be *after* we have got the pointer to the `nghttp2_session`. This
    /// chicken-and-egg issue can be resolved only by allowing this reference to be nil.
    private var session: OpaquePointer! = nil

    private var frameHeader: nghttp2_frame_hd! = nil

    public var frameReceivedHandler: (HTTP2Frame) -> Void

    public var headersAccumulation: HTTPHeaders! = nil

    init(mode: Mode, frameReceivedHandler: @escaping (HTTP2Frame) -> Void) {
        var session: OpaquePointer?
        self.frameReceivedHandler = frameReceivedHandler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let rc: Int32 = withCallbacks { nghttp2Callbacks in
            return withSessionOptions { options in
                switch mode {
                case .server:
                    return nghttp2_session_server_new2(&session, nghttp2Callbacks, selfPtr, options)
                }
            }
        }
        precondition(rc == 0 && session != nil, "Failed to initialize nghttp2 session")
        self.session = session
    }

    fileprivate func onBeginFrameCallback(frameHeader: UnsafePointer<nghttp2_frame_hd>) throws {
        self.frameHeader = frameHeader.pointee
        return
    }

    /// Called whenever nghttp2 receives a frame.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onFrameReceiveCallback(frame: UnsafePointer<nghttp2_frame>) throws {
        let frame = frame.pointee
        let nioFramePayload: HTTP2Frame.FramePayload
        let nioFrameHeader = HTTP2Frame.FrameHeader(nghttp2FrameHeader: frame.data.hd)
        switch UInt32(frame.data.hd.type) {
        case NGHTTP2_DATA.rawValue:
            nioFramePayload = .data
        case NGHTTP2_HEADERS.rawValue:
            nioFramePayload = .headers(.request, self.headersAccumulation)
        case NGHTTP2_PRIORITY.rawValue:
            nioFramePayload = .priority
        case NGHTTP2_RST_STREAM.rawValue:
            nioFramePayload = .rstStream
        case NGHTTP2_SETTINGS.rawValue:
            var settings: [(Int32, UInt32)] = []
            settings.reserveCapacity(frame.settings.niv)
            for idx in 0..<frame.settings.niv {
                let iv = frame.settings.iv[idx]
                settings.append((iv.settings_id, iv.value))
            }
            nioFramePayload = .settings(settings)
        case NGHTTP2_PUSH_PROMISE.rawValue:
            nioFramePayload = .pushPromise
        case NGHTTP2_PING.rawValue:
            nioFramePayload = .ping
        case NGHTTP2_GOAWAY.rawValue:
            nioFramePayload = .goAway
        case NGHTTP2_WINDOW_UPDATE.rawValue:
            nioFramePayload = .windowUpdate(windowSizeIncrement: Int(frame.window_update.window_size_increment))
        case NGHTTP2_CONTINUATION.rawValue:
            nioFramePayload = .continuation
        default:
            fatalError("unrecognised HTTP/2 frame type \(self.frameHeader.type) received")
        }

        let nioFrame = HTTP2Frame(header: nioFrameHeader,
                                     payload: nioFramePayload)
        self.frameReceivedHandler(nioFrame)
    }

    /// Called whenever nghttp2 receives a chunk of data from a data frame.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onDataChunkRecvCallback(flags: UInt8, streamID: Int32, data: UnsafeBufferPointer<UInt8>) throws {
        return
    }

    /// Called when the stream `streamID` is closed.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onStreamCloseCallback(streamID: Int32, errorCode: UInt32) throws {
        return
    }

    /// Called when the reception of a HEADERS or PUSH_PROMISE frame is started. Does not contain
    /// any of the header pairs themselves.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onBeginHeadersCallback(frame: UnsafePointer<nghttp2_frame>) throws {
        self.headersAccumulation = HTTPHeaders()
        return
    }

    /// Called when a header name+value pair has been decoded.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onHeaderCallback(frame: UnsafePointer<nghttp2_frame>,
                                      name: UnsafeBufferPointer<UInt8>,
                                      value: UnsafeBufferPointer<UInt8>,
                                      flags: UInt8) throws {
        self.headersAccumulation.add(name: String(decoding: name, as: UTF8.self),
                                     value: String(decoding: value, as: UTF8.self))
    }

    public func feedInput(buffer: inout ByteBuffer) {
        buffer.withUnsafeReadableBytes { data in
            switch nghttp2_session_mem_recv(self.session, data.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count) {
            case let x where x >= 0:
                ()
            case Int(NGHTTP2_ERR_NOMEM.rawValue):
                fatalError("out of memory")
            case let x:
                fatalError("error \(x)")
            }
        }
    }

    public func feedOutput(allocator: ByteBufferAllocator, streamID: Int32, buffer: HTTP2Frame.FramePayload) {
        switch buffer {
        case .data:
            fatalError("not implemented")
        case .headers(let headersCategory, let headers):
            headers.withNGHTTP2Headers(allocator: allocator,
                                    headersCategory: headersCategory,
                                    headers: headers) { a, b, c in
                                        nghttp2_submit_headers(self.session,
                                                               0,
                                                               streamID,
                                                               a,
                                                               b,
                                                               c,
                                                               nil)
            }
        case .priority:
            fatalError("not implemented")
        case .rstStream:
            fatalError("not implemented")
        case .settings(_):
            // FIXME this does nothing
            nghttp2_submit_settings(self.session, 0, nil, 0)
            //fatalError("not implemented")
        case .pushPromise:
            fatalError("not implemented")
        case .ping:
            fatalError("not implemented")
        case .goAway:
            fatalError("not implemented")
        case .windowUpdate(let windowSizeIncrement):
            fatalError("not implemented")
        case .continuation:
            fatalError("not implemented")
        case .alternativeService:
            fatalError("not implemented")
        }

    }

    public func send(allocator: ByteBufferAllocator, flushFunction: () -> Void,  _ sendFunction: (ByteBuffer) -> Void) {
        var data: UnsafePointer<UInt8>? = nil
        while true {
            let length = nghttp2_session_mem_send(self.session, &data)
            guard length != 0 else {
                break
            }
            var buffer = allocator.buffer(capacity: length)
            buffer.write(bytes: UnsafeBufferPointer(start: data, count: length))
            sendFunction(buffer)
        }
        flushFunction()
    }

    deinit {
        nghttp2_session_del(session)
    }
}
