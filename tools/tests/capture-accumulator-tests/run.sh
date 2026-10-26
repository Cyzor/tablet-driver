#!/bin/sh
# Compile and run the device-data collection accumulator checks against the real
# source file. The app has no XCTest target, so this builds a small executable
# from CaptureAccumulator.swift plus the test main and runs it.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Diagnostics/CaptureAccumulator.swift"
TEST="$DIR/CaptureAccumulatorTests.swift"
BIN="$(mktemp -d)/capture-accumulator-tests"

# TabletKit is shared with the other harnesses that link it; the helper builds
# it once and caches it. See tools/tests/build-tabletkit.sh for why it compiles
# from source instead of using SwiftPM's .build output.
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -I "$KIT" "$SRC" "$TEST" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
