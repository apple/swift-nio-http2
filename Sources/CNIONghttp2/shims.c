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
#include <c_nio_nghttp2.h>

// This file provides an implementation of a number of shim functions to
// handle different versions of nghttp2.

// This shim only works on recent versions of nghttp2, otherwise it does
// nothing.
void CNIONghttp2_nghttp2_session_callbacks_set_error_callback(
    nghttp2_session_callbacks *cbs,
    CNIONghttp2_nghttp2_error_callback error_callback) {
#if NGHTTP2_VERSION_NUM >= 0x010900
    return nghttp2_session_callbacks_set_error_callback(cbs, error_callback);
#endif
}

// This shim turns the macro into something we can see.
int CNIONghttp2_nghttp2_version_number(void) {
    return NGHTTP2_VERSION_NUM;
}
