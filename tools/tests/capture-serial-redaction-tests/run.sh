#!/bin/sh
# Compile and run the capture serial-redaction checks against the real source.
# `CaptureSerialRedaction` is free of the capture types precisely so this can
# compile it rather than mirror it. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Discovery/CaptureSerialRedaction.swift"
BIN="$(mktemp -d)/capture-serial-redaction-tests"

swiftc -O "$SRC" "$DIR/main.swift" -o "$BIN"
"$BIN"
