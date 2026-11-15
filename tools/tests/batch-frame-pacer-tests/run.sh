#!/bin/sh
# Compile and run the Bluetooth frame pacing checks against the real
# BatchFramePacer.swift, on TabletKit's real HID thread. Exits non-zero on
# failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test batch-frame-pacer-tests --kit "$ROOT/MockTab/Driver/Devices/BatchFramePacer.swift" "$DIR/main.swift"
"$TEST_BIN"
