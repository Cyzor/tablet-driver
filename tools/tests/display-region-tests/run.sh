#!/bin/sh
# Compile and run the display sub-region mapping checks against the real
# DisplayMapper.swift. This builds a small
# executable from DisplayMapper.swift plus a hand-written stand-in for
# InjectionSnapshot (see TabletSettingsStub.swift for why it isn't the real
# file) and the test main, then runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test display-region-tests --kit \
    "$ROOT/MockTab/Driver/Mapping/DisplayMapper.swift" \
    "$ROOT/MockTab/Driver/Mapping/RelativeBallistics.swift" \
    "$ROOT/MockTab/Settings/Model/TabletOrientation.swift" \
    "$ROOT/MockTab/Settings/Model/CalibrationData.swift" \
    "$DIR/TabletSettingsStub.swift" \
    "$DIR/DisplayRegionTests.swift"
"$TEST_BIN"
