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
import NIOHPACK

extension HPACKHeaders {
    /// Checks that a given HPACKHeaders block is a valid request header block, meeting all of the constraints of RFC 7540.
    ///
    /// If the header block is not valid, throws an error.
    internal func validateRequestBlock() throws {
        return try RequestBlockValidator.validateBlock(self)
    }

    /// Checks that a given HPACKHeaders block is a valid response header block, meeting all of the constraints of RFC 7540.
    ///
    /// If the header block is not valid, throws an error.
    internal func validateResponseBlock() throws {
        return try ResponseBlockValidator.validateBlock(self)
    }

    /// Checks that a given HPACKHeaders block is a valid trailer block, meeting all of the constraints of RFC 7540.
    ///
    /// If the header block is not valid, throws an error.
    internal func validateTrailersBlock() throws {
        return try TrailersValidator.validateBlock(self)
    }
}


/// A `HeaderBlockValidator` is an object that can confirm that a HPACK block meets certain constraints.
fileprivate protocol HeaderBlockValidator {
    init()

    mutating func validateNextField(name: HeaderFieldName, value: String) throws
}

extension HeaderBlockValidator {
    /// Validates that a header block meets the requirements of this `HeaderBlockValidator`.
    fileprivate static func validateBlock(_ block: HPACKHeaders) throws {
        var validator = Self()
        for (name, value, _) in block {
            let fieldName = try HeaderFieldName(name)
            try validator.validateNextField(name: fieldName, value: value)
        }
    }
}

/// An object that can be used to validate if a given header block is a valid request header block.
fileprivate struct RequestBlockValidator { }

extension RequestBlockValidator: HeaderBlockValidator {
    fileprivate mutating func validateNextField(name: HeaderFieldName, value: String) throws {
        return
    }
}


/// An object that can be used to validate if a given header block is a valid response header block.
fileprivate struct ResponseBlockValidator { }

extension ResponseBlockValidator: HeaderBlockValidator {
    fileprivate mutating func validateNextField(name: HeaderFieldName, value: String) throws {
        return
    }
}


/// An object that can be used to validate if a given header block is a valid trailer block.
fileprivate struct TrailersValidator { }

extension TrailersValidator: HeaderBlockValidator {
    fileprivate mutating func validateNextField(name: HeaderFieldName, value: String) throws {
        return
    }
}


/// A structure that carries the details of a specific header field name.
///
/// Used to validate the correctness of a specific header field name at a given
/// point in a header block.
fileprivate struct HeaderFieldName { }

extension HeaderFieldName {
    fileprivate init(_ fieldName: String) throws {
        let fieldBytes = Substring(fieldName).utf8

        let baseName: Substring.UTF8View
        if fieldBytes.first == UInt8(ascii: ":") {
            baseName = fieldBytes.dropFirst()
        } else {
            baseName = fieldBytes
        }

        guard baseName.isValidFieldName else {
            throw NIOHTTP2Errors.InvalidHTTP2HeaderFieldName(fieldName)
        }
    }
}


extension Substring.UTF8View {
    /// Whether this is a valid HTTP/2 header field name.
    fileprivate var isValidFieldName: Bool {
        /// RFC 7230 defines header field names as matching the `token` ABNF, which is:
        ///
        ///     token          = 1*tchar
        ///
        ///     tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
        ///                    / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
        ///                    / DIGIT / ALPHA
        ///                    ; any VCHAR, except delimiters
        ///
        ///     DIGIT          =  %x30-39
        ///                    ; 0-9
        ///
        ///     ALPHA          =  %x41-5A / %x61-7A   ; A-Z / a-z
        ///
        /// RFC 7540 subsequently clarifies that HTTP/2 headers must be converted to lowercase before
        /// sending. This therefore excludes the range A-Z in ALPHA. If we convert tchar to the range syntax
        /// used in DIGIT and ALPHA, and then collapse the ranges that are more than two elements long, we get:
        ///
        ///     tchar          = %x21 / %x23-27 / %x2A / %x2B / %x2D / %x2E / %x5E-60 / %x7C / %x7E / %x30-39 /
        ///                    / %x41-5A / %x61-7A
        ///
        /// Now we can strip out the uppercase characters, and shuffle these so they're in ascending order:
        ///
        ///     tchar          = %x21 / %x23-27 / %x2A / %x2B / %x2D / %x2E / %x30-39 / %x5E-60 / %x61-7A
        ///                    / %x7C / %x7E
        ///
        /// Then we can also spot that we have a pair of ranges that bump into each other and do one further level
        /// of collapsing.
        ///
        ///     tchar          = %x21 / %x23-27 / %x2A / %x2B / %x2D / %x2E / %x30-39 / %x5E-7A
        ///                    / %x7C / %x7E
        ///
        /// We can then translate this into a straightforward switch statement to check whether the code
        /// units are valid.
        return self.allSatisfy { codeUnit in
            switch codeUnit {
            case 0x21, 0x23...0x27, 0x2a, 0x2b, 0x2d, 0x2e, 0x30...0x39,
                 0x5e...0x7a, 0x7c, 0x7e:
                return true
            default:
                return false
            }
        }
    }
}
