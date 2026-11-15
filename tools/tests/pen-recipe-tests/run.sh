#!/bin/sh
# Compile and run the pen recipe checks against the real source file: the
# three barrels match their artwork, and every variant's parts sit where
# clicks find them.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test pen-recipe-tests "$ROOT/MockTab/Figures/PenRecipe.swift" "$DIR/main.swift"
"$TEST_BIN"
