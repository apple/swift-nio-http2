#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

tmp_dir="/tmp"

function die() {
    echo >&2 "ERROR: $*"
    exit 1
}

while getopts "t:" opt; do
    case "$opt" in
        t)
            tmp_dir="$OPTARG"
            ;;
        \?)
            die "unknown option $opt"
            ;;
    esac
done

nio_checkout=$(mktemp -d "$tmp_dir/.swift-nio_XXXXXX")
(
cd "$nio_checkout"
git clone --depth 1 https://github.com/apple/swift-nio
)

"$nio_checkout/swift-nio/IntegrationTests/allocation-counter-tests-framework/run-allocation-counter.sh" \
    -p "$here/../../.." \
    -m NIO \
    -m NIOHTTP1 \
    -m NIOHTTP2 \
    -t "$tmp_dir" \
    -d <( echo '.package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),' ) \
    "$here"/test_*.swift
