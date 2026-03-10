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

import Benchmark
import NIOCore
import NIOHPACK

let benchmarks: @Sendable () -> Void = {
    Benchmark(
        "HPACKHeaderEncoding_APNS",
        configuration: .init(
            metrics: [.mallocCountTotal, .instructions, .wallClock],
            scalingFactor: .kilo
        )
    ) { benchmark in
        let apnsHeaders: HPACKHeaders = [
            ":method": "POST",
            ":path": "/3/device/00fc13adff785122b4ad28809a3e8082045c3e7c1a9f8f58e2f57a30bad76c95",
            ":scheme": "https",
            ":authority": "api.push.apple.com",
            "content-type": "application/json",
            "apns-topic": "com.example.MyApp",
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": "0",
            "authorization": "bearer eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJBQkNERTEyMzQ1Iiwi",
        ]

        let allocator = ByteBufferAllocator()
        var encoder = HPACKEncoder(allocator: allocator)
        var buffer = allocator.buffer(capacity: 1024)

        for _ in benchmark.scaledIterations {
            try! encoder.encode(headers: apnsHeaders, to: &buffer)
            buffer.clear()
        }

        blackHole(buffer)
    }
}
