#!/bin/sh
# Compile and run the pen recipe checks against the real source file: the
# three barrels match their artwork, and every variant's parts sit where
# clicks find them.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
TEST="$DIR/main.swift"
T="$(mktemp -d)"
BIN="$T/pen-recipe-tests"

swiftc -O "$ROOT/MockTab/Figures/PenRecipe.swift" "$TEST" -o "$BIN"
"$BIN"
