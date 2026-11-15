#!/bin/sh
# Compile and run the HID descriptor readability checks against the real source file.
# This builds a small executable from
# LiveHIDDescriptorInspector.swift plus the test main and runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test descriptor-opacity-tests --kit "$ROOT/MockTab/Driver/Diagnostics/LiveHIDDescriptorInspector.swift" "$DIR/DescriptorOpacityTests.swift"
"$TEST_BIN"
