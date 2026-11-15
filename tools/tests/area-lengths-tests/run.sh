#!/bin/sh
# Compile and run the Tablet Area size field checks against the real
# AreaLengths.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test area-lengths-tests "$ROOT/MockTab/UI/Panes/TabletArea/AreaLengths.swift" "$DIR/main.swift"
"$TEST_BIN"
