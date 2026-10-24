#!/bin/sh
# Compile and run the tablet figure checks against the real source files: the
# generated layout table, orientation turns, and layout invariants for every
# layout in both styles, and every drawing against golden-drawings.txt
# (UPDATE_GOLDENS=1 rewrites it).
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
FIGURES="$ROOT/MockTab/Figures"
TEST="$DIR/main.swift"
T="$(mktemp -d)"
BIN="$T/tablet-figure-tests"

swiftc -O "$FIGURES/TabletFigure.swift" "$FIGURES/TabletLayoutTable.swift" "$FIGURES/TabletLayoutIdentity.swift" \
    "$ROOT/MockTab/Settings/Model/TabletOrientation.swift" "$TEST" -o "$BIN"
"$BIN" "$DIR"
