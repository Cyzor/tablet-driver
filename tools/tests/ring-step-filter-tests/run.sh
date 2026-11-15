#!/bin/sh
# Compile and run the touch ring step checks against the real
# RingStepFilter.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test ring-step-filter-tests "$ROOT/MockTab/Driver/Injection/RingStepFilter.swift" "$DIR/main.swift"
"$TEST_BIN"
