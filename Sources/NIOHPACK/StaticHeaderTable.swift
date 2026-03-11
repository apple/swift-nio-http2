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

enum StaticHeaderTable {
    static let count = StaticHeaderTable.values.count

    static let values: [(String, String)] = [
        ("", ""),  // real indexing begins at 1
        (":authority", ""),
        (":method", "GET"),
        (":method", "POST"),
        (":path", "/"),
        (":path", "/index.html"),
        (":scheme", "http"),
        (":scheme", "https"),
        (":status", "200"),
        (":status", "204"),
        (":status", "206"),
        (":status", "304"),
        (":status", "400"),
        (":status", "404"),
        (":status", "500"),
        ("accept-charset", ""),
        ("accept-encoding", "gzip, deflate"),
        ("accept-language", ""),
        ("accept-ranges", ""),
        ("accept", ""),
        ("access-control-allow-origin", ""),
        ("age", ""),
        ("allow", ""),
        ("authorization", ""),
        ("cache-control", ""),
        ("content-disposition", ""),
        ("content-encoding", ""),
        ("content-language", ""),
        ("content-length", ""),
        ("content-location", ""),
        ("content-range", ""),
        ("content-type", ""),
        ("cookie", ""),
        ("date", ""),
        ("etag", ""),
        ("expect", ""),
        ("expires", ""),
        ("from", ""),
        ("host", ""),
        ("if-match", ""),
        ("if-modified-since", ""),
        ("if-none-match", ""),
        ("if-range", ""),
        ("if-unmodified-since", ""),
        ("last-modified", ""),
        ("link", ""),
        ("location", ""),
        ("max-forwards", ""),
        ("proxy-authenticate", ""),
        ("proxy-authorization", ""),
        ("range", ""),
        ("referer", ""),
        ("refresh", ""),
        ("retry-after", ""),
        ("server", ""),
        ("set-cookie", ""),
        ("strict-transport-security", ""),
        ("transfer-encoding", ""),
        ("user-agent", ""),
        ("vary", ""),
        ("via", ""),
        ("www-authenticate", ""),
    ]

    /// Pre-computed hash index for O(1) static table name lookups.
    /// Maps case-insensitive header name → array of (offset, value) pairs in the static table.
    private static let lookup: [CaseInsensitiveASCIIString: [(offset: Int, value: String)]] = {
        var index = [CaseInsensitiveASCIIString: [(offset: Int, value: String)]]()
        index.reserveCapacity(StaticHeaderTable.values.count)
        for (offset, entry) in StaticHeaderTable.values.enumerated() {
            let key = CaseInsensitiveASCIIString(entry.0)
            index[key, default: []].append((offset: offset, value: entry.1))
        }
        return index
    }()

    static subscript(name: String) -> [(offset: Int, value: String)]? {
        self.lookup[CaseInsensitiveASCIIString(name)]
    }
}

/// A wrapper around `String` that provides case-insensitive ASCII hashing and equality.
/// Used as a dictionary key for O(1) static table lookups.
private struct CaseInsensitiveASCIIString: Hashable, Sendable {
    @usableFromInline
    let _string: String

    @inlinable
    init(_ string: String) {
        self._string = string
    }

    @inlinable
    func hash(into hasher: inout Hasher) {
        // fast path
        if self._string.isContiguousUTF8 {
            // Accumulate a single hash value from all bytes to minimize hasher.combine calls.
            self._string.utf8.withContiguousStorageIfAvailable { buffer in
                for idx in 0..<buffer.count {
                    hasher.combine(buffer[idx] & 0xdf)
                }
            }!
        } else {
            // slow path
            for byte in self._string.utf8 {
                hasher.combine(byte & 0xdf)
            }
        }
    }

    @inlinable
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs._string.isEqualCaseInsensitiveASCIIBytes(to: rhs._string)
    }
}
