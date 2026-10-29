#!/bin/sh
# Compile and run the Wacom import report checks against the fixture backup.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/wacom-import-tests"

swiftc -O \
    "$ROOT/tools/wacom-import/WacomPrefs.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN" "$DIR/fixtures"
