// swift-tools-version:4.0
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

struct HeaderTableEntry {
    var name: String
    var value: String?
    
    init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }
    
    // RFC 7541 § 4.1:
    //
    //      The size of an entry is the sum of its name's length in octets (as defined in
    //      Section 5.2), its value's length in octets, and 32.
    //
    //      The size of an entry is calculated using the length of its name and value
    //      without any Huffman encoding applied.
    var length: Int {
        return self.name.utf8.count + (self.value?.utf8.count ?? 0) + 32
    }
}

extension HeaderTableEntry : Equatable {
    static func == (lhs: HeaderTableEntry, rhs: HeaderTableEntry) -> Bool {
        return lhs.name == rhs.name && lhs.value == rhs.value
    }
}

extension HeaderTableEntry : Hashable {
    var hashValue: Int {
        #if swift(>=4.2)
            var h = Hasher()
            h.combine(self.name)
            h.combine(self.value)
            return h.finalize()
        #else
            var result = self.name.hashValue
            if let value = self.value {
                result = result * 31 + value.hashValue
            }
            return result
        #endif
    }
}
