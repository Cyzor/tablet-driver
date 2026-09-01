#!/bin/sh
# Compile and run Scroll Drag release-velocity checks against the real source
# file. The app has no XCTest target, so this builds a small executable from
# PanScrollTracker.swift plus the test main and runs it.
# Sibling of tools/tests/touch-state-tracker-tests/run.sh.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Injection/PanScrollTracker.swift"
TEST="$DIR/PanScrollTrackerTests.swift"
T="$(mktemp -d)"
BIN="$T/pan-scroll-tracker-tests"

# TabletKit is shared with the other harnesses that link it; the helper builds
# it once and caches it. See tools/tests/build-tabletkit.sh for why it compiles
# from source instead of using SwiftPM's .build output.
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -I "$KIT" "$SRC" "$TEST" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
