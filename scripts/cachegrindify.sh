#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set +ex

# Benchmarks known to behave well under cachegrind.
# When adding new benchmarks, consider adding them to this list.
CACHEGRIND_BENCHES=( server_only_10k_requests_100_concurrent server_only_10k_requests_1_concurrent )

function run_bench {
    BRANCH="$1"

    echo "Running against $BRANCH"
    git checkout "$BRANCH"
    swift build -c release -Xswiftc -g -Xswiftc -DCACHEGRIND > /dev/null

    for BENCH in "${CACHEGRIND_BENCHES[@]}"; do
        valgrind --tool=cachegrind --cachegrind-out-file="cachegrind.out.$BENCH.$BRANCH" ./.build/x86_64-unknown-linux-gnu/release/NIOHTTP2PerformanceTester "$BENCH" > /dev/null
    done
}

function compare {
    BASE_BRANCH="$1"
    TARGET_BRANCH="$2"

    for BENCH in "${CACHEGRIND_BENCHES[@]}"; do
        BASE_TOTAL=$(cg_annotate "cachegrind.out.$BENCH.$BASE_BRANCH" | grep "PROGRAM TOTALS" | awk '{ print $1 }')
        TARGET_TOTAL=$(cg_annotate "cachegrind.out.$BENCH.$TARGET_BRANCH" | grep "PROGRAM TOTALS" | awk '{ print $1 }')

        echo "Bench $BENCH result changed: base $BASE_TOTAL, target $TARGET_TOTAL"
    done
}

if ! command -v valgrind &> /dev/null; then
    echo "Valgrind not installed, please install valgrind and re-run"
    exit 1
fi

BASE_BRANCH="$1"
TARGET_BRANCH="$2"

run_bench "$BASE_BRANCH"
run_bench "$TARGET_BRANCH"
compare "$BASE_BRANCH" "$TARGET_BRANCH"

