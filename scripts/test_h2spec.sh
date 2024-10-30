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

set -eou pipefail

function server_lsof() {
    lsof -a -P -d 0-1024 -p "$1"
}

function stop_server() {
    sleep 0.5 # just to make sure all the fds could be closed
    kill -0 "$1" # assert server is still running    # ignore-unacceptable-language
    kill "$1" # tell server to shut down gracefully    # ignore-unacceptable-language
    for _ in $(seq 20); do
        if ! kill -0 "$1" 2> /dev/null; then    # ignore-unacceptable-language
            break # good, dead
        fi
	# shellcheck disable=SC2009 # pgrep much more awkward to use for this
        ps auxw | grep "$1" || true
        sleep 0.1
    done
    if kill -0 "$1" 2> /dev/null; then    # ignore-unacceptable-language
        fail "server $1 still running"
    fi
}

# Simple thing to do. Start the server in the background.
# Allow extra build arguments from the command line - eg tsan.
swift build "$@"
"$(swift build --show-bin-path)/NIOHTTP2Server" 127.0.0.1 8888 > /dev/null & disown
SERVER_PID=$!
echo "$SERVER_PID"

# Wait for the server to bind a socket.
worked=false
for _ in $(seq 20); do
    port=$(server_lsof "$SERVER_PID" | grep -Eo 'TCP .*:[0-9]+ ' | grep -Eo '[0-9]{4,5} ' | tr -d ' ' || true)
    if [[ -n "$port" ]]; then
	worked=true
	break
    else
	sleep 0.1 # wait for the socket to be bound
    fi
done
"$worked" || fail "Could not reach server 2s after lauching..."

# Run h2spec
h2spec -p 8888

stop_server "$SERVER_PID"
