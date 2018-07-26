//
//  ByteBufferView.swift
//  NIOHPACK
//
//  Created by Jim Dovey on 7/10/18.
//

import NIO

extension ByteBufferView {
    @_inlineable
    @_specialize(where C == ByteBufferView)
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
    
    @_inlineable
    @_specialize(where S == String.UTF8View)
    public func matches<S: Sequence>(_ other: S) -> Bool where S.Element == UInt8 {
        return self.elementsEqual(other)
    }
}

extension StringRing {
    func viewBytes(at index: Int, length: Int) -> ByteBufferView {
        let endIndex = index + length
        if endIndex < self.capacity {
            return self._storage.viewBytes(at: index, length: length)
        } else {
            // need to allocate a copy to get contiguous access :(
            // we know this will work, because we're constraining the bounds
            var buf = self._storage.getSlice(at: index, length: self._storage.capacity - index)!
            buf.write(bytes: self._storage.viewBytes(at: 0, length: length - buf.readableBytes))
            return buf.readableBytesView
        }
    }
}
