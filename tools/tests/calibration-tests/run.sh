#!/bin/sh
# Compile and run the calibration fitting checks against the real source file.
# This builds a small executable from
# CalibrationData.swift plus the test main and runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test calibration-tests "$ROOT/MockTab/Settings/Model/CalibrationData.swift" "$DIR/CalibrationFitTests.swift"
"$TEST_BIN"
