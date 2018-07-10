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

struct DynamicHeaderTable {
    public static let defaultSize = 4096
    
    /// The actual table, with items looked up by index.
    private var storage: HeaderTableStorage
    
    /// List of indexes to actual values within the table.
    
    
    /// The length of the contents of the table.
    var length: Int {
        return self.storage.length
    }
    
    /// The maximum size to which the dynamic table may grow.
    var maximumLength: Int {
        get {
            return self.storage.maxSize
        }
        set {
            self.storage.setTableSize(to: newValue)
        }
    }
    
    /// The number of items in the table.
    var count: Int {
        return self.storage.count
    }
    
    init(maximumLength: Int = DynamicHeaderTable.defaultSize, allocator: ByteBufferAllocator = ByteBufferAllocator()) {
        self.storage = HeaderTableStorage(maxSize: maximumLength, allocator: allocator)
    }
    
    /// Subscripts into the dynamic table alone, using a zero-based index.
    subscript(i: Int) -> HeaderTableEntry {
        return self.storage[i]
    }
    
    func view(of index: HPACKHeaderIndex) -> RingBufferView {
        return self.storage.view(of: index)
    }
    
    // internal for testing
    func dumpHeaders() -> String {
        return self.storage.dumpHeaders()
    }
    
    /// Searches the table for a matching header, optionally with a particular value. If
    /// a match is found, returns the index of the item and an indication whether it contained
    /// the matching value as well.
    ///
    /// Invariants: If `value` is `nil`, result `containsValue` is `false`.
    ///
    /// - Parameters:
    ///   - name: The name of the header for which to search.
    ///   - value: Optional value for the header to find. Default is `nil`.
    /// - Returns: A tuple containing the matching index and, if a value was specified as a
    ///            parameter, an indication whether that value was also found. Returns `nil`
    ///            if no matching header name could be located.
    func findExistingHeader<C : Collection>(named name: C, value: C? = nil) -> (index: Int, containsValue: Bool)? where C.Element == UInt8 {
        // looking for both name and value, but can settle for just name
        // thus we'll search manually.
        // TODO: there's probably a better algorithm for this.
        var firstNameMatch: Int? = nil
        for index in self.storage.indices(matching: name) {
            if firstNameMatch == nil {
                // record the first (most recent) index with a matching header name,
                // in case there's no value match.
                firstNameMatch = index
            }
            
            if let value = value, self.storage.view(of: self.storage[index].value).matches(value) {
                // this entry has both the name and the value we're seeking
                return (index, true)
            }
        }
        
        // no value matches -- but did we find a name?
        if let index = firstNameMatch {
            return (index, false)
        } else {
            // no matches at all
            return nil
        }
    }
    
    /// Appends a header to the table. Note that if this succeeds, the new item's index
    /// is always zero.
    ///
    /// This call may result in an empty table, as per RFC 7541 § 4.4:
    /// > "It is not an error to attempt to add an entry that is larger than the maximum size;
    /// > an attempt to add an entry larger than the maximum size causes the table to be
    /// > emptied of all existing entries and results in an empty table."
    ///
    /// - Parameters:
    ///   - name: A collection of UTF-8 code points comprising the name of the header to insert.
    ///   - value: A collection of UTF-8 code points comprising the value of the header to insert.
    ///   - evictAutomatically: If `true`, the table will evict existing items to make room. Default is `true`.
    /// - Returns: `true` if the header was added to the table, `false` if not.
    mutating func addHeader<C : Collection>(named name: C, value: C, evictAutomatically: Bool = true) throws where C.Element == UInt8 {
        do {
            try self.storage.add(name: name, value: value)
        } catch let error as RingBufferError.BufferOverrun {
            if evictAutomatically {
                // purge from the table and try again
                
                // if there's still not enough room, then the entry is too large for the table
                // note that the HTTP2 spec states that we should make this check AFTER evicting
                // the table's contents: http://httpwg.org/specs/rfc7541.html#entry.addition
                //
                //  "It is not an error to attempt to add an entry that is larger than the maximum size; an
                //   attempt to add an entry larger than the maximum size causes the table to be emptied of
                //   all existing entries and results in an empty table."
                
                self.storage.purge(toRelease: error.amount)
                return try self.addHeader(named: name, value: value, evictAutomatically: false)
            } else {
                // ping the error up the stack, with more information
                throw NIOHPACKErrors.FailedToAddIndexedHeader(bytesNeeded: self.storage.length + error.amount,
                                                              name: String(decoding: name, as: UTF8.self),
                                                              value: String(decoding: value, as: UTF8.self))
            }
        }
    }
    
    /// Appends a header to the table. Note that if this succeeds, the new item's index
    /// is always zero.
    ///
    /// This call may result in an empty table, as per RFC 7541 § 4.4:
    /// > "It is not an error to attempt to add an entry that is larger than the maximum size;
    /// > an attempt to add an entry larger than the maximum size causes the table to be
    /// > emptied of all existing entries and results in an empty table."
    ///
    /// - Parameters:
    ///   - name: A contiguous collection of UTF-8 bytes comprising the name of the header to insert.
    ///   - value: A contiguous collection of UTF-8 bytes comprising the value of the header to insert.
    ///   - evictAutomatically: If `true`, the table will evict existing items to make room. Default is `true`.
    /// - Returns: `true` if the header was added to the table, `false` if not.
    mutating func addHeader<C : ContiguousCollection>(nameBytes: C, valueBytes: C, evictAutomatically: Bool = true) throws where C.Element == UInt8 {
        do {
            try self.storage.add(nameBytes: nameBytes, valueBytes: valueBytes)
        } catch let error as RingBufferError.BufferOverrun {
            if evictAutomatically {
                self.storage.purge(toRelease: error.amount)
                return try self.addHeader(nameBytes: nameBytes, valueBytes: valueBytes, evictAutomatically: false)
            } else {
                throw NIOHPACKErrors.FailedToAddIndexedHeader(bytesNeeded: self.storage.length + error.amount,
                                                              name: String(decoding: nameBytes, as: UTF8.self),
                                                              value: String(decoding: valueBytes, as: UTF8.self))
            }
        }
    }
}
