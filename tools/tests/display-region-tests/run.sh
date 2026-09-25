#!/bin/sh
# Compile and run the display sub-region mapping checks against the real
# DisplayMapper.swift. The app has no XCTest target, so this builds a small
# executable from DisplayMapper.swift plus a hand-written stand-in for
# InjectionSnapshot (see TabletSettingsStub.swift for why it isn't the real
# file) and the test main, then runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
MAPPER="$ROOT/MockTab/Driver/Mapping/DisplayMapper.swift"
BALLISTICS="$ROOT/MockTab/Driver/Mapping/RelativeBallistics.swift"
ORIENTATION="$ROOT/MockTab/Settings/Model/TabletOrientation.swift"
CALIBRATION="$ROOT/MockTab/Settings/Model/CalibrationData.swift"
STUB="$DIR/TabletSettingsStub.swift"
TEST="$DIR/DisplayRegionTests.swift"
BIN="$(mktemp -d)/display-region-tests"

# TabletKit is shared with the other harnesses that link it; the helper builds
# it once and caches it.
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -I "$KIT" "$MAPPER" "$BALLISTICS" "$ORIENTATION" "$CALIBRATION" "$STUB" "$TEST" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
