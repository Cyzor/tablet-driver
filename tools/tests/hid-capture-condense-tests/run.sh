#!/bin/sh
# Compile and run HIDCapture.condense(_:) checks against the real source
# file. The app has no XCTest target, so this builds a small executable from
# HIDCapture.swift plus the test main and runs it.
# Sibling of tools/tests/pan-scroll-tracker-tests/run.sh.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/HID/HIDCapture.swift"
TEST="$DIR/main.swift"
T="$(mktemp -d)"
BIN="$T/hid-capture-condense-tests"

# TabletKit is shared with the other harnesses that link it; the helper builds
# it once and caches it. See tools/tests/build-tabletkit.sh for why it compiles
# from source instead of using SwiftPM's .build output.
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -I "$KIT" "$SRC" "$TEST" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
