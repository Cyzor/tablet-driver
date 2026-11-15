#!/bin/sh
# Compile and run per-dial mode-storage checks against the real source files.
# This builds a small executable from
# RotaryConfig.swift, the model types it references, and the test main.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test rotary-config-tests "$ROOT/MockTab/Settings/Model/RotaryConfig.swift" "$ROOT/MockTab/Settings/Model/ControlSlot.swift" "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" "$DIR/main.swift"
"$TEST_BIN"
