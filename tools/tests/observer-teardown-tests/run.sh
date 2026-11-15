#!/bin/sh
# Compile and run the reconnect subscription-accumulation checks. Models the
# Combine arrangement rather than compiling DeviceContext — see the harness
# header. No TabletKit link needed.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test observer-teardown-tests "$DIR/main.swift"
"$TEST_BIN"
