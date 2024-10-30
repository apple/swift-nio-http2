#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##
## Copyright (c) 2014 - 2017 Apple Inc. and the project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See LICENSE.txt for license information:
## https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt

# As the license header implies, this file was derived from swift-protobuf,
# and edited for use with SwiftNIO HTTP/2.


set -eu

# shellcheck disable=SC2001 # Too complex
FuzzTestingDir=$(dirname "$(echo "$0" | sed -e "s,^\([^/]\),$(pwd)/\1,")")
readonly FuzzTestingDir

printUsage() {
  NAME=$(basename "${0}")
  cat << EOF
usage: ${NAME} [OPTIONS]

This script builds (and can run) the fuzz tests.

OPTIONS:

 General:

   -h, --help
         Show this message
   --debug-only
         Just build the 'debug' configuration.
   --release-only
         Just build the 'release' configuration.
   --both
         Build both the 'debug' and 'release' configurations. This is
         the default.
   --run-regressions, --run
         After building, also run all the fuzz tests against the known fail
         cases.

EOF
}

FUZZ_TESTS=("FuzzHTTP2")
CHECK_REGRESSIONS="no"
# Default to both
CMD_CONFIGS=("debug" "release")

while [[ $# != 0 ]]; do
  case "${1}" in
    -h | --help )
      printUsage
      exit 0
      ;;
    --debug-only )
      CMD_CONFIGS=("debug")
      ;;
    --release-only )
      CMD_CONFIGS=("release")
      ;;
    --both )
      CMD_CONFIGS=("debug" "release")
      ;;
    --run-regressions | --run )
      CHECK_REGRESSIONS="yes"
      ;;
    -*)
      echo "ERROR: Unknown option: ${1}" 1>&2
      printUsage
      exit 1
      ;;
    *)
      echo "ERROR: Unknown argument: ${1}" 1>&2
      printUsage
      exit 1
      ;;
  esac
  shift
done

cd "${FuzzTestingDir}"

declare -a CMD_BASE
if [ "$(uname)" == "Darwin" ]; then
  CMD_BASE=(
    xcrun --toolchain swift swift build -Xswiftc "-sanitize=fuzzer,address" -Xswiftc -parse-as-library
  )
else
  CMD_BASE=(
    swift build -Xswiftc "-sanitize=fuzzer,address" -Xswiftc -parse-as-library
  )
fi

for CMD_CONFIG in "${CMD_CONFIGS[@]}"; do
  echo "------------------------------------------------------------------------------------------"
  echo "Building: ${CMD_CONFIG}"
  echo "${CMD_BASE[@]}" -c "${CMD_CONFIG}"
  "${CMD_BASE[@]}" -c "${CMD_CONFIG}"

  if [[ "${CHECK_REGRESSIONS}" == "yes" ]] ; then
    for FUZZ_TEST in "${FUZZ_TESTS[@]}"; do
      # Don't worry about running the test cases against the right binaries, they should
      # all be able to handle any input.
      echo "------------------------------------------------------------------------------------------"
      echo "Regressing: ${FUZZ_TEST}"
      ".build/${CMD_CONFIG}/${FUZZ_TEST}" FailCases/*
    done
  fi
done
