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

/// Keeps track of whether or not a `Channel` should be able to write based on watermarks.
///
/// A `WatermarkedFlowController` is a straightforward object that keeps track of
/// the number of to-be-written bytes in a `Channel`, as well as the trajectory of those
/// bytes. This allows a `Channel` to buffer a certain number of bytes before flipping its
/// writability state, and then allows draining to a different watermark before the state flips
/// again.
///
/// The goal here is to constrain the number of resources allocated for a task, while also ensuring
/// that `Channel` writability state doesn't flick between writable and not-writable rapidly. This produces
/// a more stable system that responds better to changes in the underlying network.
///
/// The controller keeps track of the number of pending bytes (that is, bytes that have been written but not yet
/// reached the network), as well as a high and a low watermark. If the number of pending bytes exceeds the high
/// watermark, the writability state changes to false. If the number of pending bytes is below the low watermark,
/// the writability state changes to true.
///
/// If the number of pending bytes is between the two watermarks, the writability state remains in whatever the previous
/// state was. This essentially causes a "lag" in the change of writability state: once the state flips, it will take a while
/// for the number of pending bytes to cross the other threshold to cause the state to flip again.
struct WatermarkedFlowController {
    /// The "high" water mark. If the number of pending bytes exceeds this number, the
    /// writability state will change to "false".
    private let highWatermark: Int

    /// The "low" watermark. If the number of pending bytes is lower than this number, the
    /// writability state will change to "true".
    private let lowWatermark: Int

    /// The number of pending bytes waiting to be written to the network.
    private var pendingBytes: Int

    /// Whether the `Channel` should consider itself writable or not.
    internal private(set) var isWritable: Bool

    internal init(highWatermark: Int, lowWatermark: Int) {
        precondition(
            lowWatermark < highWatermark,
            "Low watermark \(lowWatermark) exceeds or meets High watermark \(highWatermark)"
        )
        precondition(lowWatermark >= 0, "Low watermark \(lowWatermark) is negative")

        self.highWatermark = highWatermark
        self.lowWatermark = lowWatermark
        self.pendingBytes = 0
        self.isWritable = true
    }
}

extension WatermarkedFlowController {
    /// Notifies the flow controller that we have buffered some bytes to send to the network.
    mutating func bufferedBytes(_ bufferedBytes: Int) {
        precondition(bufferedBytes >= 0)
        self.pendingBytes += bufferedBytes
        if self.pendingBytes > self.highWatermark {
            self.isWritable = false
        }
    }

    /// Notifies the flow controller that we have successfully written some bytes to the network.
    mutating func wroteBytes(_ writtenBytes: Int) {
        precondition(writtenBytes >= 0)
        // pendingBytes can become negative: this is unusual but tolerated.
        //
        // Both bufferedBytes(_:) and wroteBytes(_:) are called by the HTTP2StreamChannel in
        // write0(_:promise:). bufferedBytes(_:) is called when the outbound write is buffered
        // and wroteBytes(_:) is called when the promise for the buffer write is completed. Both
        // calls are given the estimated size of the write so their effect on pendingBytes will
        // always balance out.
        //
        // If the promise passed to write0(_:promise:) has already been completed then the callback
        // to wroteBytes(_:) will happen before the call to bufferedBytes(_:). If this happens then
        // pendingBytes can (briefly) become negative.
        self.pendingBytes -= writtenBytes
        if self.pendingBytes < self.lowWatermark {
            self.isWritable = true
        }
    }
}

extension WatermarkedFlowController: Equatable {}

extension WatermarkedFlowController: CustomDebugStringConvertible {
    var debugDescription: String {
        "WatermarkedFlowController(highWatermark: \(self.highWatermark), lowWatermark: \(self.lowWatermark), pendingBytes: \(self.pendingBytes), isWritable: \(self.isWritable))"
    }
}
