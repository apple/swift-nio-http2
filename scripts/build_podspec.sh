#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

function usage() {
  echo "$0 [-u] [-f skipUpToTarget] version nio_version"
  echo
  echo "OPTIONS:"
  echo "  -u: Additionally, upload the podspecs as they are generated"
  echo "  -f: Skip over all targets before the specified target"
}

upload=false
skip_until=""
while getopts ":uf:" opt; do
  case $opt in
    u)
      upload=true
      ;;
    f)
      skip_until="$OPTARG"
      ;;
    \?)
      usage
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

version=$1

# Current SwiftNIO Version to add as dependency in the .podspec
nio_version=$2
if [[ $nio_version =~ ^([0-9]+)\. ]]; then
  # Extract and incremenet the major version to use an upper bound on the
  # version requirement (we can't use '~>' as it means 'up to the next
  # major' if you specify x.y and 'up to the next minor' if you specify x.y.z).
  next_major_version=$((${BASH_REMATCH[1]} + 1))
else
  echo "Invalid NIO version '$nio_version'"
  exit 1
fi

newline=$'\n'

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
tmpdir=$(mktemp -d /tmp/.build_podspecsXXXXXX)

echo "Building podspec in $tmpdir"

targets=( $("${here}/list_topsorted_dependencies.sh" -l -r | sed 's/^NIO/SwiftNIO/') )

for target in "${targets[@]}"; do

  if [[ -n "$skip_until" && "$target" != "$skip_until" ]]; then
    echo "Skipping $target"
    continue
  elif [[ "$skip_until" == "$target" ]]; then
    skip_until=""
  fi

  echo "Building podspec for $target"

  dependencies=()

  while read -r raw_dependency; do
    if [ "$raw_dependency" == "SwiftNIOHPACK" ]; then
      dependencies+=( "${newline}  s.dependency '$raw_dependency', s.version.to_s" )
    else
      dependencies+=( "${newline}  s.dependency '$raw_dependency', '>= $nio_version', '< $next_major_version'" )
    fi
  done < <("${here}/list_topsorted_dependencies.sh" -d "${target#Swift}" | sed 's/^NIO/SwiftNIO/')

  cat > "${tmpdir}/${target}.podspec" <<- EOF
Pod::Spec.new do |s|
  s.name = '$target'
  s.version = '$version'
  s.license = { :type => 'Apache 2.0', :file => 'LICENSE.txt' }
  s.summary = 'Useful code around SwiftNIO.'
  s.homepage = 'https://github.com/apple/swift-nio-http2'
  s.author = 'Apple Inc.'
  s.source = { :git => 'https://github.com/apple/swift-nio-http2.git', :tag => s.version.to_s }
  s.documentation_url = 'https://apple.github.io/swift-nio-http2/'
  s.module_name = '${target#Swift}'

  s.swift_version = '5.0'
  s.cocoapods_version = '>=1.6.0'
  s.ios.deployment_target = '10.0'
  s.osx.deployment_target = '10.12'
  s.tvos.deployment_target = '10.0'

  s.source_files = 'Sources/${target#Swift}/**/*.{swift,c,h}'
  ${dependencies[*]-}
end
EOF

  pod repo update # last chance of getting the latest versions of previous pushed pods
  if $upload; then
    echo "Uploading ${tmpdir}/${target}.podspec"
    pod trunk push "${tmpdir}/${target}.podspec" --synchronous
  fi

done
