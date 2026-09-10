#!/bin/sh
# Compile and run the reconnect subscription-accumulation checks. Models the
# Combine arrangement rather than compiling DeviceContext — see the harness
# header. No TabletKit link needed.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
TEST="$DIR/ObserverTeardownTests.swift"
T="$(mktemp -d)"
BIN="$T/observer-teardown-tests"

swiftc -O "$TEST" -o "$BIN"
"$BIN"
