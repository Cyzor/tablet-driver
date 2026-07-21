#!/bin/sh
# Compile and run the prefs version-skew resilience checks against the real
# source files. The app has no XCTest target, so this builds a small
# executable from the affected structs plus the test main and runs it.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SETTINGS="$ROOT/MockTab/Settings"
TEST="$DIR/main.swift"
BIN="$(mktemp -d)/prefs-resilience-tests"

swiftc -O \
    "$SETTINGS/UnknownFieldsCodable.swift" \
    "$SETTINGS/ButtonBinding.swift" \
    "$SETTINGS/ControlSlot.swift" \
    "$SETTINGS/BezierCurve.swift" \
    "$TEST" \
    -o "$BIN"
"$BIN"
