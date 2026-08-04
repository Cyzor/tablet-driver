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

swiftc -O "$SRC" "$TEST" -o "$BIN"
"$BIN"
