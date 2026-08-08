#!/bin/sh
# Compile and run the HID descriptor readability checks against the real source file.
# The app has no XCTest target, so this builds a small executable from
# HIDDescriptorReader.swift plus the test main and runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$ROOT/MockTab/Driver/HID/HIDDescriptorReader.swift"
TEST="$DIR/DescriptorOpacityTests.swift"
BIN="$(mktemp -d)/descriptor-opacity-tests"

(
  cd "$ROOT/TabletKit"
  swift build --quiet
)
MODULES="$(find "$ROOT/TabletKit/.build" -type d -path '*/debug/Modules' -print -quit)"
if [ -z "$MODULES" ]; then
  echo "TabletKit Swift module was not built" >&2
  exit 1
fi

LIB="$(find "$ROOT/TabletKit/.build" -name 'libTabletKit.a' -print -quit)"
if [ -z "$LIB" ]; then
  echo "libTabletKit.a was not built" >&2
  exit 1
fi

swiftc -O -I "$MODULES" "$SRC" "$TEST" "$LIB" -o "$BIN"
"$BIN"
