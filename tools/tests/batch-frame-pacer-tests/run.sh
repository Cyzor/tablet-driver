#!/bin/sh
# Compile and run the Bluetooth frame pacing checks against the real
# BatchFramePacer.swift, on TabletKit's real HID thread. Exits non-zero on
# failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/batch-frame-pacer-tests"
KIT="$(sh "$ROOT/tools/tests/build-tabletkit.sh")"

# Unoptimized, like the app's Debug build, so runtime checks stay on.
swiftc -I "$KIT" "$ROOT/MockTab/Driver/Devices/BatchFramePacer.swift" "$DIR/main.swift" \
    "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
