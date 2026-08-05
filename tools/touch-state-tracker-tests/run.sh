#!/bin/sh
# Compile and run touch-state intent checks against the real source file.
# The app has no XCTest target, so this builds a small executable from
# TouchStateTracker.swift plus the test main and runs it.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Injection/TouchStateTracker.swift"
TEST="$DIR/TouchStateTrackerTests.swift"
BIN="$(mktemp -d)/touch-state-tracker-tests"

(
  cd "$ROOT/TabletKit"
  swift build --quiet
)
MODULES="$(find "$ROOT/TabletKit/.build" -type d -path '*/debug/Modules' -print -quit)"
if [ -z "$MODULES" ]; then
  echo "TabletKit Swift module was not built" >&2
  exit 1
fi

swiftc -O -I "$MODULES" "$SRC" "$TEST" -o "$BIN"
"$BIN"
