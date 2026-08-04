#!/bin/sh
# Compile and run the device-data collection accumulator checks against the real
# source file. The app has no XCTest target, so this builds a small executable
# from DiscoveryAccumulator.swift plus the test main and runs it.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Discovery/DiscoveryAccumulator.swift"
TEST="$DIR/DiscoveryAccumulatorTests.swift"
BIN="$(mktemp -d)/discovery-accumulator-tests"

swiftc -O "$SRC" "$TEST" -o "$BIN"
"$BIN"
