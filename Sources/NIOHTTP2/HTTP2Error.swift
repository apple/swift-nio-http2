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

/// Errors that NIO raises when handling HTTP/2 connections.
public enum NIOHTTP2Error: Error {
    /// NIO's upgrade handler encountered a successful upgrade to a protocol that it
    /// does not recognise.
    case invalidALPNToken
}
