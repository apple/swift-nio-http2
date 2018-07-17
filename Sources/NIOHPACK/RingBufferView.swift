//
//  RingBufferView.swift
//  NIOHPACK
//
//  Created by Jim Dovey on 7/10/18.
//

import NIO

public struct RingBufferView : ContiguousCollection, RandomAccessCollection {
    public typealias Element = UInt8
    public typealias Index = Int
    public typealias SubSequence = RingBufferView
    
    private let buffer: SimpleRingBuffer
    private let range: Range<Index>
    
    internal init(buffer: SimpleRingBuffer, range: Range<Index>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.capacity)
        self.buffer = buffer
        self.range = range
    }
    
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try self.buffer.withVeryUnsafeBytes { ptr in
            try body(UnsafeRawBufferPointer(start: ptr.baseAddress!.advanced(by: self.range.lowerBound),
                                            count: self.range.count))
        }
    }
    
    public var startIndex: Int {
        return range.lowerBound
    }
    
    public var endIndex: Int {
        return range.upperBound
    }
    
    public func index(after i: Int) -> Int {
        return i + 1
    }
    
    public subscript(position: Int) -> UInt8 {
        guard position >= self.range.lowerBound && position < self.range.upperBound else {
            preconditionFailure("index \(position) out of range")
        }
        return self.buffer.withVeryUnsafeBytes { ptr in
            return ptr[position]
        }
    }
    
    public subscript(range: Range<Index>) -> RingBufferView {
        return RingBufferView(buffer: self.buffer, range: range)
    }
    
    public func matches<C: ContiguousCollection>(_ other: C) -> Bool where C.Element == UInt8 {
        return self.withUnsafeBytes { myBytes in
            return other.withUnsafeBytes { theirBytes in
                guard myBytes.count == theirBytes.count else {
                    return false
                }
                return memcmp(myBytes.baseAddress!, theirBytes.baseAddress!, myBytes.count) == 0
            }
        }
    }
    
    public func matches<S: Sequence>(_ other: S) -> Bool where S.Element == UInt8 {
        return self.elementsEqual(other)
    }
}

public extension SimpleRingBuffer {
    public func viewBytes(at index: Int, length: Int) -> RingBufferView {
        let endIndex = index + length
        if endIndex < self.capacity {
            return RingBufferView(buffer: self, range: index ..< endIndex)
        } else {
            // need to allocate a copy to get contiguous access :(
            // the copy will be rebased, so we need to adjust the input range
            let range = index - self.readerIndex ..< endIndex - self.readerIndex
            return RingBufferView(buffer: self._makeContiguousCopy(), range: range)
        }
    }
}
