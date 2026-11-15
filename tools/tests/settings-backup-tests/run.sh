#!/bin/sh
# Compile and run the settings backup checks against the real source file.
# Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test settings-backup-tests "$ROOT/MockTab/Settings/Serialization/SettingsBackup.swift" "$DIR/main.swift"
"$TEST_BIN"
