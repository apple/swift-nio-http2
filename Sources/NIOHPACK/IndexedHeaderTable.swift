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

/// The unified header table used by HTTP/2, encompassing both static and dynamic tables.
public struct IndexedHeaderTable {
    // private but tests
    let staticTable: HeaderTableStorage
    var dynamicTable: DynamicHeaderTable
    
    /// Creates a new header table, optionally specifying a maximum size for the dynamic
    /// portion of the table.
    ///
    /// - Parameter maxDynamicTableSize: Maximum size of the dynamic table. Default = 4096.
    init(allocator: ByteBufferAllocator, maxDynamicTableSize: Int = DynamicHeaderTable.defaultSize) {
        self.staticTable = HeaderTableStorage(allocator: allocator, staticHeaderList: StaticHeaderTable)
        self.dynamicTable = DynamicHeaderTable(maximumLength: maxDynamicTableSize, allocator: allocator)
    }
    
    /// Obtains the header key/value pair at the given index within the table.
    ///
    /// - note: Per RFC 7541, this uses a *1-based* index.
    /// - Parameter index: The index to query.
    /// - Returns: A tuple containing the name and value of the stored header.
    /// - Throws: `NIOHPACKErrors.InvalidHeaderIndex` if the supplied index was invalid.
    public func header(at index: Int) throws -> (name: String, value: String) {
        let (nameView, valueView) = try self.headerViews(at: index)
        return (String(decoding: nameView, as: UTF8.self), String(decoding: valueView, as: UTF8.self))
    }
    
    /// Obtains the header key/value pair at the given index within the table as sequences of
    /// raw bytes.
    ///
    /// - note: Per RFC 7541, this uses a *1-based* index.
    /// - Parameter index: The index to query.
    /// - Returns: A tuple containing the name and value of the stored header.
    /// - Throws: `NIOHPACKErrors.InvalidHeaderIndex` if the supplied index was invalid.
    public func headerViews(at index: Int) throws -> (name: ByteBufferView, value: ByteBufferView) {
        let result: (ByteBufferView, ByteBufferView)
        if index < self.staticTable.count {
            let entry = self.staticTable[index]
            result = (self.staticTable.view(of: entry.name), self.staticTable.view(of: entry.value))
        } else if index - self.staticTable.count < self.dynamicTable.count {
            let entry = self.dynamicTable[index - self.staticTable.count]
            result = (self.dynamicTable.view(of: entry.name), self.dynamicTable.view(of: entry.value))
        } else {
            throw NIOHPACKErrors.InvalidHeaderIndex(suppliedIndex: index, availableIndex: self.staticTable.count + self.dynamicTable.count - 1)
        }
        
        return result
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
    public func firstHeaderMatch(for name: String, value: String?) -> (index: Int, matchesValue: Bool)? {
        return self.firstHeaderMatch(for: name.utf8, value: value?.utf8)
    }
    
    func firstHeaderMatch<Name: Collection, Value: Collection>(for name: Name, value: Value?) -> (index: Int, matchesValue: Bool)? where Name.Element == UInt8, Value.Element == UInt8 {
        guard let value = value else {
            return self.staticTable.indices(matching: name).first.map { ($0, false) }
        }
        
        var firstHeaderIndex: Int? = nil
        for index in self.staticTable.indices(matching: name) {
            // we've found a name, at least
            if firstHeaderIndex == nil {
                firstHeaderIndex = index
            }
            
            if self.staticTable.view(of: self.staticTable[index].value).matches(value) {
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
    public mutating func add(headerNamed name: String, value: String) throws {
        try self.add(headerNamed: name.utf8, value: value.utf8)
    }
    
    /// Appends a header to the table.
    ///
    /// This call may result in an empty table, as per RFC 7541 § 4.4:
    /// > "It is not an error to attempt to add an entry that is larger than the maximum size;
    /// > an attempt to add an entry larger than the maximum size causes the table to be
    /// > emptied of all existing entries and results in an empty table."
    ///
    /// - Parameters:
    ///   - name: A sequence of contiguous bytes containing the name of the header to insert.
    ///   - value: A sequence of contiguous bytes containing the value of the header to insert.
    public mutating func add<Name: ContiguousCollection, Value: ContiguousCollection>(headerNameBytes nameBytes: Name, valueBytes: Value) throws where Name.Element == UInt8, Value.Element == UInt8 {
        try self.dynamicTable.addHeader(nameBytes: nameBytes, valueBytes: valueBytes)
    }
    
    /// An internal variant, where we've already deconstructed the String into its UTF-8 bytes.
    internal mutating func add<Name: Collection, Value: Collection>(headerNamed name: Name, value: Value) throws where Name.Element == UInt8, Value.Element == UInt8 {
        try self.dynamicTable.addHeader(named: name, value: value)
    }
    
    /// Internal for test access.
    internal func dumpHeaders() -> String {
        return "\(staticTable.dumpHeaders())\n\(dynamicTable.dumpHeaders())"
    }
    
    /// The length, in bytes, of the dynamic portion of the header table.
    public var dynamicTableLength: Int {
        return self.dynamicTable.length
    }
    
    /// The current allowed length of the dynamic portion of the header table. May be
    /// less than the current protocol-assigned maximum supplied by a SETTINGS frame.
    public var dynamicTableAllowedLength: Int {
        get { return self.dynamicTable.allowedLength }
        set { self.dynamicTable.allowedLength = newValue }
    }
    
    /// The hard limit on the size to which the dynamic table may grow. Only a SETTINGS
    /// frame can change this: it can't grow beyond this size due to changes within
    /// header blocks.
    public var maxDynamicTableLength: Int {
        get { return self.dynamicTable.maximumTableLength }
        set { self.dynamicTable.maximumTableLength = newValue }
    }
}
