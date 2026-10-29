#!/bin/sh
# Compile and run the older-file label import checks against the real
# ConfigurationImporter.swift. Reuses configuration-display-region-tests' stubs
# for the types only `parse` needs. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SETTINGS="$ROOT/MockTab/Settings"
BIN="$(mktemp -d)/configuration-label-tests"

swiftc -O \
    "$SETTINGS/Serialization/ConfigurationImporter.swift" \
    "$SETTINGS/Serialization/ImportPlan.swift" \
    "$SETTINGS/Model/ButtonBinding.swift" \
    "$SETTINGS/Model/ControlSlot.swift" \
    "$SETTINGS/Model/RotaryConfig.swift" \
    "$SETTINGS/Serialization/UnknownFieldsCodec.swift" \
    "$SETTINGS/Model/BezierCurve.swift" \
    "$DIR/../configuration-display-region-tests/StubTypes.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN"
