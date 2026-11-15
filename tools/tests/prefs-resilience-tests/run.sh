#!/bin/sh
# Compile and run the prefs version-skew resilience checks against the real
# source files. This builds a small
# executable from the affected structs plus the test main and runs it.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test prefs-resilience-tests "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" "$ROOT/MockTab/Settings/Model/ControlSlot.swift" "$ROOT/MockTab/Settings/Model/BezierCurve.swift" "$DIR/main.swift"
"$TEST_BIN"
