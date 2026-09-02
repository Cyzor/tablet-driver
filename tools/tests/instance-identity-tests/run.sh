#!/bin/sh
# Compile and run the settings-namespace claim-rule checks against the real
# source. The app has no XCTest target, so this builds a small executable from
# DeviceInstanceClaims.swift plus the test main. DeviceInstanceClaims imports
# TabletKit (for DeviceInstanceKey), so TabletKit is built first and linked in.
# Exits non-zero on failure.
#
# DeviceInstanceKey's own value semantics are covered by DeviceInstanceKeyTests
# in the TabletKit test suite; this harness is only the host claim rule.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Devices/DeviceInstanceClaims.swift"
TEST="$DIR/InstanceIdentityTests.swift"
PKG="$ROOT/TabletKit"
BIN="$(mktemp -d)/instance-identity-tests"

# Build TabletKit and locate its module + static library. SwiftPM puts both
# directly in the bin path (TabletKit.swiftmodule as a directory bundle,
# libTabletKit.a alongside).
swift build --package-path "$PKG" -c debug
BUILD="$(swift build --package-path "$PKG" -c debug --show-bin-path)"

if [ ! -e "$BUILD/TabletKit.swiftmodule" ] || [ ! -f "$BUILD/libTabletKit.a" ]; then
    echo "error: TabletKit build products not found under $BUILD" >&2
    echo "       expected TabletKit.swiftmodule and libTabletKit.a" >&2
    exit 2
fi

swiftc -O \
    -I "$BUILD" \
    -L "$BUILD" -lTabletKit \
    "$SRC" "$TEST" -o "$BIN"
"$BIN"
