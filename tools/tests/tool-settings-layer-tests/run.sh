#!/bin/sh
# Compile and run the per-pen settings layer checks against the real
# ToolSettings. The stub supplies the logger and the undo protocol, which
# live in TabletSettings.swift alongside most of the app's dependencies.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test tool-settings-layer-tests --kit \
    "$ROOT/MockTab/Settings/ToolSettings.swift" \
    "$ROOT/MockTab/Settings/Model/BezierCurve.swift" \
    "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" \
    "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" \
    "$DIR/stub.swift" "$DIR/main.swift"
"$TEST_BIN"
