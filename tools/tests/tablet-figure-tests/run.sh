#!/bin/sh
# Compile and run the tablet figure checks against the real source files: the
# generated layout table, orientation turns, and layout invariants for every
# layout in both styles.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
AREA="$ROOT/MockTab/UI/Panes/TabletArea"
TEST="$DIR/main.swift"
T="$(mktemp -d)"
BIN="$T/tablet-figure-tests"

swiftc -O "$AREA/TabletFigure.swift" "$AREA/TabletLayoutTable.swift" \
    "$ROOT/MockTab/Settings/Model/TabletOrientation.swift" "$TEST" -o "$BIN"
"$BIN"
