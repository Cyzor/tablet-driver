#!/bin/sh
# Compile and run the device-data collection accumulator checks against the real
# source file. This builds a small executable
# from CaptureAccumulator.swift plus the test main and runs it.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test capture-accumulator-tests --kit "$ROOT/MockTab/Driver/Diagnostics/CaptureAccumulator.swift" "$DIR/CaptureAccumulatorTests.swift"
"$TEST_BIN"
