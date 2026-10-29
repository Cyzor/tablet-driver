#!/bin/sh
# Compile and run the Wacom import report and encoder checks against the fixture backup.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/wacom-import-tests"
KIT="$(sh "$DIR/../build-tabletkit.sh")"

S="$ROOT/MockTab/Settings"

swiftc -O -I "$KIT" -L "$KIT" -lTabletKit \
    "$ROOT/tools/wacom-import/WacomPrefs.swift" \
    "$ROOT/tools/wacom-import/Encoder.swift" \
    "$S/Serialization/ConfigurationImporter.swift" \
    "$S/Serialization/ImportPlan.swift" \
    "$S/Serialization/UnknownFieldsCodec.swift" \
    "$S/Model/ButtonBinding.swift" \
    "$S/Model/ControlSlot.swift" \
    "$S/Model/RotaryConfig.swift" \
    "$S/Model/BezierCurve.swift" \
    "$DIR/../configuration-display-region-tests/StubTypes.swift" \
    "$DIR/EncoderChecks.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN" "$DIR/fixtures"
