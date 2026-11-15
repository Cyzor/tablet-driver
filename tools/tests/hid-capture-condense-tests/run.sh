#!/bin/sh
# Compile and run HIDCapture.condense(_:) checks against the real source
# file. This builds a small executable from
# HIDCapture.swift plus the test main and runs it.
# Sibling of tools/tests/pan-scroll-tracker-tests/run.sh.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test hid-capture-condense-tests --kit "$ROOT/MockTab/Driver/Diagnostics/HIDCapture.swift" "$ROOT/MockTab/Driver/Diagnostics/CaptureSerialRedaction.swift" "$ROOT/MockTab/App/DateStamp.swift" "$DIR/main.swift"
"$TEST_BIN"
