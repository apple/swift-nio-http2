//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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
import NIOHTTP2

func run(identifier: String) {
    var buffer = ByteBufferAllocator().buffer(capacity: 128)
    buffer.writeBytes([
        0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63,
        0x6f, 0x6d,
    ])
    let request1 = buffer
    buffer.clear()
    buffer.writeBytes([0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 0x6e, 0x6f, 0x2d, 0x63, 0x61, 0x63, 0x68, 0x65])
    let request2 = buffer
    buffer.clear()
    buffer.writeBytes([
        0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b, 0x65, 0x79, 0x0c, 0x63,
        0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x76, 0x61, 0x6c, 0x75, 0x65,
    ])
    let request3 = buffer

    measure(identifier: identifier) {
        var sum = 0
        for _ in 0..<1000 {
            var request1Buffer = request1
            var request2Buffer = request2
            var request3Buffer = request3
            var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
            let decoded1 = try! decoder.decodeHeaders(from: &request1Buffer)
            sum += decoded1.count
            let decoded2 = try! decoder.decodeHeaders(from: &request2Buffer)
            sum += decoded2.count
            let decoded3 = try! decoder.decodeHeaders(from: &request3Buffer)
            sum += decoded3.count
        }
        return sum
    }
}
