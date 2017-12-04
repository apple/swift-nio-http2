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

/// The global nghttp2 frame receive callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift class in order to dispatch the frame for
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

    init(mode: Mode) {
        var session: OpaquePointer?
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

    /// Called whenever nghttp2 receives a frame.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onFrameReceiveCallback(frame: UnsafePointer<nghttp2_frame>) throws {
        return
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
        return
    }

    /// Called when a header name+value pair has been decoded.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onHeaderCallback(frame: UnsafePointer<nghttp2_frame>,
                                      name: UnsafeBufferPointer<UInt8>,
                                      value: UnsafeBufferPointer<UInt8>,
                                      flags: UInt8) throws {
        return
    }

    deinit {
        nghttp2_session_del(session)
    }
}
