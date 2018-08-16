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

    // Provide an initial default outbound concurrent stream limit of 100.
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
    nghttp2_session_callbacks_set_send_data_callback(nghttp2Callbacks, sendDataCallback)
    nghttp2_session_callbacks_set_on_frame_send_callback(nghttp2Callbacks, onFrameSendCallback)
    nghttp2_session_callbacks_set_on_frame_not_send_callback(nghttp2Callbacks, onFrameNotSentCallback)
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

/// The global nghttp2 send-data callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift class in order to dispatch the DATA
/// frame down the channel pipeline. Also responsible for converting pointers + length into buffer pointers for ease of use.
private func sendDataCallback(session: OpaquePointer?,
                              frame: UnsafeMutablePointer<nghttp2_frame>?,
                              frameHeader: UnsafePointer<UInt8>?,
                              length: Int,
                              source: UnsafeMutablePointer<nghttp2_data_source>?,
                              userData: UnsafeMutableRawPointer?) -> CInt {
    guard let frame = frame, let frameHeader = frameHeader, let source = source, let userData = userData else {
        preconditionFailure("Invalid pointers provided to sendDataCallback")
    }
    let frameHeaderBufferPointer = UnsafeBufferPointer(start: frameHeader, count: 9)

    let nioSession = evacuateSession(userData)
    nioSession.sendDataCallback(frame: frame, frameHeader: frameHeaderBufferPointer, source: source)
    return 0
}

/// The global nghttp2 on-frame-send callback.
///
/// Responsible for sanity-checking inputs and converting the user-data into a Swift class in order to notify the session about a frame
/// send.
private func onFrameSendCallback(session: OpaquePointer?, frame: UnsafePointer<nghttp2_frame>?, userData: UnsafeMutableRawPointer?) -> CInt {
    guard let frame = frame, let userData = userData else {
        preconditionFailure("Invalid pointers provided to onFrameSendCallback")
    }

    let nioSession = evacuateSession(userData)
    nioSession.onFrameSendCallback(frame: frame)
    return 0
}

private func onFrameNotSentCallback(session: OpaquePointer?,
                                    frame: UnsafePointer<nghttp2_frame>?,
                                    errorCode: CInt,
                                    userData: UnsafeMutableRawPointer?) -> CInt {
    // TODO(cory): Report the errors.
    precondition(errorCode == 0)
    return 0
}


/// This struct exists to work around an annoying problem with stream data when using nghttp2,
/// which is that we need to have a structure but nghttp2 doesn't give us anywhere nice to hang
/// it. We also need to keep track of stream IDs that we may have seen in the past, in case they
/// reappear.
///
/// This is because of the need to use `HTTP2StreamID`, a type that makes me quite
/// unhappy in its current form. In general we attempt to obtain the stream ID from nghttp2
/// directly by asking for the `HTTP2Stream` object, but it is occasionally possible that
/// we need to obtain a stream ID for a stream that is long gone (e.g. for RST_STREAM or
/// GOAWAY purposes). This structure maintains a map that allows us to resurrect these as needed.
fileprivate struct StreamManager {
    /// The map of streams from their network stream ID.
    ///
    /// This map contains two types of stream IDs. The first are stream IDs for streams that
    /// are no longer active. The second are two special sentinel values, for the root stream
    /// and the highest numbered stream ID.
    private var streamMap: [Int32: HTTP2Stream]

    /// The maximum size of the cache.
    private let maxSize: Int

    /// The parser mode for this connection.
    private let mode: HTTP2Parser.ParserMode

    fileprivate init(mode: HTTP2Parser.ParserMode, maxSize: Int) {
        self.maxSize = maxSize
        self.mode = mode
        self.streamMap = [0: HTTP2Stream(mode: mode, streamID: .rootStream), Int32.max: HTTP2Stream(mode: mode, streamID: .maxID)]
    }

    /// Obtains the NIO stream data for a given stream, or nil if NIO doesn't know about this stream.
    public func getStreamData(for streamID: Int32) -> HTTP2Stream? {
        return self.streamMap[streamID]
    }

    /// Creates stream data for a given stream.
    mutating func createStreamData(for streamID: Int32) -> HTTP2Stream {
        self.purgeOldStreams()
        let streamData = HTTP2Stream(mode: self.mode, streamID: HTTP2StreamID(knownID: streamID))
        self.streamMap[streamID] = streamData
        return streamData
    }

    /// Creates stream data for a given stream with an internal stream ID.
    mutating func createStreamData(for internalStreamID: HTTP2StreamID) -> HTTP2Stream {
        self.purgeOldStreams()
        let streamData = HTTP2Stream(mode: self.mode, streamID: internalStreamID)
        self.streamMap[internalStreamID.networkStreamID!] = streamData
        return streamData
    }

    // Discard old and unnecessary streams.
    private mutating func purgeOldStreams() {
        // If the stream map is not full, we don't purge.
        guard self.streamMap.count >= self.maxSize else { return }

        // It's full, time to purge some entries.
        var purgeableStreamIDIterator = self.streamMap.lazy.filter { entry in
            if entry.key == 0 || entry.key == Int32.max {
                // Exclude the streams with max or min stream IDs.
                return false
            }

            // We only want inactive streams.
            return !entry.value.active
        }.map { $0.key }.sorted().makeIterator()

        while self.streamMap.count >= maxSize, let toPurge = purgeableStreamIDIterator.next() {
            self.streamMap.removeValue(forKey: toPurge)
        }
    }
}

// MARK:- An extension to the HTTP/2 headers struct to check if this is an informational response.
private extension nghttp2_headers {
    /// Whether this header block is an informational response.
    var isInformationalResponse: Bool {
        guard self.nvlen > 0 else {
            return false
        }

        // TODO(cory): This is very slow (creating Strings here), but it's part and parcel of the
        // slowness nghttp2 forces on us so let's just do it safely for now.
        let name = String(decoding: UnsafeBufferPointer(start: self.nva.pointee.name, count: self.nva.pointee.namelen), as: UTF8.self)
        guard name == ":status" else {
            return false
        }

        let value = String(decoding: UnsafeBufferPointer(start: self.nva.pointee.value, count: self.nva.pointee.valuelen), as: UTF8.self)
        return value.starts(with: "1")
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

    /// An internal buffer used to accumulate the body of DATA frames.
    private var dataAccumulation: ByteBuffer

    /// Access to an allocator for use during frame callbacks.
    private let allocator: ByteBufferAllocator

    /// The mode of this session: client or server.
    private let mode: HTTP2Parser.ParserMode

    /// A small byte-buffer used to write DATA frame headers into.
    ///
    /// In many cases this will trigger a CoW (as most flushes will write more than one DATA
    /// frame), so we allocate a new small buffer for this rather than use one of the other buffers
    /// we have lying around. That shrinks the allocation sizes and allows us to use clear() rather
    /// than slicing and potentially triggering copies of the entire buffer for no good reason.
    private var dataFrameHeaderBuffer: ByteBuffer

    /// The callback passed by the parent object, to call each time we need to send some data.
    ///
    /// This is expected to have similar semantics to `Channel.write`: that is, it does not trigger I/O
    /// directly. This can safely be called at any time, including when reads have been fed to the code.
    private let sendFunction: (IOData, EventLoopPromise<Void>?) -> Void

    /// The callback passed by the parent object to call each time we want to send a user event.
    private let userEventFunction: (Any) -> Void

    // TODO(cory): This is not really sufficient, we need to introspect nghttp2, but it is enough for now.
    private var closed: Bool = false

    private var streamIDManager: StreamManager

    init(mode: HTTP2Parser.ParserMode,
         allocator: ByteBufferAllocator,
         maxCachedStreamIDs: Int,
         frameReceivedHandler: @escaping (HTTP2Frame) -> Void,
         sendFunction: @escaping (IOData, EventLoopPromise<Void>?) -> Void,
         userEventFunction: @escaping (Any) -> Void) {
        var session: OpaquePointer?
        self.frameReceivedHandler = frameReceivedHandler
        self.sendFunction = sendFunction
        self.userEventFunction = userEventFunction
        self.allocator = allocator
        self.mode = mode
        self.streamIDManager = StreamManager(mode: self.mode, maxSize: maxCachedStreamIDs)

        // TODO(cory): We should make MAX_FRAME_SIZE configurable and use that, rather than hardcode
        // that value here.
        self.dataAccumulation = allocator.buffer(capacity: 16384)  // 2 ^ 14

        // 9 is the size of the serialized frame header, excluding the padding byte, which we never set.
        self.dataFrameHeaderBuffer = allocator.buffer(capacity: 9)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let rc: Int32 = withCallbacks { nghttp2Callbacks in
            return withSessionOptions { options in
                switch mode {
                case .server:
                    return nghttp2_session_server_new2(&session, nghttp2Callbacks, selfPtr, options)
                case .client:
                    return nghttp2_session_client_new2(&session, nghttp2Callbacks, selfPtr, options)
                }
            }
        }
        precondition(rc == 0 && session != nil, "Failed to initialize nghttp2 session")
        self.session = session
    }

    fileprivate func onBeginFrameCallback(frameHeader: UnsafePointer<nghttp2_frame_hd>) throws {
        let frameHeader = frameHeader.pointee
        if frameHeader.type == NGHTTP2_DATA.rawValue {
            // We need this buffer now: we delayed this potentially CoW operation as long
            // as we could.
            self.dataAccumulation.clear()
        }
        return
    }

    /// Called whenever nghttp2 receives a frame.
    ///
    /// In this early version of the codebase, this function does nothing.
    fileprivate func onFrameReceiveCallback(frame: UnsafePointer<nghttp2_frame>) throws {
        let frame = frame.pointee
        let nioFramePayload: HTTP2Frame.FramePayload
        switch UInt32(frame.hd.type) {
        case NGHTTP2_DATA.rawValue:
            // TODO(cory): Should we slice here? It will reduce the cost of a CoW initiated
            // by the remote peer if the data frame is much smaller than this buffer.
            nioFramePayload = .data(.byteBuffer(self.dataAccumulation))
        case NGHTTP2_HEADERS.rawValue:
            nioFramePayload = .headers(self.headersAccumulation)

            /// If we are a server, the first headers frame on a new stream should cause us to create our stream state and store it.
            if case .server = self.mode, frame.headers.cat == NGHTTP2_HCAT_REQUEST {
                let streamState = self.streamIDManager.createStreamData(for: frame.hd.stream_id)
                streamState.active = true
            }
        case NGHTTP2_PRIORITY.rawValue:
            // we explicitly suppress priority frames at this time.
            return
        case NGHTTP2_RST_STREAM.rawValue:
            nioFramePayload = .rstStream(HTTP2ErrorCode(frame.rst_stream.error_code))
        case NGHTTP2_SETTINGS.rawValue:
            var settings: [HTTP2Setting] = []
            settings.reserveCapacity(frame.settings.niv)
            for idx in 0..<frame.settings.niv {
                let iv = frame.settings.iv[idx]
                settings.append(HTTP2Setting(fromNghttp2: iv))
            }
            nioFramePayload = .settings(settings)
        case NGHTTP2_PUSH_PROMISE.rawValue:
            nioFramePayload = .pushPromise
        case NGHTTP2_PING.rawValue:
            nioFramePayload = .ping(HTTP2PingData(withTuple: frame.ping.opaque_data))
        case NGHTTP2_GOAWAY.rawValue:
            let frameData = frame.goaway
            let opaqueData = frameData.opaque_data_len > 0 ? self.allocator.buffer(containingCopyOf: UnsafeBufferPointer(start: frameData.opaque_data, count: frameData.opaque_data_len)) : nil
            guard let lastStreamID = self.streamIDManager.getStreamData(for: frameData.last_stream_id)?.streamID else {
                // TODO(cory): This should probably report the error some other way.
                preconditionFailure("Could not find stream ID")
            }
            let errorCode = HTTP2ErrorCode(frameData.error_code)
            nioFramePayload = .goAway(lastStreamID: lastStreamID, errorCode: errorCode, opaqueData: opaqueData)
        case NGHTTP2_WINDOW_UPDATE.rawValue:
            nioFramePayload = .windowUpdate(windowSizeIncrement: Int(frame.window_update.window_size_increment))
        default:
            fatalError("unrecognised HTTP/2 frame type \(self.frameHeader.type) received")
        }

        let streamID = self.streamIDManager.getStreamData(for: frame.hd.stream_id)!.streamID
        let nioFrame = HTTP2Frame(streamID: streamID, flags: frame.hd.flags, payload: nioFramePayload)
        self.frameReceivedHandler(nioFrame)

        // We can now clear our internal state, ready for another frame.
        self.headersAccumulation = nil
    }

    /// Called whenever nghttp2 receives a chunk of data from a data frame.
    fileprivate func onDataChunkRecvCallback(flags: UInt8, streamID: Int32, data: UnsafeBufferPointer<UInt8>) throws {
        self.dataAccumulation.write(bytes: data)
    }

    /// Called when the stream `streamID` is closed.
    fileprivate func onStreamCloseCallback(streamID: Int32, errorCode: UInt32) throws {
        let streamData = self.streamIDManager.getStreamData(for: streamID)!

        // If we have a data provider, pull it out.
        let error = NIOHTTP2Errors.StreamClosed(streamID: streamData.streamID,
                                                errorCode: HTTP2ErrorCode(errorCode))

        // Retire the stream data: it should not be used again.
        streamData.active = false

        // Now we can call out. We fail pending writes and fire a user event.
        streamData.dataProvider.failAllWrites(error: error)
        let reason = error.errorCode == .noError ? nil : error.errorCode
        self.userEventFunction(StreamClosedEvent(streamID: streamData.streamID, reason: reason))
    }

    /// Called when the reception of a HEADERS or PUSH_PROMISE frame is started. Does not contain
    /// any of the header pairs themselves.
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

    /// Called when nghttp2 wants us to send a data frame with pass-through data.
    ///
    /// nghttp2's "send a buffer of bytes" code is sufficiently complex that it's basically just as easy
    /// for us to do "pass-through" writes (that is, writes where we send the body of the data frame on
    /// directly rather than copy it into nghttp2) as it is for us to copy the data into nghttp2's
    /// buffers. This function is called when we've told nghttp2 that we're going to pass a write
    /// through.
    ///
    /// This function needs to write the frame header, optional padding byte, frame body, and then
    /// any padding that may be needed. We never send any padding in this early build, so this code
    /// is very simple.
    fileprivate func sendDataCallback(frame: UnsafeMutablePointer<nghttp2_frame>,
                                      frameHeader: UnsafeBufferPointer<UInt8>,
                                      source: UnsafeMutablePointer<nghttp2_data_source>) {
        precondition(frame.pointee.data.padlen == 0, "unexpected padding in DATA frame")
        self.dataFrameHeaderBuffer.clear()
        self.dataFrameHeaderBuffer.write(bytes: frameHeader)
        self.sendFunction(.byteBuffer(self.dataFrameHeaderBuffer), nil)

        let provider = Unmanaged<HTTP2DataProvider>.fromOpaque(source.pointee.ptr!).takeUnretainedValue()
        provider.forWriteInDataFrame { body, promise in
            self.sendFunction(body, promise)
        }
    }

    /// Called when nghttp2 has just sent a frame.
    ///
    /// We hook this function expressly to make sure that we queue up the sending of DATA frames once the header
    /// frame for a given stream has been emitted. This is a frankly insane way to do things, but it's the only
    /// way to replicate the behaviour of `nghttp2_submit_request` while still being able to choose the stream ID
    /// for the new stream.
    ///
    /// All this method does is check to see whether the frame is a HEADERS or CONTINUATION frame with END_HEADERS
    /// set and, if it is, queues up the sending of DATA frames for that stream.
    fileprivate func onFrameSendCallback(frame: UnsafePointer<nghttp2_frame>) {
        let frameType = frame.pointee.hd.type
        guard frameType == NGHTTP2_HEADERS.rawValue || frameType == NGHTTP2_CONTINUATION.rawValue else {
            return
        }

        // Next, check for END_HEADERS flag. If END_HEADERS is set, but END_STREAM is not, we are expecting some data.=
        let flags = UInt32(frame.pointee.hd.flags)
        guard (flags & NGHTTP2_FLAG_END_HEADERS.rawValue) != 0 && (flags & NGHTTP2_FLAG_END_STREAM.rawValue) == 0 else {
            return
        }

        // Next, check if this is an informational response block. If it is, we have more HEADERS frames inbound, we can't
        // attach our data provider now.
        if frame.pointee.headers.isInformationalResponse {
            return
        }

        // Ok, there's some data to send. Grab the provider.
        // TODO(cory): Don't force-unwrap this.
        let provider = self.streamIDManager.getStreamData(for: frame.pointee.hd.stream_id)!.dataProvider
        var nghttp2Provider = provider.nghttp2DataProvider
        precondition(provider.state == .idle)

        // Submit the data. We always submit END_STREAM: nghttp2 will work out when to actually fire it.
        let rc = nghttp2_submit_data(self.session, UInt8(NGHTTP2_FLAG_END_STREAM.rawValue), frame.pointee.hd.stream_id, &nghttp2Provider)
        precondition(rc == 0)
    }

    public func feedInput(buffer: inout ByteBuffer) throws {
        try buffer.withUnsafeReadableBytes { data in
            switch nghttp2_session_mem_recv(self.session, data.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count) {
            case let x where x >= 0:
                precondition(x == data.count, "did not consume all bytes")
            case Int(NGHTTP2_ERR_NOMEM.rawValue):
                fatalError("out of memory")
            case Int(NGHTTP2_ERR_BAD_CLIENT_MAGIC.rawValue):
                throw NIOHTTP2Errors.BadClientMagic()
            case let nghttp2ErrorCode:
                throw NIOHTTP2Errors.InternalError(nghttp2ErrorCode: nghttp2_error(rawValue: Int32(nghttp2ErrorCode)))
            }
        }
    }

    public func feedOutput(frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        if self.closed {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        
        switch frame.payload {
        case .data:
            self.writeDataToStream(frame: frame, promise: promise)
        case .headers:
            self.sendHeaders(frame: frame)
        case .priority:
            fatalError("not implemented")
        case .rstStream:
            self.sendRstStream(frame: frame)
        case .settings:
            self.sendSettings(frame: frame)
        case .pushPromise:
            fatalError("not implemented")
        case .ping:
            self.sendPing(frame: frame)
        case .goAway:
            self.sendGoAway(frame: frame)
        case .windowUpdate:
            fatalError("not implemented")
        case .alternativeService:
            fatalError("not implemented")
        }
    }

    public func receivedEOF() throws {
        // EOF is the end of this connection. If the connection is already over, that's fine: otherwise,
        // we want to throw an error for reporting on the pipeline. Either way, we need to clean up our state.
        self.closed = true

        // TODO(cory): Check state, throw in error cases.
    }

    public func doOneWrite() -> WriteResult {
        precondition(!self.closed)
        var data: UnsafePointer<UInt8>? = nil

        let length = nghttp2_session_mem_send(self.session, &data)
        // TODO(cory): I think this mishandles DATA frames: they'll say 0, but there may be more frames to
        // send. Must investigate.
        guard length != 0 else {
            return .noWrite
        }
        var buffer = self.allocator.buffer(capacity: length)
        buffer.write(bytes: UnsafeBufferPointer(start: data, count: length))
        self.sendFunction(.byteBuffer(buffer), nil)
        return .didWrite
    }

    enum WriteResult {
        case didWrite
        case noWrite
    }

    /// Given a headers frame, configure nghttp2 to write it and set up appropriate
    /// settings for sending data.
    ///
    /// The complexity of this function exists because nghttp2 does not allow us to have both a headers
    /// and a data frame pending for a stream at the same time. As a result, before we've sent the headers frame we
    /// cannot ask nghttp2 to send the data frame for us. Instead, we set up all our own state for sending data frames
    /// and then wait to swap it in until nghttp2 tells us the data got sent.
    ///
    /// That means all this state must be ready to go once we've submitted the headers frame to nghttp2. This function
    /// is responsible for getting all our ducks in a row.
    private func sendHeaders(frame: HTTP2Frame) {
        guard case .headers(let headers) = frame.payload else {
            preconditionFailure("Attempting to send non-headers frame")
        }

        let isEndStream = frame.endStream
        let flags = isEndStream ? UInt8(NGHTTP2_FLAG_END_STREAM.rawValue) : UInt8(0)

        guard let networkStreamID = frame.streamID.networkStreamID else {
            // This must be a request: delegate to that function.
            self.sendRequest(streamID: frame.streamID, flags: flags, headers: headers)
            return
        }

        let streamData = self.streamIDManager.getStreamData(for: networkStreamID)!
        let blockType = streamData.newOutboundHeaderBlock(block: headers)
        if blockType == .trailer {
            // Trailers are a tricky beast, as they must be submitted via the data provider. They count as EOF.
            // TODO(cory): Error handling.
            precondition(isEndStream)
            streamData.dataProvider.bufferEOF(trailers: headers)
            return
        }

        // Ok, we know we have some kind of response header here, we can submit it directly.
        assert(self.mode == .server)
        let rc = headers.withNGHTTP2Headers(allocator: self.allocator) { vec, count in
            nghttp2_submit_headers(self.session,
                                   flags,
                                   networkStreamID,
                                   nil,
                                   vec,
                                   count,
                                   nil)
        }
        precondition(rc == 0)
    }

    /// Sends a HEADERS frame for a request.
    ///
    /// This function specifically handles the additional logic for creating a brand new stream.
    private func sendRequest(streamID: HTTP2StreamID, flags: UInt8, headers: HTTPHeaders) {
        let rc = headers.withNGHTTP2Headers(allocator: self.allocator) { vec, count in
            nghttp2_submit_headers(self.session, flags, -1, nil, vec, count, nil)
        }

        precondition(rc > 0)
        streamID.resolve(to: rc)
        let streamData = self.streamIDManager.createStreamData(for: streamID)
        streamData.active = true

        let blockType = streamData.newOutboundHeaderBlock(block: headers)
        assert(blockType == .requestHead)
    }

    /// Given the data for a "data frame", configure nghttp2 to write it.
    ///
    /// This function does not immediately emit output: it just configures nghttp2 to start outputting
    /// data at some point.
    private func writeDataToStream(frame: HTTP2Frame, promise: EventLoopPromise<Void>?) {
        guard case .data(let data) = frame.payload else {
            preconditionFailure("Write data attempted on non-data frame \(frame)")
        }

        guard let streamState = self.streamIDManager.getStreamData(for: frame.streamID.networkStreamID!), streamState.active else {
            promise?.fail(error: NIOHTTP2Errors.NoSuchStream(streamID: frame.streamID))
            return
        }

        streamState.dataProvider.bufferWrite(write: data, promise: promise)

        // If this has END_STREAM set, we do not expect trailers.
        if frame.endStream {
            streamState.dataProvider.bufferEOF(trailers: nil)
        }

        if case .pending = streamState.dataProvider.state {
            // The data provider is currently in the pending state, we need to tell nghttp2 it's active again.
            let rc = nghttp2_session_resume_data(self.session, frame.streamID.networkStreamID!)
            // TODO(cory): Error handling
            precondition(rc == 0)
            streamState.dataProvider.didResume()
        }
    }

    private func sendGoAway(frame: HTTP2Frame) {
        guard case .goAway(let lastStreamID, let errorCode, let opaqueData) = frame.payload else {
            preconditionFailure("Send goaway attempted on non-goaway frame \(frame)")
        }

        precondition(frame.streamID == .rootStream, "GOAWAY must be sent on the root stream")

        func submitGoAway(opaqueData: UnsafeRawBufferPointer?) -> CInt {
            return nghttp2_submit_goaway(self.session,
                                         0,
                                         lastStreamID.networkStreamID!,
                                         UInt32(http2ErrorCode: errorCode),
                                         opaqueData?.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         opaqueData?.count ?? 0)
        }

        let rc: CInt
        if let data = opaqueData {
            rc = data.withUnsafeReadableBytes { submitGoAway(opaqueData: $0) }
        } else {
            rc = submitGoAway(opaqueData: nil)
        }

        // TODO(cory): Error handling!
        precondition(rc == 0)
    }

    private func sendSettings(frame: HTTP2Frame) {
        guard case .settings(let settings) = frame.payload else {
            preconditionFailure("Send settings attempted on non-settings frame \(frame)")
        }

        let rc = settings.map { nghttp2_settings_entry(nioSetting: $0) }.withUnsafeBufferPointer {
            nghttp2_submit_settings(self.session, 0, $0.baseAddress!, $0.count)
        }
        precondition(rc == 0)
    }

    private func sendPing(frame: HTTP2Frame) {
        guard case .ping(var opaqueData) = frame.payload else {
            preconditionFailure("Send ping attempted on non-ping frame \(frame)")
        }

        let rc = withUnsafeBytes(of: &opaqueData.bytes) {
            nghttp2_submit_ping(self.session, 0, $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        precondition(rc == 0)
    }

    private func sendRstStream(frame: HTTP2Frame) {
        guard case .rstStream(let errorCode) = frame.payload else {
            preconditionFailure("Send rstStream attempted on non-rst-stream frame \(frame)")
        }

        let rc = nghttp2_submit_rst_stream(self.session, 0, frame.streamID.networkStreamID!, UInt32(http2ErrorCode: errorCode))
        precondition(rc == 0)
    }

    deinit {
        nghttp2_session_del(session)
    }
}

private extension ByteBufferAllocator {
    /// Allocate a buffer containing a copy of the bytes in `pointer`.
    ///
    /// - parameters:
    ///     - pointer: The pointer to the bytes to copy.
    /// - returns: A `ByteBuffer` containing a copy of the bytes.
    func buffer(containingCopyOf pointer: UnsafeBufferPointer<UInt8>) -> ByteBuffer {
        var buffer = self.buffer(capacity: pointer.count)
        buffer.write(bytes: pointer)
        return buffer
    }
}
