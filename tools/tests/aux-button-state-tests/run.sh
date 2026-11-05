#!/bin/sh
# Exercise the actual aux press/release ledger without posting system input.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/aux-button-state-tests"

swiftc -O \
    "$ROOT/MockTab/Settings/Model/ButtonBinding.swift" \
    "$ROOT/MockTab/Settings/Serialization/UnknownFieldsCodec.swift" \
    "$ROOT/MockTab/Driver/Injection/AuxButtonState.swift" \
    "$DIR/main.swift" -o "$BIN"
"$BIN"
