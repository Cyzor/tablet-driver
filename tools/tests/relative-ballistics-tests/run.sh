#!/bin/sh
# Compile and run the relative-mode ballistics checks against the real
# RelativeBallistics.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/relative-ballistics-tests"

swiftc -O \
    "$ROOT/MockTab/Driver/Mapping/RelativeBallistics.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN" "$ROOT"
