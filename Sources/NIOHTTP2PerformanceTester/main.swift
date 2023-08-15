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

import Foundation
import Dispatch

// MARK: Test Harness

var _warning: String = ""
assert({
    print("======================================================")
    print("= YOU ARE RUNNING NIOPerformanceTester IN DEBUG MODE =")
    print("======================================================")
    _warning = " <<< DEBUG MODE >>>"
    return true
}())
let warning = _warning

public func measure(_ fn: () throws -> Int) rethrows -> [TimeInterval] {
    func measureOne(_ fn: () throws -> Int) rethrows -> TimeInterval {
        let start = Date()
        _ = try fn()
        let end = Date()
        return end.timeIntervalSince(start)
    }

    _ = try measureOne(fn) /* pre-heat and throw away */
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try measureOne(fn)
    }

    return measurements
}

let limitSet = ProcessInfo.processInfo.arguments.dropFirst()

public func measureAndPrint(desc: String, fn: () throws -> Int) rethrows -> Void {
    #if CACHEGRIND
    // When CACHEGRIND is set we only run a single requested test, and we only run it once. No printing or other mess.
    if limitSet.contains(desc) {
        _ = try fn()
    }
    #else
    if limitSet.count == 0 || limitSet.contains(desc) {
        print("measuring\(warning): \(desc): ", terminator: "")
        let measurements = try measure(fn)
        print(measurements.reduce("") { $0 + "\($1), " })
    } else {
        print("skipping '\(desc)', limit set = \(limitSet)")
    }
    #endif
}

func measureAndPrint<B: Benchmark>(desc: String, benchmark bench: @autoclosure () -> B) throws {
    // Avoids running setUp/tearDown when we don't want that benchmark.
    guard limitSet.count == 0 || limitSet.contains(desc) else {
        return
    }

    let bench = bench()

    try bench.setUp()
    defer {
        bench.tearDown()
    }
    try measureAndPrint(desc: desc) {
        return try bench.run()
    }
}

// MARK: Utilities

try measureAndPrint(desc: "1_conn_10k_reqs", benchmark: Bench1Conn10kRequests())
try measureAndPrint(desc: "encode_100k_header_blocks_indexable", benchmark: HPACKHeaderEncodingBenchmark(headers: .indexable, loopCount: 100_000))
try measureAndPrint(desc: "encode_100k_header_blocks_nonindexable", benchmark: HPACKHeaderEncodingBenchmark(headers: .nonIndexable, loopCount: 100_000))
try measureAndPrint(desc: "encode_100k_header_blocks_neverIndexed", benchmark: HPACKHeaderEncodingBenchmark(headers: .neverIndexed, loopCount: 100_000))
try measureAndPrint(desc: "decode_100k_header_blocks_indexable", benchmark: HPACKHeaderDecodingBenchmark(headers: .indexable, loopCount: 100_000))
try measureAndPrint(desc: "decode_100k_header_blocks_nonindexable", benchmark: HPACKHeaderDecodingBenchmark(headers: .nonIndexable, loopCount: 100_000))
try measureAndPrint(desc: "decode_100k_header_blocks_neverIndexed", benchmark: HPACKHeaderDecodingBenchmark(headers: .neverIndexed, loopCount: 100_000))
try measureAndPrint(desc: "hpackheaders_canonical_form", benchmark: HPACKHeaderCanonicalFormBenchmark(.noTrimming))
try measureAndPrint(desc: "hpackheaders_canonical_form_trimming_whitespace", benchmark: HPACKHeaderCanonicalFormBenchmark(.trimmingWhitespace))
try measureAndPrint(desc: "hpackheaders_canonical_form_trimming_whitespace_short_strings", benchmark: HPACKHeaderCanonicalFormBenchmark(.trimmingWhitespaceFromShortStrings))
try measureAndPrint(desc: "hpackheaders_canonical_form_trimming_whitespace_long_strings", benchmark: HPACKHeaderCanonicalFormBenchmark(.trimmingWhitespaceFromLongStrings))
try measureAndPrint(desc: "hpackheaders_normalize_httpheaders_removing_10k_conn_headers", benchmark: HPACKHeadersNormalizationOfHTTPHeadersBenchmark(headersKind: .manyUniqueConnectionHeaderValues(10_000), iterations: 10))
try measureAndPrint(desc: "hpackheaders_normalize_httpheaders_keeping_10k_conn_headers", benchmark: HPACKHeadersNormalizationOfHTTPHeadersBenchmark(headersKind: .manyConnectionHeaderValuesWhichAreNotRemoved(10_000), iterations: 10))
try measureAndPrint(desc: "huffman_encode_basic", benchmark: HuffmanEncodingBenchmark(huffmanString: .basicHuffmanString, loopCount: 100))
try measureAndPrint(desc: "huffman_encode_complex", benchmark: HuffmanEncodingBenchmark(huffmanString: .complexHuffmanString, loopCount: 100))
try measureAndPrint(desc: "huffman_decode_basic", benchmark: HuffmanDecodingBenchmark(huffmanBytes: .basicHuffmanBytes, loopCount: 25))
try measureAndPrint(desc: "huffman_decode_complex", benchmark: HuffmanDecodingBenchmark(huffmanBytes: .complexHuffmanBytes, loopCount: 10))
try measureAndPrint(desc: "server_only_10k_requests_1_concurrent", benchmark: ServerOnly10KRequestsBenchmark(concurrentStreams: 1))
try measureAndPrint(desc: "server_only_10k_requests_100_concurrent", benchmark: ServerOnly10KRequestsBenchmark(concurrentStreams: 100))
try measureAndPrint(desc: "stream_teardown_10k_requests_100_concurrent", benchmark: StreamTeardownBenchmark(concurrentStreams: 100))
