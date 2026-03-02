//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// swift-format-ignore: NoBlockComments
/*
 * Copyright 2024, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import NIOCore

/// A timer backed by `NIOScheduledCallback`.
struct Timer<Handler: NIOScheduledCallbackHandler>: Sendable where Handler: Sendable {
    /// The event loop on which to run this timer.
    private let eventLoop: any EventLoop

    /// The duration of the timer.
    private let duration: TimeAmount

    /// The handler to call when the timer fires.
    private let handler: Handler

    /// The currently scheduled callback if the timer is running.
    private var scheduledCallback: NIOScheduledCallback?

    init(eventLoop: any EventLoop, duration: TimeAmount, handler: Handler) {
        self.eventLoop = eventLoop
        self.duration = duration
        self.handler = handler
        self.scheduledCallback = nil
    }

    /// Cancel the timer, if it is running.
    func cancel() {
        guard let scheduledCallback = self.scheduledCallback else { return }
        scheduledCallback.cancel()
    }

    /// Start or restart the timer.
    mutating func start() {
        self.scheduledCallback?.cancel()
        // Only throws if the event loop is shutting down, so we'll just swallow the error here.
        self.scheduledCallback = try? self.eventLoop.scheduleCallback(in: self.duration, handler: self.handler)
    }
}
