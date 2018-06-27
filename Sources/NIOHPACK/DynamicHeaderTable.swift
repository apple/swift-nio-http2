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

import NIOConcurrencyHelpers

class DynamicHeaderTable {
    public static let defaultSize = 4096
    typealias HeaderTableStore = Array<HeaderTableEntry>
    
    /// The actual table, with items looked up by index.
    fileprivate var table: HeaderTableStore = []
    
    fileprivate var lock = ReadWriteLock()
    
    /// The length of the contents of the table.
    ///
    /// The length of a single entry is defined as the sum of the UTF-8 octet
    /// lengths of its name and value strings plus 32.
    var length: Int {
        return self.table.reduce(0) { $0 + $1.length }
    }
    
    /// The maximum size to which the dynamic table may grow.
    var maximumLength: Int {
        didSet {
            if self.length > self.maximumLength {
                self.purge()
            }
        }
    }
    
    /// The number of items in the table.
    var count: Int {
        return self.table.count
    }
    
    init(maximumLength: Int = DynamicHeaderTable.defaultSize) {
        self.maximumLength = maximumLength
    }
    
    subscript(i: Int) -> HeaderTableEntry {
        return self.table[i]
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
    func findExistingHeader(named name: String, value: String? = nil) -> (index: Int, containsValue: Bool)? {
        return self.lock.withReadLock {
            guard let value = value else {
                // not looking to match a value, so we can defer to stdlib functions.
                if let index = self.table.index(where: { $0.name == name }) {
                    return (index, false)
                }
                
                return nil
            }
            
            // looking for both name and value, but can settle for just name
            // thus we'll search manually.
            // TODO: there's probably a better algorithm for this.
            var firstNameMatch: Int? = nil
            for (index, entry) in self.table.enumerated() where entry.name == name {
                if firstNameMatch == nil {
                    // record the first (most recent) index with a matching header name,
                    // in case there's no value match.
                    firstNameMatch = index
                }
                
                if entry.value == value {
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
    ///   - name: The name of the header to insert.
    ///   - value: The value of the header to insert.
    /// - Returns: `true` if the header was added to the table, `false` if not.
    func appendHeader(named name: String, value: String) -> Bool {
        return self.lock.withWriteLock {
            let entry = HeaderTableEntry(name: name, value: value)
            if self.length + entry.length > self.maximumLength {
                self.evict(atLeast: entry.length - (self.maximumLength - self.length))
                
                // if there's still not enough room, then the entry is too large for the table
                // note that the HTTP2 spec states that we should make this check AFTER evicting
                // the table's contents: http://httpwg.org/specs/rfc7541.html#entry.addition
                //
                //  "It is not an error to attempt to add an entry that is larger than the maximum size; an
                //   attempt to add an entry larger than the maximum size causes the table to be emptied of
                //   all existing entries and results in an empty table."
                
                guard self.length + entry.length <= self.maximumLength else {
                    return false
                }
            }
            
            // insert the new item at the start of the array
            // trust to the implementation to handle this nicely
            self.table.insert(entry, at: 0)
            return true
        }
    }
    
    private func purge() {
        lock.withWriteLockVoid {
            if self.length <= self.maximumLength {
                return
            }
            
            self.evict(atLeast: self.length - self.maximumLength)
        }
    }
    
    /// Edits the table directly. Only call while write-lock is held.
    private func evict(atLeast lengthToRelease: Int) {
        var lenReleased = 0
        var numRemoved = 0
        
        // The HPACK spec dictates that entries be remove from the end of the table
        // (i.e. oldest removed first).
        // We scan backwards counting sizes until we meet the amount we need, then
        // we remove everything in a single call.
        for entry in self.table.reversed() {
            lenReleased += entry.length
            numRemoved += 1
            
            if (lenReleased >= lengthToRelease) {
                break
            }
        }
        
        self.table.removeLast(numRemoved)
    }
}
