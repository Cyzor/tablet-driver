#!/bin/sh
# Compile and run the diagnostic-package checks against the real source.
# Builds a real archive with ditto and unzips it again, so the round trip —
# not just the call — is what's verified. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

swift_test diagnostic-package-tests "$ROOT/MockTab/Driver/Diagnostics/DiagnosticPackage.swift" "$ROOT/MockTab/App/DateStamp.swift" "$DIR/DiagnosticPackageTests.swift"
"$TEST_BIN" "$ROOT/MockTab/Driver/Diagnostics/DiagnosticPackage.swift"
