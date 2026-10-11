#!/bin/sh
# Compile and run the Xencelabs relink checks against the real source file.
# Sibling of tools/tests/pan-scroll-tracker-tests/run.sh.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Devices/XencelabsRelinkState.swift"
T="$(mktemp -d)"
BIN="$T/xencelabs-relink-tests"

swiftc -O "$SRC" "$DIR/XencelabsRelinkTests.swift" -o "$BIN"
"$BIN"
