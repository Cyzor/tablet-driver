#!/bin/sh
# Compile and run the settings backup checks against the real source file.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/settings-backup-tests"

swiftc -O \
    "$ROOT/MockTab/Settings/Serialization/SettingsBackup.swift" \
    "$DIR/main.swift" \
    -o "$BIN"
"$BIN"
