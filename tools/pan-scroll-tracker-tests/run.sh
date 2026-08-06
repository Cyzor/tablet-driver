#!/bin/sh
# Compile and run Scroll Drag release-velocity checks against the real source
# file. The app has no XCTest target, so this builds a small executable from
# PanScrollTracker.swift plus the test main and runs it.
# Sibling of tools/touch-state-tracker-tests/run.sh.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Injection/PanScrollTracker.swift"
TEST="$DIR/PanScrollTrackerTests.swift"
BIN="$(mktemp -d)/pan-scroll-tracker-tests"

(
  cd "$ROOT/TabletKit"
  swift build --quiet
)
MODULES="$(find "$ROOT/TabletKit/.build" -type d -path '*/debug/Modules' -print -quit)"
if [ -z "$MODULES" ]; then
  echo "TabletKit Swift module was not built" >&2
  exit 1
fi

# Unlike the touch tracker, PanScrollTracker calls into TabletKit (PanSmoother),
# so the static library has to be linked, not just its module map imported.
LIB="$(find "$ROOT/TabletKit/.build" -name 'libTabletKit.a' -print -quit)"
if [ -z "$LIB" ]; then
  echo "libTabletKit.a was not built" >&2
  exit 1
fi

swiftc -O -I "$MODULES" "$SRC" "$TEST" "$LIB" -o "$BIN"
"$BIN"
