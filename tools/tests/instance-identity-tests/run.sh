#!/bin/sh
# Compile and run the settings-namespace claim-rule checks against the real
# source. This builds a small executable from
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
. "$DIR/../lib.sh"

swift_test instance-identity-tests --kit "$ROOT/MockTab/Driver/Devices/DeviceInstanceClaims.swift" "$DIR/InstanceIdentityTests.swift"
"$TEST_BIN"
