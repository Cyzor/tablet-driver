#!/bin/sh
# Compile and run the Wacom import report checks against the fixture backup.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/wacom-import-tests"
KIT="$(sh "$DIR/../build-tabletkit.sh")"

swiftc -O -I "$KIT" -L "$KIT" -lTabletKit \
    "$ROOT/tools/wacom-import/WacomPrefs.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN" "$DIR/fixtures"
