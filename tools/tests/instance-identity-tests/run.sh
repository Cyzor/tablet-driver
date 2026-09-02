#!/bin/sh
# Compile and run the settings-namespace claim-rule checks against the real
# source. The app has no XCTest target, so this builds a small executable from
# DeviceInstanceClaims.swift plus the test main.
#
# DeviceInstanceClaims imports TabletKit (for DeviceInstanceKey), so it links
# the shared TabletKit archive the helper builds and caches — see
# tools/tests/build-tabletkit.sh for why that compiles from source rather than
# reaching into SwiftPM's .build output.
#
# DeviceInstanceKey's own value semantics are covered by DeviceInstanceKeyTests
# in the TabletKit test suite; this harness is only the host claim rule.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Devices/DeviceInstanceClaims.swift"
TEST="$DIR/InstanceIdentityTests.swift"
T="$(mktemp -d)"
BIN="$T/instance-identity-tests"

KIT="$($ROOT/tools/tests/build-tabletkit.sh)"

swiftc -O -I "$KIT" "$SRC" "$TEST" "$KIT/libTabletKit.a" -o "$BIN"
"$BIN"
