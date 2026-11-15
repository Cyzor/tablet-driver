#!/bin/sh
# Compile and run touch-state intent checks against the real source file.
# This builds a small executable from
# TouchStateTracker.swift plus the test main and runs it.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test touch-state-tracker-tests --kit "$ROOT/MockTab/Driver/Injection/TouchStateTracker.swift" "$DIR/TouchStateTrackerTests.swift" "$DIR/TouchStateTrackerGoldens.swift"
"$TEST_BIN" "$DIR"
