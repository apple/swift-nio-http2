//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1

/// Very similar to `NIOHTTP1.HTTPHeaders`, but with extra data for storing indexing
/// information.
public struct HPACKHeaders: ExpressibleByDictionaryLiteral, Sendable {
    /// The maximum size of the canonical connection header value array to use when removing
    /// connection headers during `HTTPHeaders` normalisation. When using an array the removal
    /// is O(H·C) where H is the length of headers to noramlize and C is the length of the
    /// connection header value array.
    ///
    /// Beyond this limit we construct a set of the connection header values to reduce the
    /// complexity to O(H).
    ///
    /// We use an array for small connection header lists as it is cheaper (values don't need to be
    /// hashed and constructing a set incurs an additional allocation). The value of 32 was picked
    /// as the crossover point where using an array became more expensive than using a set when
    /// running the `hpackheaders_normalize_httpheaders_removing_10k_conn_headers` performance test
    /// with varying input sizes.
    @usableFromInline
    static let connectionHeaderValueArraySizeLimit = 32

    @usableFromInline
    internal var headers: [HPACKHeader]

    // see 8.1.2.2. Connection-Specific Header Fields in RFC 7540
    @usableFromInline
    static let illegalHeaders: [String] = ["connection", "keep-alive", "proxy-connection",
                                           "transfer-encoding", "upgrade"]

    /// Constructor that can be used to map between `HTTPHeaders` and `HPACKHeaders` types.
    @inlinable
    public init(httpHeaders: HTTPHeaders, normalizeHTTPHeaders: Bool) {
        if normalizeHTTPHeaders {
            self.headers = httpHeaders.map { HPACKHeader(name: $0.name.lowercased(), value: $0.value) }

            let connectionHeaderValue = httpHeaders[canonicalForm: "connection"]

            // Above a limit we use a set rather than scanning the connection header value array.
            // See `Self.connectionHeaderValueArraySizeLimit`.
            if connectionHeaderValue.count > Self.connectionHeaderValueArraySizeLimit {
                var headersToRemove = Set(connectionHeaderValue)
                // Since we have a set we can just merge in the illegal headers.
                headersToRemove.formUnion(Self.illegalHeaders.lazy.map { $0[...] })
                self.headers.removeAll { header in
                    headersToRemove.contains(header.name[...])
                }
            } else {
                self.headers.removeAll { header in
                    connectionHeaderValue.contains(header.name[...]) ||
                        HPACKHeaders.illegalHeaders.contains(header.name)
                }
            }
        } else {
            self.headers = httpHeaders.map { HPACKHeader(name: $0.name, value: $0.value) }
        }
    }

    /// Constructor that can be used to map between `HTTPHeaders` and `HPACKHeaders` types.
    @inlinable
    public init(httpHeaders: HTTPHeaders) {
        self.init(httpHeaders: httpHeaders, normalizeHTTPHeaders: true)
    }

    /// Construct a `HPACKHeaders` structure.
    ///
    /// The indexability of all headers is assumed to be the default, i.e. indexable and
    /// rewritable by proxies.
    ///
    /// - Parameters:
    ///   - headers: An initial set of headers to use to populate the header block.
    @inlinable
    public init(_ headers: [(String, String)] = []) {
        self.headers = headers.map { HPACKHeader(name: $0.0, value: $0.1) }
    }

    /// Construct a `HPACKHeaders` structure.
    ///
    /// The indexability of all headers is assumed to be the default, i.e. indexable and
    /// rewritable by proxies.
    ///
    /// - Parameter elements: name, value pairs provided by a dictionary literal.
    @inlinable
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    /// Construct a `HPACKHeaders` structure.
    ///
    /// The indexability of all headers is assumed to be the default, i.e. indexable and
    /// rewritable by proxies.
    ///
    /// - Parameters:
    ///   - headers: An initial set of headers to use to populate the header block.
    ///   - allocator: The allocator to use to allocate the underlying storage.
    @available(*, deprecated, renamed: "init(_:)")
    public init(_ headers: [(String, String)] = [], allocator: ByteBufferAllocator) {
        // We no longer use an allocator so we don't need this method anymore.
        self.init(headers)
    }

    /// Internal initializer to make things easier for unit tests.
    @inlinable
    init(fullHeaders: [(HPACKIndexing, String, String)]) {
        self.headers = fullHeaders.map { HPACKHeader(name: $0.1, value: $0.2, indexing: $0.0) }
    }

    /// Internal initializer for use in HPACK decoding.
    @inlinable
    init(headers: [HPACKHeader]) {
        self.headers = headers
    }

    /// Add a header name/value pair to the block.
    ///
    /// This method is strictly additive: if there are other values for the given header name
    /// already in the block, this will add a new entry. `add` performs case-insensitive
    /// comparisons on the header field name.
    /// - Parameters:
    ///   - name: The header field name. This must be an ASCII string. For HTTP/2 lowercase
    ///         header names are strongly encouraged.
    ///   - value: The header field value to add for the given name.
    ///   - indexing: The types of indexing and rewriting operations a decoder may take with
    ///         regard to this header.
    @inlinable
    public mutating func add(name: String, value: String, indexing: HPACKIndexing = .indexable) {
        precondition(!name.utf8.contains(where: { !$0.isASCII }), "name must be ASCII")
        self.headers.append(HPACKHeader(name: name, value: value, indexing: indexing))
    }

    /// Add a sequence of header name/value pairs to the block.
    ///
    /// This method is strictly additive: if there are other entries with the same header
    /// name already in the block, this will add new entries.
    ///
    /// - Parameter contentsOf: The sequence of header name/value pairs. Header names must be ASCII
    ///     strings. For HTTP/2 lowercase header names are strongly recommended.
    @inlinable
    public mutating func add<S: Sequence>(contentsOf other: S, indexing: HPACKIndexing = .indexable) where S.Element == (String, String) {
        self.reserveCapacity(self.headers.count + other.underestimatedCount)
        for (name, value) in other {
            self.add(name: name, value: value, indexing: indexing)
        }
    }

    /// Add a sequence of header name/value/indexing triplet to the block.
    ///
    /// This method is strictly additive: if there are other entries with the same header
    /// name already in the block, this will add new entries.
    ///
    /// - Parameter contentsOf: The sequence of header name/value/indexing triplets. Header names
    ///     must be ASCII strings. For HTTP/2 lowercase header names are strongly recommended.
    @inlinable
    public mutating func add<S: Sequence>(contentsOf other: S) where S.Element == HPACKHeaders.Element {
        self.reserveCapacity(self.headers.count + other.underestimatedCount)
        for (name, value, indexing) in other {
            self.add(name: name, value: value, indexing: indexing)
        }
    }

    /// Add a header name/value pair to the block, replacing any previous values for the
    /// same header name that are already in the block.
    ///
    /// This is a supplemental method to `add` that essentially combines `remove` and `add`
    /// in a single function. It can be used to ensure that a header block is in a
    /// well-defined form without having to check whether the value was previously there.
    /// Like `add`, this method performs case-insensitive comparisons of the header field
    /// names.
    ///
    /// - Parameters:
    ///   - name: The header field name. For maximum compatibility this should be an
    ///         ASCII string. For future-proofing with HTTP/2 lowercase header names are strongly
    ///         recommended.
    ///   - value: The header field value to add for the given name.
    ///   - indexing: The types of indexing and rewriting operations a decoder may take with
    ///         regard to this header.
    @inlinable
    public mutating func replaceOrAdd(name: String, value: String, indexing: HPACKIndexing = .indexable) {
        self.remove(name: name)
        self.add(name: name, value: value, indexing: indexing)
    }

    /// Remove all values for a given header name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name.
    ///
    /// - Parameter name: The name of the header field to remove from the block.
    @inlinable
    public mutating func remove(name nameToRemove: String) {
        self.headers.removeAll { header in
            return nameToRemove.isEqualCaseInsensitiveASCIIBytes(to: header.name)
        }
    }

    /// Retrieve all of the values for a given header field name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name. It
    /// does not return a maximally-decomposed list of the header fields, but instead
    /// returns them in their original representation: that means that a comma-separated
    /// header field list may contain more than one entry, some of which contain commas
    /// and some do not. If you want a representation of the header fields suitable for
    /// performing computation on, consider `getCanonicalForm`.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    @inlinable
    public subscript(name: String) -> [String] {
        return self._values(forHeader: name, canonicalForm: false)
    }

    /// Retrieves the first value for a given header field name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name. It
    /// does not return the first value from a maximally-decomposed list of the header fields,
    /// but instead returns the first value from the original representation: that means
    /// that a comma-separated header field list may contain more than one entry, some of
    /// which contain commas and some do not. If you want a representation of the header fields
    /// suitable for performing computation on, consider `getCanonicalForm`.
    ///
    /// - Parameter name: The header field name whose first value should be retrieved.
    /// - Returns: The first value for the header field name.
    @inlinable
    public func first(name: String) -> String? {
        guard !self.headers.isEmpty else {
            return nil
        }

        return self.headers.first { $0.name.isEqualCaseInsensitiveASCIIBytes(to: name) }?.value
    }

    /// Checks if a header is present.
    ///
    /// - Parameters:
    ///   - name: The name of the header
    /// - Returns: `true` if a header with the name (and value) exists, `false` otherwise.
    @inlinable
    public func contains(name: String) -> Bool {
        guard !self.headers.isEmpty else {
            return false
        }

        for header in self.headers {
            if header.name.isEqualCaseInsensitiveASCIIBytes(to: name) {
                return true
            }
        }
        return false
    }

    /// Retrieves the header values for the given header field in "canonical form": that is,
    /// splitting them on commas as extensively as possible such that multiple values received on the
    /// one line are returned as separate entries. Also respects the fact that Set-Cookie should not
    /// be split in this way.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    @inlinable
    public subscript(canonicalForm name: String) -> [String] {
        return self._values(forHeader: name, canonicalForm: true)
    }

    /// Return a sequence of header values for the header field named `name`.
    ///
    /// See also ``HPACKHeaders/subscript(_:)-8qnm8`` and ``HPACKHeaders/subscript(canonicalForm:)``.
    ///
    /// - Parameters:
    ///   - name: The name of the header field whose values should be iterated.
    ///   - canonicalForm: Whether the values should be decomposed into their "canonical form". That
    ///     is, splitting them on commas as extensively as possible such that multiple values
    ///     received on the one line are returned as separate entries.
    /// - Note: Enabling `canonicalForm`  for the 'set-cookie' header has no efffect.
    /// - Returns: A sequence of header values for `name`.
    public func values(forHeader name: String, canonicalForm: Bool = false) -> Values {
        if canonicalForm, name.isEqualCaseInsensitiveASCIIBytes(to: "set-cookie") {
            // Not safe to split 'set-cookie'.
            return Values(headers: self, name: name, canonicalize: false)
        } else {
            return Values(headers: self, name: name, canonicalize: canonicalForm)
        }
    }

    /// Special internal function for use by tests.
    internal subscript(position: Int) -> (String, String) {
        precondition(position < self.headers.endIndex, "Position \(position) is beyond bounds of \(self.headers.endIndex)")
        let header = self.headers[position]
        return (header.name, header.value)
    }

    @inlinable
    internal func _values(forHeader name: String, canonicalForm: Bool) -> [String] {
        let values = self.values(forHeader: name, canonicalForm: canonicalForm)
        var iterator = values.makeIterator()

        guard let first = iterator.next() else {
            // No value, no allocation.
            return []
        }

        var headerValues = [String]()
        // Avoid intermediate allocations by overcomitting on capacity. Note: may be an undercommit
        // if the canonical form is being fetched.
        headerValues.reserveCapacity(self.headers.count)
        headerValues.append(String(first))
        while let next = iterator.next() {
            headerValues.append(String(next))
        }

        return headerValues
    }
}

extension HPACKHeaders {
    public struct Values: Sequence {
        public typealias Element = Substring

        private let headers: HPACKHeaders
        private let name: String
        private let canonicalize: Bool

        fileprivate init(headers: HPACKHeaders, name: String, canonicalize: Bool) {
            self.headers = headers
            self.name = name
            self.canonicalize = canonicalize
        }

        public func makeIterator() -> Iterator {
            return Iterator(headers: self.headers, name: self.name, canonicalize: self.canonicalize)
        }
    }
}

extension HPACKHeaders.Values {
    public struct Iterator: IteratorProtocol {
        /// The header name to look for.
        private let name: String
        /// Whether the header values should be split.
        private let shouldSplit: Bool

        /// An iterator for the header values.
        private var headerIterator: Array<HPACKHeader>.Iterator
        /// An iterator for splitting a given header value.
        private var splittingIterator: String.UTF8View.LazyUTF8ViewSplitSequence.Iterator?

        fileprivate init(headers: HPACKHeaders, name: String, canonicalize: Bool) {
            self.headerIterator = headers.headers.makeIterator()
            self.splittingIterator = nil
            self.name = name
            self.shouldSplit = canonicalize
        }

        public mutating func next() -> Substring? {
            while true {
                switch self.process() {
                case .emit(let value):
                    return value
                case .continueProcessing:
                    continue
                }
            }
        }

        private enum NextStep {
            case emit(Substring?)
            case continueProcessing
        }

        private mutating func process() -> NextStep {
            // If there's a splitting iterator, spin through that first.
            if var splittingIterator = self.splittingIterator {
                while let nextFragment = splittingIterator.next() {
                    let trimmed = nextFragment._trimWhitespace()

                    if !trimmed.isEmpty {
                        // Non-empty, emit the value.
                        self.splittingIterator = splittingIterator
                        return .emit(Substring(trimmed))
                    }
                }

                // Exhausted the iterator, switch back to iterating plain values.
                self.splittingIterator = nil
                return .continueProcessing
            } else {
                while let next = self.headerIterator.next() {
                    if next.name.isEqualCaseInsensitiveASCIIBytes(to: self.name) {
                        // A match: do we need to split it?
                        if self.shouldSplit {
                            let split = next.value.utf8._lazySplit(separator: UInt8(ascii: ","))
                            // Spin through the splitting iterator next.
                            self.splittingIterator = split.makeIterator()
                            return .continueProcessing
                        } else {
                            return .emit(next.value[...])
                        }
                    }
                }

                // Exhausted the value iterator; we're done.
                return .emit(nil)
            }
        }
    }
}

extension HPACKHeaders {
    /// The total number of headers that can be contained without allocating new storage.
    @inlinable
    public var capacity: Int {
        return self.headers.capacity
    }

    /// Reserves enough space to store the specified number of headers.
    ///
    /// - Parameter minimumCapacity: The requested number of headers to store.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        self.headers.reserveCapacity(minimumCapacity)
    }

    /// Removes all headers whilst optionally keeping the capacity.
    ///
    /// - Parameter keepingCapacity: Whether to keep the underlying memory or not. Use this flag to
    ///                              reduce allocations when reusing the header collection.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = false) {
        self.headers.removeAll(keepingCapacity: keepingCapacity)
    }
}

extension HPACKHeaders: RandomAccessCollection {
    public typealias Element = (name: String, value: String, indexable: HPACKIndexing)

    public struct Index: Comparable {
        @usableFromInline
        let _base: Array<HPACKHeaders>.Index

        @inlinable
        init(_base: Array<HPACKHeaders>.Index) {
            self._base = _base
        }

        @inlinable
        public static func < (lhs: Index, rhs: Index) -> Bool {
            return lhs._base < rhs._base
        }
    }

    @inlinable
    public var startIndex: HPACKHeaders.Index {
        return .init(_base: self.headers.startIndex)
    }

    @inlinable
    public var endIndex: HPACKHeaders.Index {
        return .init(_base: self.headers.endIndex)
    }

    @inlinable
    public func index(before i: HPACKHeaders.Index) -> HPACKHeaders.Index {
        return .init(_base: self.headers.index(before: i._base))
    }

    @inlinable
    public func index(after i: HPACKHeaders.Index) -> HPACKHeaders.Index {
        return .init(_base: self.headers.index(after: i._base))
    }

    @inlinable
    public subscript(position: HPACKHeaders.Index) -> Element {
        let element = self.headers[position._base]
        return (name: element.name, value: element.value, indexable: element.indexing)
    }

    // Why are we providing an `Iterator` when we could just use the default one?
    // The answer is that we changed from Sequence to RandomAccessCollection in a SemVer minor release. The
    // previous code had a special-case Iterator, and so to avoid breaking that abstraction we need to provide one
    // here too. Happily, however, we can simply delegate to the underlying Iterator type.

    /// An iterator of HTTP header fields.
    ///
    /// This iterator will return each value for a given header name separately. That
    /// means that `name` is not guaranteed to be unique in a given block of headers.
    public struct Iterator: IteratorProtocol {
        @usableFromInline
        var _base: Array<HPACKHeader>.Iterator

        @inlinable
        init(_ base: HPACKHeaders) {
            self._base = base.headers.makeIterator()
        }

        @inlinable
        public mutating func next() -> Element? {
            guard let element = self._base.next() else {
                return nil
            }
            return (name: element.name, value: element.value, indexable: element.indexing)
        }
    }

    @inlinable
    public func makeIterator() -> HPACKHeaders.Iterator {
        return Iterator(self)
    }
}


extension HPACKHeaders: CustomStringConvertible {
    public var description: String {
        var headersArray: [(HPACKIndexing, String, String)] = []
        headersArray.reserveCapacity(self.headers.count)

        for h in self.headers {
            headersArray.append((h.indexing, h.name, h.value))
        }
        return headersArray.description
    }
}

// NOTE: This is a bad definition of equatable and hashable. In particular, both order and
// indexability are ignored. We should change it, but we should be careful when we do so.
// More discussion at https://github.com/apple/swift-nio-http2/issues/342.
extension HPACKHeaders: Equatable {
    @inlinable
    public static func ==(lhs: HPACKHeaders, rhs: HPACKHeaders) -> Bool {
        guard lhs.headers.count == rhs.headers.count else {
            return false
        }
        let lhsNames = Set(lhs.headers.map { $0.name })
        let rhsNames = Set(rhs.headers.map { $0.name })
        guard lhsNames == rhsNames else {
            return false
        }

        for name in lhsNames {
            guard lhs[name].sorted() == rhs[name].sorted() else {
                return false
            }
        }

        return true
    }
}

extension HPACKHeaders: Hashable {
    @inlinable
    public func hash(into hasher: inout Hasher) {
        // Discriminator, to indicate that this is a collection. This improves the performance
        // of Sets and Dictionaries that include collections of HPACKHeaders by reducing hash collisions.
        hasher.combine(self.count)

        // This emulates the logic used in equatability, but we sort it to ensure that
        // we hash equivalently.
        let names = Set(self.headers.lazy.map { $0.name }).sorted()
        for name in names {
            hasher.combine(self[name].sorted())
        }
    }
}

/// Defines the types of indexing and rewriting operations a decoder may take with
/// regard to this header.
public enum HPACKIndexing: CustomStringConvertible, Sendable {
    /// Header may be written into the dynamic index table or may be rewritten by
    /// proxy servers.
    case indexable
    /// Header is not written to the dynamic index table, but proxies may rewrite
    /// it en-route, as long as they preserve its non-indexable attribute.
    case nonIndexable
    /// Header may not be written to the dynamic index table, and proxies must
    /// pass it on as-is without rewriting.
    case neverIndexed

    public var description: String {
        switch self {
        case .indexable:
            return "[]"
        case .nonIndexable:
            return "[non-indexable]"
        case .neverIndexed:
            return "[neverIndexed]"
        }
    }
}

@usableFromInline
internal struct HPACKHeader: Sendable {
    @usableFromInline
    var indexing: HPACKIndexing

    @usableFromInline
    var name: String

    @usableFromInline
    var value: String

    @inlinable
    internal init(name: String, value: String, indexing: HPACKIndexing = .indexable) {
        self.indexing = indexing
        self.name = name
        self.value = value
    }
}


extension HPACKHeader {
    @inlinable
    internal var size: Int {
        // RFC 7541 § 4.1:
        //
        //      The size of an entry is the sum of its name's length in octets (as defined in
        //      Section 5.2), its value's length in octets, and 32.
        //
        //      The size of an entry is calculated using the length of its name and value
        //      without any Huffman encoding applied.
        return name.utf8.count + value.utf8.count + 32
    }
}


internal extension UInt8 {
    @inlinable
    var isASCII: Bool {
        return self <= 127
    }
}

/* private but inlinable */
internal extension UTF8.CodeUnit {
    @inlinable
    var isASCIIWhitespace: Bool {
        switch self {
        case UInt8(ascii: " "),
             UInt8(ascii: "\t"):
            return true
        default:
            return false
        }
    }
}

extension Substring.UTF8View {
    @inlinable
    func _trimWhitespace() -> Substring.UTF8View {
        guard let firstNonWhitespace = self.firstIndex(where: { !$0.isASCIIWhitespace }) else {
           // The whole substring is ASCII whitespace.
            return Substring().utf8
        }

        // There must be at least one non-ascii whitespace character, so banging here is safe.
        let lastNonWhitespace = self.lastIndex(where: { !$0.isASCIIWhitespace })!
        return self[firstNonWhitespace...lastNonWhitespace]
    }
}

extension String.UTF8View {
    @inlinable
    func _lazySplit(separator: UTF8.CodeUnit) -> LazyUTF8ViewSplitSequence {
        return LazyUTF8ViewSplitSequence(self, separator: separator)
    }

    @usableFromInline
    struct LazyUTF8ViewSplitSequence: Sequence {
        @usableFromInline typealias Element = Substring.UTF8View

        @usableFromInline var _baseView: String.UTF8View
        @usableFromInline var _separator: UTF8.CodeUnit

        @inlinable
        init(_ baseView: String.UTF8View, separator: UTF8.CodeUnit) {
            self._baseView = baseView
            self._separator = separator
        }

        @inlinable
        func makeIterator() -> Iterator {
            return Iterator(self)
        }

        @usableFromInline
        struct Iterator: IteratorProtocol {
            @usableFromInline var _base: LazyUTF8ViewSplitSequence
            @usableFromInline var _lastSplitIndex: Substring.UTF8View.Index

            @inlinable
            init(_ base: LazyUTF8ViewSplitSequence) {
                self._base = base
                self._lastSplitIndex = base._baseView.startIndex
            }

            @inlinable
            mutating func next() -> Substring.UTF8View? {
                let endIndex = self._base._baseView.endIndex

                guard self._lastSplitIndex != endIndex else {
                    return nil
                }

                let restSlice = self._base._baseView[self._lastSplitIndex...]

                if let nextSplitIndex = restSlice.firstIndex(of: self._base._separator) {
                    // The separator is present. We want to drop the separator, so we need to advance the index past this point.
                    self._lastSplitIndex = self._base._baseView.index(after: nextSplitIndex)
                    return restSlice[..<nextSplitIndex]
                } else {
                    // The separator isn't present, so we want the entire rest of the slice.
                    self._lastSplitIndex = self._base._baseView.endIndex
                    return restSlice
                }
            }
        }
    }
}


extension String.UTF8View {
    /// Compares two UTF8 strings as case insensitive ASCII bytes.
    ///
    /// - Parameter bytes: The string constant in the form of a collection of `UInt8`
    /// - Returns: Whether the collection contains **EXACTLY** this array or no, but by ignoring case.
    @inlinable
    func compareCaseInsensitiveASCIIBytes(to other: String.UTF8View) -> Bool {
            // fast path: we can get the underlying bytes of both
            let maybeMaybeResult = self.withContiguousStorageIfAvailable { lhsBuffer -> Bool? in
                other.withContiguousStorageIfAvailable { rhsBuffer in
                    if lhsBuffer.count != rhsBuffer.count {
                        return false
                    }

                    for idx in 0 ..< lhsBuffer.count {
                        // let's hope this gets vectorised ;)
                        if lhsBuffer[idx] & 0xdf != rhsBuffer[idx] & 0xdf && lhsBuffer[idx].isASCII {
                            return false
                        }
                    }
                    return true
                }
            }

            if let maybeResult = maybeMaybeResult, let result = maybeResult {
                return result
            } else {
                return self._compareCaseInsensitiveASCIIBytesSlowPath(to: other)
            }
    }

    @inlinable
    @inline(never)
    func _compareCaseInsensitiveASCIIBytesSlowPath(to other: String.UTF8View) -> Bool {
        return self.elementsEqual(other, by: { return (($0 & 0xdf) == ($1 & 0xdf) && $0.isASCII) })
    }
}


extension String {
    @inlinable
    internal func isEqualCaseInsensitiveASCIIBytes(to: String) -> Bool {
        return self.utf8.compareCaseInsensitiveASCIIBytes(to: to.utf8)
    }
}
