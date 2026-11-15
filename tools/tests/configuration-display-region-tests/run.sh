#!/bin/sh
# Compile and run the configuration-import displayRegion backward-compatibility
# checks against the real ConfigurationImporter.swift. The app has no XCTest
# target, so this builds a small executable from ConfigurationImporter.swift plus
# a stand-in for the two types only its (untested-here) `parse` function
# needs (see StubTypes.swift) and the test main, then runs it. Exits
# non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test configuration-display-region-tests \
    "$ROOT/MockTab/Settings/Serialization/ConfigurationImporter.swift" \
    "$ROOT/MockTab/Settings/Serialization/ImportPlan.swift" \
    "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" \
    "$ROOT/MockTab/Settings/Model/ControlSlot.swift" \
    "$ROOT/MockTab/Settings/Model/RotaryConfig.swift" \
    "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" \
    "$ROOT/MockTab/Settings/Model/BezierCurve.swift" \
    "$DIR/StubTypes.swift" \
    "$DIR/ConfigurationDisplayRegionTests.swift"
"$TEST_BIN"
