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
import NIO

/// The result of receiving a frame that is about to be sent.
internal enum OutboundFrameAction {
    /// The caller should forward the frame on.
    case forward

    /// This object has buffered the frame, no action should be taken.
    case nothing

    /// A number of frames have to be dropped on the floor due to a RST_STREAM frame being emitted, and the RST_STREAM
    /// frame itself must be forwarded.
    /// This cannot be done automatically without potentially causing exclusive access violations.
    case forwardAndDrop(MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>, NIOHTTP2Errors.StreamClosed)

    /// A number of frames have to be dropped on the floor due to a RST_STREAM frame being emitted, and the RST_STREAM
    /// frame itself should be succeeded and not forwarded.
    /// This cannot be done automatically without potentially causing exclusive access violations.
    case succeedAndDrop(MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>, NIOHTTP2Errors.StreamClosed)
}

/// A buffer of outbound frames used in HTTP/2 connections.
///
/// Outbound frames have to pass through a number of buffers before they can be sent to the network. Most frames,
/// particularly control frames, are never buffered, but a small number of frames are. These need to pass through
/// the buffers in order to ensure that we avoid violating certain parts of the HTTP/2 protocol.
///
/// This object provides a "compound" buffer that is made up of multiple smaller buffers. This buffer passes the
/// frames through in order and understands the relationship of the various buffers to each other.
internal struct CompoundOutboundBuffer {
    /// A buffer that ensures we don't violate SETTINGS_MAX_CONCURRENT_STREAMS. This is the first buffer all
    /// frames pass through.
    private var concurrentStreamsBuffer: ConcurrentStreamBuffer

    /// A buffer that ensures we don't violate HTTP/2 flow control. This is the second buffer all frames pass through.
    private var flowControlBuffer: OutboundFlowControlBuffer
}


// MARK: CompoundOutboundBuffer initializers
extension CompoundOutboundBuffer {
    internal init(mode: NIOHTTP2Handler.ParserMode, initialMaxOutboundStreams: Int) {
        self.concurrentStreamsBuffer = ConcurrentStreamBuffer(mode: mode, initialMaxOutboundStreams: initialMaxOutboundStreams)
        self.flowControlBuffer = OutboundFlowControlBuffer()
    }
}

// MARK: CompoundOutboundBuffer outbound methods
//
// Note that this does not quite conform to OutboundFrameBuffer. This is because the implementation of nextFlushedWritableFrame may in principle
// cause an error that requires us to error out on a frame, and we cannot make outcalls from this structure.
extension CompoundOutboundBuffer {
    mutating func processOutboundFrame(_ frame: HTTP2Frame, promise: EventLoopPromise<Void>?) throws -> OutboundFrameAction {
        var framesToDrop: MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)> = MarkedCircularBuffer(initialCapacity: 0)
        var error: NIOHTTP2Errors.StreamClosed? = nil

        // The outbound frames pass through the buffers in order, with the following logic:
        //
        // 1. If a buffer returns .nothing, return .nothing as the frame has been buffered.
        // 2. If a buffer returns .forward, pass to the next buffer.
        // 3. If a buffer returns .forwardAndDrop, pass to the next buffer and store the dropped frames. Future buffers may append
        //        to the dropped frames.
        // 4. If a buffer returns .succeedAndDrop, return .succeedAndDrop.
        // The return value of the last buffer is the return value of the compound buffer, unless we returned early.
        switch try self.concurrentStreamsBuffer.processOutboundFrame(frame, promise: promise) {
        case .nothing:
            return .nothing
        case .succeedAndDrop(let framesToDrop, let error):
            return .succeedAndDrop(framesToDrop, error)
        case .forwardAndDrop(let newFramesToDrop, let newError):
            for frame in newFramesToDrop {
                framesToDrop.append(frame)
            }
            error = newError
            break
        case .forward:
            break
        }

        switch try self.flowControlBuffer.processOutboundFrame(frame, promise: promise) {
        case .nothing:
            return .nothing
        case .succeedAndDrop(let framesToDrop, let error):
            return .succeedAndDrop(framesToDrop, error)
        case .forwardAndDrop(let newFramesToDrop, let newError):
            for frame in newFramesToDrop {
                framesToDrop.append(frame)
            }
            error = newError
            break
        case .forward:
            break
        }

        // Ok, we're at the end. If we have an error, return .forwardAndDrop. Otherwise, return .forward.
        if let error = error {
            return .forwardAndDrop(framesToDrop, error)
        } else {
            return .forward
        }
    }

    mutating func flushReceived() {
        // Here we just tell every buffer that we have got a flush.
        self.concurrentStreamsBuffer.flushReceived()
        self.flowControlBuffer.flushReceived()
    }

    enum FlushedWritableFrameResult {
        case noFrame
        case frame(HTTP2Frame, EventLoopPromise<Void>?)
        case error(EventLoopPromise<Void>?, Error)
    }

    mutating func nextFlushedWritableFrame() -> FlushedWritableFrameResult {
        // The goal here is to eagerly do as much work as possible on the concurrent streams buffer before we get to the
        // flow control buffer. We spin over the concurrent streams buffer, unbuffering everything we can and passing it
        // to the flow control buffer.
        //
        // We expect only two possible outcomes from this forwarding: .forward or .nothing. If we get .nothing, we continue
        // the loop. If we get .forward we stop the loop and return the frame, as it can go on. We don't expect either of
        // the "andDrop" results as they are a result of RST_STREAM frames, which are never buffered.
        //
        // If we get to the end of the loop without forwarding a frame, we mark a new flush point on the flowControlBuffer
        // and then ask it for a frame, returning its response.
        while let (frame, promise) = self.concurrentStreamsBuffer.nextFlushedWritableFrame() {
            do {
                switch try self.flowControlBuffer.processOutboundFrame(frame, promise: promise) {
                case .nothing:
                    continue
                case .forward:
                    return .frame(frame, promise)
                case .forwardAndDrop, .succeedAndDrop:
                    preconditionFailure("Asked to drop frames despite that being impossible: frame: \(frame)")
                }
            } catch {
                return .error(promise, error)
            }
        }

        if let (frame, promise) = self.flowControlBuffer.nextFlushedWritableFrame() {
            return .frame(frame, promise)
        } else {
            return .noFrame
        }
    }
}

// MARK: CompoundOutboundBuffer state change methods.
extension CompoundOutboundBuffer {
    mutating func streamCreated(_ streamID: HTTP2StreamID, initialWindowSize: UInt32) {
        self.concurrentStreamsBuffer.streamCreated(streamID)
        self.flowControlBuffer.streamCreated(streamID, initialWindowSize: initialWindowSize)
    }

    mutating func streamClosed(_ streamID: HTTP2StreamID) -> DroppedPromisesCollection {
        var droppedPromises = DroppedPromisesCollection()
        droppedPromises.droppedConcurrentStreamsFrames = self.concurrentStreamsBuffer.streamClosed(streamID)
        droppedPromises.droppedFlowControlFrames = self.flowControlBuffer.streamClosed(streamID)
        return droppedPromises
    }

    mutating func updateStreamWindow(_ streamID: HTTP2StreamID, newSize: Int32) {
        self.flowControlBuffer.updateWindowOfStream(streamID, newSize: newSize)
    }

    var maxFrameSize: Int {
        get {
            return self.flowControlBuffer.maxFrameSize
        }
        set {
            self.flowControlBuffer.maxFrameSize = newValue
        }
    }

    var connectionWindowSize: Int {
        get {
            return self.flowControlBuffer.connectionWindowSize
        }
        set {
            self.flowControlBuffer.connectionWindowSize = newValue
        }
    }

    var maxOutboundStreams: Int {
        get {
            return self.concurrentStreamsBuffer.maxOutboundStreams
        }
        set {
            self.concurrentStreamsBuffer.maxOutboundStreams = newValue
        }
    }
}

// MARK: CompoundOutboundBuffer.DroppedPromisesCollection
extension CompoundOutboundBuffer {
    /// A structure that contains promises dropped by the buffers when a stream has been closed.
    struct DroppedPromisesCollection {
        typealias ConcurrentStreamsFrames = MarkedCircularBuffer<(HTTP2Frame, EventLoopPromise<Void>?)>
        typealias FlowControlFrames = MarkedCircularBuffer<(HTTP2Frame.FramePayload, EventLoopPromise<Void>?)>

        var droppedConcurrentStreamsFrames: ConcurrentStreamsFrames?
        var droppedFlowControlFrames: FlowControlFrames?
    }
}

extension CompoundOutboundBuffer.DroppedPromisesCollection: Collection {
    typealias Element = EventLoopPromise<Void>?

    struct Index: Comparable {
        fileprivate enum BackingIndex: Equatable {
            case concurrentStreams(ConcurrentStreamsFrames.Index)
            case flowControl(FlowControlFrames.Index)
            case endIndex
        }

        fileprivate private(set) var backingIndex: BackingIndex

        fileprivate init(_ backingIndex: BackingIndex) {
            self.backingIndex = backingIndex
        }

        static func < (lhs: Index, rhs: Index) -> Bool {
            switch (lhs.backingIndex, rhs.backingIndex) {
            case (.concurrentStreams, .flowControl),
                 (.concurrentStreams, .endIndex):
                return true
            case (.concurrentStreams(let lhsBackingIndex), .concurrentStreams(let rhsBackingIndex)):
                return lhsBackingIndex < rhsBackingIndex
            case (.flowControl, .concurrentStreams):
                return false
            case (.flowControl, .endIndex):
                return true
            case (.flowControl(let lhsBackingIndex), .flowControl(let rhsBackingIndex)):
                return lhsBackingIndex < rhsBackingIndex
            case (.endIndex, _):
                return false
            }
        }
    }

    var startIndex: Index {
        if let concurrentStreams = self.droppedConcurrentStreamsFrames {
            return Index(.concurrentStreams(concurrentStreams.startIndex))
        } else if let flowControl = self.droppedFlowControlFrames {
            return Index(.flowControl(flowControl.startIndex))
        } else {
            return Index(.endIndex)
        }
    }

    var endIndex: Index {
        return Index(.endIndex)
    }

    func index(after index: Index) -> Index {
        // These force unwraps are safe, as the index will never point at a collection we don't have.
        switch index.backingIndex {
        case .concurrentStreams(let baseIndex):
            let newBaseIndex = self.droppedConcurrentStreamsFrames!.index(after: baseIndex)
            if newBaseIndex != self.droppedConcurrentStreamsFrames!.endIndex {
                return Index(.concurrentStreams(newBaseIndex))
            }

            // Gotta move on.
            if let flowControl = self.droppedFlowControlFrames {
                return Index(.flowControl(flowControl.startIndex))
            } else {
                return Index(.endIndex)
            }
        case .flowControl(let baseIndex):
            let newBaseIndex = self.droppedFlowControlFrames!.index(after: baseIndex)
            if newBaseIndex != self.droppedFlowControlFrames!.endIndex {
                return Index(.flowControl(newBaseIndex))
            } else {
                return Index(.endIndex)
            }
        case .endIndex:
            return Index(.endIndex)
        }
    }

    subscript(_ index: Index) -> Element {
        switch index.backingIndex {
        case .concurrentStreams(let baseIndex):
            return self.droppedConcurrentStreamsFrames![baseIndex].1
        case .flowControl(let baseIndex):
            return self.droppedFlowControlFrames![baseIndex].1
        case .endIndex:
            preconditionFailure("Attempted to subscript with endIndex")
        }
    }

    var count: Int {
        // An override of count to ensure that we get faster performance than index walking.
        let droppedConcurrentStreams = self.droppedConcurrentStreamsFrames?.count ?? 0
        let droppedFlowControl = self.droppedFlowControlFrames?.count ?? 0
        return droppedConcurrentStreams + droppedFlowControl
    }
}
