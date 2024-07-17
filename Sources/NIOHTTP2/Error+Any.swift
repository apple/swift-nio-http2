//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

// 'any Error' is unconditionally boxed, avoid allocating per use by statically boxing them.
extension ChannelError {
    static let _alreadyClosed: any Error = ChannelError.alreadyClosed
    static let _eof: any Error = ChannelError.eof
    static let _ioOnClosedChannel: any Error = ChannelError.ioOnClosedChannel
}
