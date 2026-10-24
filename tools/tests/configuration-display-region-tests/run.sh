#!/bin/sh
# Compile and run the configuration-import displayRegion backward-compatibility
# checks against the real ConfigurationImporter.swift. The app has no XCTest
# target, so this builds a small executable from ConfigurationImporter.swift plus
# a stand-in for the two types only its (untested-here) `parse` function
# needs (see StubTypes.swift) and the test main, then runs it. Exits
# non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SETTINGS="$ROOT/MockTab/Settings"
IMPORTER="$SETTINGS/Serialization/ConfigurationImporter.swift"
IMPORT_PLAN="$SETTINGS/Serialization/ImportPlan.swift"
STUB="$DIR/StubTypes.swift"
TEST="$DIR/ConfigurationDisplayRegionTests.swift"
BIN="$(mktemp -d)/configuration-display-region-tests"

swiftc -O \
    "$IMPORTER" \
    "$IMPORT_PLAN" \
    "$SETTINGS/Model/ButtonBinding.swift" \
    "$SETTINGS/Model/ControlSlot.swift" \
    "$SETTINGS/Model/RotaryConfig.swift" \
    "$SETTINGS/Serialization/UnknownFieldsCodable.swift" \
    "$SETTINGS/Model/BezierCurve.swift" \
    "$STUB" \
    "$TEST" \
    -o "$BIN"
"$BIN"
