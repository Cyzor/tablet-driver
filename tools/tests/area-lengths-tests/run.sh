#!/bin/sh
# Compile and run the Tablet Area size field checks against the real
# AreaLengths.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/area-lengths-tests"

swiftc -O "$ROOT/MockTab/UI/Panes/TabletArea/AreaLengths.swift" "$DIR/main.swift" -o "$BIN"
"$BIN"
