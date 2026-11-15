#!/bin/sh
# Compile and run the Wacom import report, encoder, and writer checks against
# the fixture backup, then the command checks. The writer and command checks
# use scratch settings domains they delete. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

KIT="$(tabletkit_dir)"
# Unoptimized, as run.sh builds the tool, so runtime checks catch the same faults.
# Its checks take their assertion function as a parameter, so it keeps its own
# instead of Check.swift.
swift_test wacom-settings-tests --no-opt --no-check -I "$KIT" -L "$KIT" -lTabletKit \
    "$ROOT/tools/wacom-settings/WacomPrefs.swift" \
    "$ROOT/tools/wacom-settings/WacomCodes.swift" \
    "$ROOT/tools/wacom-settings/KeyboardLayout.swift" \
    "$ROOT/tools/wacom-settings/Encoder.swift" \
    "$ROOT/tools/wacom-settings/Writer.swift" \
    "$ROOT/MockTab/Settings/Serialization/ConfigurationImporter.swift" \
    "$ROOT/MockTab/Settings/Serialization/ImportPlan.swift" \
    "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" \
    "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" \
    "$ROOT/MockTab/Settings/Model/ControlSlot.swift" \
    "$ROOT/MockTab/Settings/Model/RotaryConfig.swift" \
    "$ROOT/MockTab/Settings/Model/BezierCurve.swift" \
    "$DIR/../configuration-display-region-tests/StubTypes.swift" \
    "$DIR/EncoderChecks.swift" \
    "$DIR/WriterChecks.swift" \
    "$DIR/LayoutChecks.swift" \
    "$DIR/AmbiguityChecks.swift" \
    "$DIR/CodeChecks.swift" \
    "$DIR/main.swift"
"$TEST_BIN" "$DIR/fixtures"
sh "$DIR/cli-checks.sh"
