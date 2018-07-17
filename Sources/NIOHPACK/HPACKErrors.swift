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

public protocol NIOHPACKError : Error, Equatable { }

/// Errors raised by NIOHPACK while encoding/decoding data.
public enum NIOHPACKErrors {
    /// An indexed header referenced an index that doesn't exist in our
    /// header tables.
    public struct InvalidHeaderIndex : NIOHPACKError {
        /// The offending index.
        public let suppliedIndex: Int
        
        /// The highest index we have available.
        public let availableIndex: Int
        
        init(suppliedIndex: Int, availableIndex: Int) {
            self.suppliedIndex = suppliedIndex
            self.availableIndex = availableIndex
        }
    }
    
    /// A header block indicated an indexed header with no accompanying
    /// value, but the index referenced an entry with no value of its own
    /// e.g. one of the many valueless items in the static header table.
    public struct IndexedHeaderWithNoValue : NIOHPACKError {
        /// The offending index.
        public let index: Int
        
        init(index: Int) {
            self.index = index
        }
    }
    
    /// An encoded string contained an invalid length that extended
    /// beyond its frame's payload size.
    public struct StringLengthBeyondPayloadSize : NIOHPACKError {
        /// The length supplied.
        public let length: Int
        
        /// The available number of bytes.
        public let available: Int
        
        init(length: Int, available: Int) {
            self.length = length
            self.available = available
        }
    }
    
    /// Decoded string data could not be parsed as valid UTF-8.
    public struct InvalidUTF8Data : NIOHPACKError {
        /// The offending bytes.
        public let bytes: ByteBuffer
        
        init(bytes: ByteBuffer) {
            self.bytes = bytes
        }
    }
    
    /// The start byte of a header did not match any format allowed by
    /// the HPACK specification.
    public struct InvalidHeaderStartByte : NIOHPACKError {
        /// The offending byte.
        public let byte: UInt8
        
        init(byte: UInt8) {
            self.byte = byte
        }
    }
    
    /// A new header could not be added to the dynamic table. Usually
    /// this means the header itself is larger than the current
    /// dynamic table size.
    public struct FailedToAddIndexedHeader<Name: Collection, Value: Collection> : NIOHPACKError where Name.Element == UInt8, Value.Element == UInt8 {
        /// The table size required to be able to add this header to the table.
        public let bytesNeeded: Int
        
        /// The name of the header that could not be written.
        public let name: Name
        
        /// The value of the header that could not be written.
        public let value: Value
        
        init(bytesNeeded: Int, name: Name, value: Value) {
            self.bytesNeeded = bytesNeeded
            self.name = name
            self.value = value
        }
        
        public static func == (lhs: NIOHPACKErrors.FailedToAddIndexedHeader<Name, Value>, rhs: NIOHPACKErrors.FailedToAddIndexedHeader<Name, Value>) -> Bool {
            guard lhs.bytesNeeded == rhs.bytesNeeded else {
                return false
            }
            return lhs.name.elementsEqual(rhs.name) && lhs.value.elementsEqual(rhs.value)
        }
    }
    
    /// Ran out of input bytes while decoding.
    public struct InsufficientInput : NIOHPACKError {
        init() { }
    }
}
