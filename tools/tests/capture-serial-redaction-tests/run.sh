#!/bin/sh
# Compile and run the capture serial-redaction checks against the real source.
# `CaptureSerialRedaction` is free of the capture types precisely so this can
# compile it rather than mirror it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test capture-serial-redaction-tests "$ROOT/MockTab/Driver/Diagnostics/CaptureSerialRedaction.swift" "$DIR/main.swift"
"$TEST_BIN"
