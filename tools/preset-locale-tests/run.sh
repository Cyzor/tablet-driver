#!/bin/sh
# Compile and run the preset-export locale round-trip checks against the real
# source files. The app has no XCTest target, so this builds a small
# executable from ButtonBinding.swift + ControlSlot.swift (TouchRingMode)
# plus the test main and runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC1="$ROOT/MockTab/Settings/ButtonBinding.swift"
SRC2="$ROOT/MockTab/Settings/ControlSlot.swift"
SRC3="$ROOT/MockTab/Settings/UnknownFieldsCodable.swift"
TEST="$DIR/main.swift"
BIN="$(mktemp -d)/preset-locale-tests"

swiftc -O "$SRC1" "$SRC2" "$SRC3" "$TEST" -o "$BIN"
"$BIN"
