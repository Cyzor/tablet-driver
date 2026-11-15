#!/bin/sh
# Compile and run ring/dial rotate and zoom scale checks. Pure arithmetic —
# InputInjector can't build standalone, so the formulas are restated in the
# test and pinned to the same measured steps/revolution.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test dial-scale-tests "$DIR/main.swift"
"$TEST_BIN"
