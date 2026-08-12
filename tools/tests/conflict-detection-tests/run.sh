#!/bin/sh
# Compile and run the conflict-detection matcher checks against the real
# source file. The app has no XCTest target, so this builds a small
# executable from ConflictDetection.swift plus the test main and runs it.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/UI/Support/ConflictDetection.swift"
TEST="$DIR/ConflictDetectionTests.swift"
BIN="$(mktemp -d)/conflict-detection-tests"

swiftc -O "$SRC" "$TEST" -o "$BIN"
"$BIN"
