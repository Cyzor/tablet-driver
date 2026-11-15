#!/bin/sh
# Compile and run the tablet figure checks against the real source files: the
# generated layout table, orientation turns, and layout invariants for every
# layout in both styles, and every drawing against golden-drawings.txt
# (UPDATE_GOLDENS=1 rewrites it).
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test tablet-figure-tests "$ROOT/MockTab/Figures/TabletFigure.swift" "$ROOT/MockTab/Figures/TabletLayoutTable.swift" "$ROOT/MockTab/Figures/TabletLayoutIdentity.swift" "$ROOT/MockTab/Settings/Model/TabletOrientation.swift" "$DIR/main.swift"
"$TEST_BIN" "$DIR"
