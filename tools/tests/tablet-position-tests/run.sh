#!/bin/sh
# Compile and run the control position checks against the real source files:
# every model's controls in reading order, and where each sits when the tablet
# is turned. Links TabletKit for the registry the control map reads.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
AREA="$ROOT/MockTab/UI/Panes/TabletArea"
TEST="$DIR/main.swift"
T="$(mktemp -d)"
BIN="$T/tablet-position-tests"

# TabletKit is shared with the other harnesses that link it; see
# tools/tests/build-tabletkit.sh.
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

SETTINGS="$ROOT/MockTab/Settings"
swiftc -O -I "$KIT" "$AREA/TabletFigure.swift" "$AREA/TabletLayoutTable.swift" "$AREA/TabletLayoutIdentity.swift" \
    "$AREA/TabletControlMap.swift" "$SETTINGS/Model/TabletOrientation.swift" "$SETTINGS/Model/TurnCarry.swift" \
    "$SETTINGS/Model/ButtonBinding.swift" "$SETTINGS/Model/ControlSlot.swift" "$SETTINGS/Model/RotaryConfig.swift" \
    "$SETTINGS/Model/BezierCurve.swift" "$SETTINGS/Serialization/UnknownFieldsCodable.swift" "$TEST" \
    "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
