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

/// A simple structure that manages an inbound flow control window.
///
/// For now, this just aims to emit window update frames whenever the flow control window drops below a certain size. It's very naive.
/// We'll worry about the rest of it later.
struct InboundWindowManager {
    private var targetWindowSize: Int32

    /// The last window size we were told about. Used when we get changes to SETTINGS_INITIAL_WINDOW_SIZE.
    private var lastWindowSize: Int?

    /// The number of bytes of buffered frames.
    private var bufferedBytes: Int = 0

    /// Whether the inbound window is closed. If this is true then no window size changes will be emitted.
    var closed = false

    init(targetSize: Int32) {
        assert(targetSize <= HTTP2FlowControlWindow.maxSize)
        assert(targetSize >= 0)

        self.targetWindowSize = targetSize
    }

    mutating func newWindowSize(_ newSize: Int) -> Int? {
        self.lastWindowSize = newSize

        // The new size assumes all frames have been delivered to the stream. This isn't necessarily
        // the case so we need to take the size of any buffered frames into account here.
        return self.calculateWindowIncrement(windowSize: newSize + self.bufferedBytes)
    }

    mutating func initialWindowSizeChanged(delta: Int) -> Int? {
        self.targetWindowSize += Int32(delta)

        if let lastWindowSize = self.lastWindowSize {
            // The delta applies to the current window size as well.
            return self.newWindowSize(lastWindowSize + delta)
        } else {
            return nil
        }
    }

    mutating func bufferedFrameReceived(size: Int) {
        self.bufferedBytes += size
    }

    mutating func bufferedFrameEmitted(size: Int) -> Int? {
        // Consume the bytes we just emitted.
        self.bufferedBytes -= size
        assert(self.bufferedBytes >= 0)

        guard let lastWindowSize = self.lastWindowSize else {
            return nil
        }

        return self.calculateWindowIncrement(windowSize: lastWindowSize + self.bufferedBytes)
    }

    private func calculateWindowIncrement(windowSize: Int) -> Int? {
        // No point calculating an increment if we're closed.
        if self.closed {
            return nil
        }

        // The simplest case is where newSize >= targetWindowSize. In that case, we do nothing.
        //
        // The next simplest case is where 0 <= newSize < targetWindowSize. In that case,
        // if targetWindowSize >= newSize * 2, we update to full size.
        //
        // The other case is where newSize is negative. This can happen. In those cases, we want to
        // increment by Int32.max or the total distance between newSize and targetWindowSize,
        // whichever is *smaller*. This ensures the result fits into Int32.
        if windowSize >= self.targetWindowSize {
            return nil
        } else if windowSize >= 0 {
            let increment = self.targetWindowSize - Int32(windowSize)
            if increment >= windowSize {
                return Int(increment)
            } else {
                return nil
            }
        } else {
            // All math in here happens on 64-bit ints to avoid overflow issues.
            let windowSize = Int64(windowSize)
            let targetWindowSize = Int64(self.targetWindowSize)

            let increment = min(abs(windowSize) + targetWindowSize, Int64(Int32.max))
            return Int(increment)
        }
    }

}
