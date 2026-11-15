#!/bin/sh
# Compile and run the unknown-Wacom fallback checks: real Wacom descriptors
# replayed through routing, descriptor pen derivation, and the guessed spec,
# each compared with goldens.txt. Exits non-zero on any change.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test unknown-wacom-fallback-tests --kit --no-check -package-name TabletKit "$DIR/main.swift"
"$TEST_BIN" "$@"
