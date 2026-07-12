#!/bin/sh
# Compile and run the calibration fitting checks against the real source file.
# The app has no XCTest target, so this builds a small executable from
# CalibrationData.swift plus the test main and runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$ROOT/MockTab/Settings/CalibrationData.swift"
TEST="$DIR/CalibrationFitTests.swift"
BIN="$(mktemp -d)/calibration-tests"

swiftc -O "$SRC" "$TEST" -o "$BIN"
"$BIN"
