//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

// TODO: remove this extension and bump the NIO dependency
// when https://github.com/apple/swift-nio/pull/3152 is released.
extension NIOIsolatedEventLoop {
    @inlinable
    @available(*, noasync)
    func makeCompletedFuture<Success>(_ result: Result<Success, Error>) -> EventLoopFuture<Success> {
        let promise = self.nonisolated().makePromise(of: Success.self)
        promise.assumeIsolatedUnsafeUnchecked().completeWith(result)
        return promise.futureResult
    }

    @inlinable
    @available(*, noasync)
    func makeCompletedFuture<Success>(
        withResultOf body: () throws -> Success
    ) -> EventLoopFuture<Success> {
        self.makeCompletedFuture(Result(catching: body))
    }
}
