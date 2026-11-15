#!/bin/sh
# Compile and run the conflict-detection matcher checks against the real
# source file. This builds a small
# executable from ConflictProcessMatcher.swift plus the test main and runs it.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test conflict-detection-tests "$ROOT/MockTab/Driver/Diagnostics/ConflictProcessMatcher.swift" "$DIR/ConflictDetectionTests.swift"
"$TEST_BIN"
