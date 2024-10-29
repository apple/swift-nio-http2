//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHPACK

struct HTTP2FrameEncoder {
    var headerEncoder: HPACKEncoder

    // RFC 7540 § 6.5.2 puts the initial value of SETTINGS_MAX_FRAME_SIZE at 2**14 octets
    var maxFrameSize: UInt32 = 1 << 14

    init(allocator: ByteBufferAllocator) {
        self.headerEncoder = HPACKEncoder(allocator: allocator)
    }

    /// Encodes the frame and optionally returns one or more blobs of data
    /// ready for the system.
    ///
    /// Returned data blobs would include anything of potentially flexible
    /// length, such as DATA payloads, header fragments in HEADERS or PUSH_PROMISE
    /// frames, and so on. This is to avoid manually copying chunks of data which
    /// we could just enqueue separately in sequence on the channel. Generally, if
    /// we have a byte buffer somewhere, we will return that separately rather than
    /// copy it into another buffer, with the corresponding allocation overhead.
    ///
    /// - Parameters:
    ///   - frame: The frame to encode.
    ///   - buf: Destination buffer for the encoded frame.
    /// - Returns: An array containing zero or more additional buffers to send, in
    ///            order. These may contain data frames' payload bytes, encoded
    ///            header fragments, etc.
    /// - Throws: Errors returned from HPACK encoder.
    mutating func encode(frame: HTTP2Frame, to buf: inout ByteBuffer) throws -> IOData? {
        // note our starting point
        let start = buf.writerIndex

        //      +-----------------------------------------------+
        //      |                 Length (24)                   |
        //      +---------------+---------------+---------------+
        //      |   Type (8)    |   Flags (8)   |
        //      +-+-------------+---------------+-------------------------------+
        //      |R|                 Stream Identifier (31)                      |
        //      +=+=============================================================+
        //      |                   Frame Payload (0...)                      ...
        //      +---------------------------------------------------------------+

        // skip 24-bit length for now, we'll fill that in later
        buf.moveWriterIndex(forwardBy: 3)

        // 8-bit type
        buf.writeInteger(frame.payload.code)

        // skip the 8 bit flags for now, we'll fill it in later as well.
        let flagsIndex = buf.writerIndex
        var flags = FrameFlags()
        buf.moveWriterIndex(forwardBy: 1)

        // 32-bit stream identifier -- ensuring the top bit is empty
        buf.writeInteger(Int32(frame.streamID))

        // frame payload follows, which depends on the frame type itself
        let payloadStart = buf.writerIndex
        let extraFrameData: IOData?
        let payloadSize: Int

        switch frame.payload {
        case .data(let dataContent):
            if dataContent.paddingBytes != nil {
                // we don't support sending padded frames just now
                throw NIOHTTP2Errors.unsupported(info: "Padding is not supported on sent frames at this time")
            }

            if dataContent.endStream {
                flags.insert(.endStream)
            }
            extraFrameData = dataContent.data
            payloadSize = dataContent.data.readableBytes

        case .headers(let headerData):
            if headerData.paddingBytes != nil {
                // we don't support sending padded frames just now
                throw NIOHTTP2Errors.unsupported(info: "Padding is not supported on sent frames at this time")
            }

            flags.insert(.endHeaders)
            if headerData.endStream {
                flags.insert(.endStream)
            }

            if let priority = headerData.priorityData {
                flags.insert(.priority)
                var dependencyRaw = UInt32(priority.dependency)
                if priority.exclusive {
                    dependencyRaw |= 0x8000_0000
                }
                buf.writeInteger(dependencyRaw)
                buf.writeInteger(priority.weight)
            }

            try self.headerEncoder.encode(headers: headerData.headers, to: &buf)
            payloadSize = buf.writerIndex - payloadStart
            extraFrameData = nil

        case .priority(let priorityData):
            var raw = UInt32(priorityData.dependency)
            if priorityData.exclusive {
                raw |= 0x8000_0000
            }
            buf.writeInteger(raw)
            buf.writeInteger(priorityData.weight)

            extraFrameData = nil
            payloadSize = 5

        case .rstStream(let errcode):
            buf.writeInteger(UInt32(errcode.networkCode))

            payloadSize = 4
            extraFrameData = nil

        case .settings(.settings(let settings)):
            for setting in settings {
                buf.writeInteger(setting.parameter.networkRepresentation)
                buf.writeInteger(setting._value)
            }

            payloadSize = settings.count * 6
            extraFrameData = nil

        case .settings(.ack):
            payloadSize = 0
            extraFrameData = nil
            flags.insert(.ack)

        case .pushPromise(let pushPromiseData):
            if pushPromiseData.paddingBytes != nil {
                // we don't support sending padded frames just now
                throw NIOHTTP2Errors.unsupported(info: "Padding is not supported on sent frames at this time")
            }

            let streamVal: UInt32 = UInt32(pushPromiseData.pushedStreamID)
            buf.writeInteger(streamVal)

            try self.headerEncoder.encode(headers: pushPromiseData.headers, to: &buf)

            payloadSize = buf.writerIndex - payloadStart
            extraFrameData = nil
            flags.insert(.endHeaders)

        case .ping(let pingData, let ack):
            withUnsafeBytes(of: pingData.bytes) { ptr -> Void in
                _ = buf.writeBytes(ptr)
            }

            if ack {
                flags.insert(.ack)
            }

            payloadSize = 8
            extraFrameData = nil

        case .goAway(let lastStreamID, let errorCode, let opaqueData):
            let streamVal: UInt32 = UInt32(lastStreamID) & ~0x8000_0000
            buf.writeInteger(streamVal)
            buf.writeInteger(UInt32(errorCode.networkCode))

            if let data = opaqueData {
                payloadSize = data.readableBytes + 8
                extraFrameData = .byteBuffer(data)
            } else {
                payloadSize = 8
                extraFrameData = nil
            }

        case .windowUpdate(let size):
            buf.writeInteger(UInt32(size) & ~0x8000_0000)
            payloadSize = 4
            extraFrameData = nil

        case .alternativeService(let origin, let field):
            if let org = origin {
                buf.moveWriterIndex(forwardBy: 2)
                let start = buf.writerIndex
                buf.writeString(org)
                buf.setInteger(UInt16(buf.writerIndex - start), at: payloadStart)
            } else {
                buf.writeInteger(UInt16(0))
            }

            if let value = field {
                payloadSize = buf.writerIndex - payloadStart + value.readableBytes
                extraFrameData = .byteBuffer(value)
            } else {
                payloadSize = buf.writerIndex - payloadStart
                extraFrameData = nil
            }

        case .origin(let origins):
            for origin in origins {
                let sizeLoc = buf.writerIndex
                buf.moveWriterIndex(forwardBy: 2)

                let start = buf.writerIndex
                buf.writeString(origin)
                buf.setInteger(UInt16(buf.writerIndex - start), at: sizeLoc)
            }

            payloadSize = buf.writerIndex - payloadStart
            extraFrameData = nil
        }

        // Confirm we're not about to violate SETTINGS_MAX_FRAME_SIZE.
        guard payloadSize <= Int(self.maxFrameSize) else {
            throw InternalError.codecError(code: .frameSizeError)
        }

        // Write the frame data. This is the payload size and the flags byte.
        buf.writePayloadSize(payloadSize, at: start)
        buf.setInteger(flags.rawValue, at: flagsIndex)

        // all bytes to write are in the provided buffer now
        return extraFrameData
    }
}

extension ByteBuffer {
    fileprivate mutating func writePayloadSize(_ size: Int, at location: Int) {
        // Yes, this performs better than running a UInt8 through the generic write(integer:) three times.
        var bytes: (UInt8, UInt8, UInt8)
        bytes.0 = UInt8((size & 0xff_00_00) >> 16)
        bytes.1 = UInt8((size & 0x00_ff_00) >> 8)
        bytes.2 = UInt8(size & 0x00_00_ff)
        withUnsafeBytes(of: bytes) { ptr in
            _ = self.setBytes(ptr, at: location)
        }
    }
}
