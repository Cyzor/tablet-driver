#!/bin/sh
# Compile and run the control position checks against the real source files:
# every model's controls in reading order, and where each sits when the tablet
# is turned. Links TabletKit for the registry the control map reads.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test tablet-position-tests --kit \
    "$ROOT/MockTab/Figures/TabletFigure.swift" "$ROOT/MockTab/Figures/TabletLayoutTable.swift" "$ROOT/MockTab/Figures/TabletLayoutIdentity.swift" \
    "$ROOT/MockTab/Figures/TabletControlMap.swift" "$ROOT/MockTab/Settings/Model/TabletOrientation.swift" "$ROOT/MockTab/Settings/Model/TurnCarry.swift" \
    "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" "$ROOT/MockTab/Settings/Model/ControlSlot.swift" "$ROOT/MockTab/Settings/Model/RotaryConfig.swift" \
    "$ROOT/MockTab/Settings/Model/BezierCurve.swift" "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" \
    "$DIR/main.swift"
"$TEST_BIN"
