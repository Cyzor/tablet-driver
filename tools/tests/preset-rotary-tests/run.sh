#!/bin/sh
# Compile and run the preset import checks for per-dial modes against the
# real PresetImporter.swift. Reuses preset-display-region-tests' stubs for
# the types only `parse` needs. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SETTINGS="$ROOT/MockTab/Settings"
BIN="$(mktemp -d)/preset-rotary-tests"

swiftc -O \
    "$SETTINGS/Serialization/PresetImporter.swift" \
    "$SETTINGS/Serialization/ImportPlan.swift" \
    "$SETTINGS/Model/ButtonBinding.swift" \
    "$SETTINGS/Model/ControlSlot.swift" \
    "$SETTINGS/Model/RotaryConfig.swift" \
    "$SETTINGS/Serialization/UnknownFieldsCodable.swift" \
    "$SETTINGS/Model/BezierCurve.swift" \
    "$DIR/../preset-display-region-tests/StubTypes.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN"
