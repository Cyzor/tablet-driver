#!/bin/sh
# Compile and run the preset-import displayRegion backward-compatibility
# checks against the real PresetImporter.swift. The app has no XCTest
# target, so this builds a small executable from PresetImporter.swift plus
# a stand-in for the two types only its (untested-here) `parse` function
# needs (see StubTypes.swift) and the test main, then runs it. Exits
# non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SETTINGS="$ROOT/MockTab/Settings"
IMPORTER="$SETTINGS/Serialization/PresetImporter.swift"
IMPORT_PLAN="$SETTINGS/Serialization/ImportPlan.swift"
STUB="$DIR/StubTypes.swift"
TEST="$DIR/PresetDisplayRegionTests.swift"
BIN="$(mktemp -d)/preset-display-region-tests"

swiftc -O \
    "$IMPORTER" \
    "$IMPORT_PLAN" \
    "$SETTINGS/Model/ButtonBinding.swift" \
    "$SETTINGS/Model/ControlSlot.swift" \
    "$SETTINGS/Serialization/UnknownFieldsCodable.swift" \
    "$SETTINGS/Model/BezierCurve.swift" \
    "$STUB" \
    "$TEST" \
    -o "$BIN"
"$BIN"
