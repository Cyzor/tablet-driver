#!/bin/sh
# Compile and run the touchdown click guard checks against the real
# TouchdownGuard.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test touchdown-guard-tests "$ROOT/MockTab/Driver/Injection/TouchdownGuard.swift" "$DIR/main.swift"
"$TEST_BIN"
