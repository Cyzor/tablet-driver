#!/bin/sh
# Replay captured interface descriptors through the app's routing decision.
# corpus*.json come from build-corpus.py. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
T="$(mktemp -d)"
BIN="$T/interface-routing-tests"
KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -I "$KIT" "$ROOT/MockTab/Driver/Devices/InterfaceRouting.swift" \
    "$DIR/InterfaceRoutingTests.swift" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN" "$DIR/corpus.json" "$DIR/corpus-linuxwacom.json"
