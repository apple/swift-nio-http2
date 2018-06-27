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

/// The unified header table used by HTTP/2, encompassing both static and dynamic tables.
public class IndexedHeaderTable {
    // private but tests
    var dynamicTable: DynamicHeaderTable
    
    /// Creates a new header table, optionally specifying a maximum size for the dynamic
    /// portion of the table.
    ///
    /// - Parameter maxDynamicTableSize: Maximum size of the dynamic table. Default = 4096.
    init(maxDynamicTableSize: Int = DynamicHeaderTable.defaultSize) {
        self.dynamicTable = DynamicHeaderTable(maximumLength: maxDynamicTableSize)
    }
    
    /// Obtains the header key/value pair at the given index within the table.
    ///
    /// - note: Per RFC 7541, this uses a *1-based* index.
    /// - Parameter index: The index to query.
    /// - Returns: A tuple containing the name and value of the stored header, or `nil` if
    ///            the index was not valid.
    public func header(at index: Int) -> (name: String, value: String)? {
        let entry: HeaderTableEntry
        if index < StaticHeaderTable.count {
            entry = StaticHeaderTable[index]    // static table is already 1-based
        } else if index - StaticHeaderTable.count < self.dynamicTable.count {
            entry = self.dynamicTable[index - StaticHeaderTable.count]
        } else {
            return nil
        }
        
        return (entry.name, entry.value ?? "")
    }
    
    /// Searches the table to locate an existing header with the given name and value. If
    /// no item exists that contains a matching value, it will return the index of the first
    /// item with a matching header name instead, to be encoded as index+value.
    ///
    /// - Parameters:
    ///   - name: The name of the header to locate.
    ///   - value: The value for which to search.
    /// - Returns: A tuple containing the index of any located header, and a boolean indicating
    ///            whether the item at that index also contains a matching value. Returns `nil`
    ///            if no match could be found.
    public func firstHeaderMatch(for name: String, value: String) -> (index: Int, matchesValue: Bool)? {
        var firstHeaderIndex: Int? = nil
        for (index, entry) in StaticHeaderTable.enumerated() where entry.name == name {
            // we've found a name, at least
            if firstHeaderIndex == nil {
                firstHeaderIndex = index
            }
            
            if entry.value == value {
                return (index, true)
            }
        }
        
        // no complete match: search the dynamic table now
        if let result = self.dynamicTable.findExistingHeader(named: name, value: value) {
            if let staticIndex = firstHeaderIndex, result.containsValue == false {
                // Dynamic table can't match the value, and we have a name match in the static
                // table. In this case, we prefer the static table.
                return (staticIndex, false)
            } else {
                // Either no match in the static table, or the dynamic table has a header with
                // a matching value. Return that, but update the index appropriately.
                return (result.index + StaticHeaderTable.count, result.containsValue)
            }
        } else if let staticIndex = firstHeaderIndex {
            // nothing in the dynamic table, but the static table had a name match
            return (staticIndex, false)
        } else {
            // no match anywhere, you'll have to encode the whole thing
            return nil
        }
    }
    
    /// Appends a header to the table.
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
    public func append(headerNamed name: String, value: String) -> Bool {
        return self.dynamicTable.appendHeader(named: name, value: value)
    }
    
    /// The length, in bytes, of the dynamic portion of the header table.
    public var dynamicTableLength: Int {
        return self.dynamicTable.length
    }
    
    /// The maximum allowed length of the dynamic portion of the header table.
    public var maxDynamicTableLength: Int {
        get { return self.dynamicTable.maximumLength }
        set { self.dynamicTable.maximumLength = newValue }
    }
}
