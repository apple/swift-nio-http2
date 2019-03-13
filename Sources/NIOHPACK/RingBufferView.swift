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

extension ByteBufferView {
    @inlinable
    internal func matches<S: Sequence>(_ other: S) -> Bool where S.Element == UInt8 {
        return self.elementsEqual(other)
    }
}

extension StringRing {
    func viewBytes(at index: Int, length: Int) -> ByteBufferView {
        // We force unwrap in here as the backing buffer of a StringRing is always entirely readable.
        let endIndex = index + length
        if endIndex < self.capacity {
            return self._storage.viewBytes(at: index, length: length)!
        } else {
            // need to allocate a copy to get contiguous access :(
            // we know this will work, because we're constraining the bounds
            var buf = self._storage.getSlice(at: index, length: self._storage.capacity - index)!
            _ = buf.writeBytes(self._storage.viewBytes(at: 0, length: length - buf.readableBytes)!)
            return buf.readableBytesView
        }
    }
}
