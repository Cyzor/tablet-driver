#!/bin/sh
# Compile and run per-dial mode-storage checks against the real source files.
# The app has no XCTest target, so this builds a small executable from
# RotaryConfig.swift, the model types it references, and the test main.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Settings/Model/RotaryConfig.swift"
DEP="$ROOT/MockTab/Settings/Model/ControlSlot.swift"
DEP2="$ROOT/MockTab/Settings/Model/ButtonBinding.swift"
DEP3="$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodable.swift"
TEST="$DIR/main.swift"
T="$(mktemp -d)"
BIN="$T/rotary-config-tests"

swiftc -O "$SRC" "$DEP" "$DEP2" "$DEP3" "$TEST" -o "$BIN"
"$BIN"
