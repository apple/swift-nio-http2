//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOHPACK

func run(identifier: String) {
    measure(identifier: identifier) {
        let headers: HPACKHeaders = ["key": "no,trimming"]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }

    measure(identifier: identifier + "_trimming_whitespace") {
        let headers: HPACKHeaders = ["key": "         some   ,   trimming     "]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }

    measure(identifier: identifier + "_trimming_whitespace_from_short_string") {
        // first components has length > 15 with whitespace and <= 15 without.
        let headers: HPACKHeaders = ["key": "   smallString   ,whenStripped"]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }

    measure(identifier: identifier + "_trimming_whitespace_from_long_string") {
        let headers: HPACKHeaders = ["key": " moreThan15CharactersWithAndWithoutWhitespace ,anotherValue"]
        var count = 0
        for _ in 0..<100_000 {
            count &+= headers[canonicalForm: "key"].count
        }
        return count
    }
}
