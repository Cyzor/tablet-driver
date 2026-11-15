#!/bin/sh
# Compile and run the configuration-export locale round-trip checks against the real
# source files. This builds a small
# executable from ButtonBinding.swift + ControlSlot.swift (TouchRingMode)
# plus the test main and runs it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test configuration-locale-tests "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" "$ROOT/MockTab/Settings/Model/ControlSlot.swift" "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" "$DIR/main.swift"
"$TEST_BIN"
