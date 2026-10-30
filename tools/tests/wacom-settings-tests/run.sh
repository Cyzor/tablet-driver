#!/bin/sh
# Compile and run the Wacom import report, encoder, and writer checks against
# the fixture backup, then the command checks. The writer and command checks
# use scratch settings domains they delete. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/wacom-settings-tests"
KIT="$(sh "$DIR/../build-tabletkit.sh")"

S="$ROOT/MockTab/Settings"

# Unoptimized, as run.sh builds the tool, so runtime checks catch the same faults.
swiftc -I "$KIT" -L "$KIT" -lTabletKit \
    "$ROOT/tools/wacom-settings/WacomPrefs.swift" \
    "$ROOT/tools/wacom-settings/KeyboardLayout.swift" \
    "$ROOT/tools/wacom-settings/Encoder.swift" \
    "$ROOT/tools/wacom-settings/Writer.swift" \
    "$S/Serialization/ConfigurationImporter.swift" \
    "$S/Serialization/ImportPlan.swift" \
    "$S/Serialization/UnknownFieldsCodec.swift" \
    "$S/Model/ButtonBinding.swift" \
    "$S/Model/ControlSlot.swift" \
    "$S/Model/RotaryConfig.swift" \
    "$S/Model/BezierCurve.swift" \
    "$DIR/../configuration-display-region-tests/StubTypes.swift" \
    "$DIR/EncoderChecks.swift" \
    "$DIR/WriterChecks.swift" \
    "$DIR/LayoutChecks.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN" "$DIR/fixtures"

sh "$DIR/cli-checks.sh"
