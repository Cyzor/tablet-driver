#!/bin/sh
# Compile and run the unknown-Wacom fallback checks: real Wacom descriptors
# replayed through routing, descriptor pen derivation, and the guessed spec,
# each compared with goldens.txt. Exits non-zero on any change.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
T="$(mktemp -d)"
BIN="$T/unknown-wacom-fallback-tests"

# Shares the cached TabletKit build; see tools/tests/build-tabletkit.sh.
# The package name reaches TabletKit's package-level routing API.
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -package-name TabletKit -I "$KIT" "$DIR/main.swift" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN" "$@"
