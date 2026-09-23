#!/bin/sh
# Compile and run the capture-findings checks against the real source. The app
# has no XCTest target, so this builds a small executable from CaptureModels.swift
# (which holds both the models and discoveryFindings) plus the test main.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Discovery/CaptureModels.swift"
INSPECTOR="$ROOT/MockTab/Driver/HID/LiveHIDDescriptorInspector.swift"
TEST="$DIR/CaptureFindingsTests.swift"
BIN="$(mktemp -d)/capture-findings-tests"

# TabletKit is shared with the other harnesses that link it; the helper builds
# it once and caches it. See tools/tests/build-tabletkit.sh for why it compiles
# from source instead of using SwiftPM's .build output.
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -I "$KIT" "$SRC" "$INSPECTOR" "$TEST" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
