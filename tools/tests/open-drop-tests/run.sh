#!/bin/sh
# Compile and run the checks for items dragged onto button rows against the
# real ButtonOpenAction.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/open-drop-tests"

swiftc -O "$ROOT/MockTab/App/ButtonOpenAction.swift" "$DIR/main.swift" -o "$BIN"
"$BIN"
