#!/bin/sh
# Compile and run the configuration import checks for per-dial modes against the
# real ConfigurationImporter.swift. Reuses configuration-display-region-tests' stubs for
# the types only `parse` needs. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test configuration-rotary-tests \
    "$ROOT/MockTab/Settings/Serialization/ConfigurationImporter.swift" \
    "$ROOT/MockTab/Settings/Serialization/ImportPlan.swift" \
    "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" \
    "$ROOT/MockTab/Settings/Model/ControlSlot.swift" \
    "$ROOT/MockTab/Settings/Model/RotaryConfig.swift" \
    "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" \
    "$ROOT/MockTab/Settings/Model/BezierCurve.swift" \
    "$DIR/../configuration-display-region-tests/StubTypes.swift" \
    "$DIR/main.swift"
"$TEST_BIN"
