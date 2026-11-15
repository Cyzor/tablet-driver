#!/bin/sh
# Compile and run the capture-findings checks against the real source. This
# builds a small executable from CaptureModels.swift
# (which holds both the models and captureFindings) plus the test main.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test capture-findings-tests --kit "$ROOT/MockTab/Driver/Diagnostics/CaptureModels.swift" "$ROOT/MockTab/Driver/Diagnostics/LiveHIDDescriptorInspector.swift" "$DIR/CaptureFindingsTests.swift"
"$TEST_BIN"
