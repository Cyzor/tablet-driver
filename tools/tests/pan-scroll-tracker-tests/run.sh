#!/bin/sh
# Compile and run Scroll Drag release-velocity checks against the real source
# file. This builds a small executable from
# PanScrollTracker.swift plus the test main and runs it.
# Sibling of tools/tests/touch-state-tracker-tests/run.sh.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test pan-scroll-tracker-tests --kit "$ROOT/MockTab/Driver/Injection/PanScrollTracker.swift" "$DIR/PanScrollTrackerTests.swift"
"$TEST_BIN"
