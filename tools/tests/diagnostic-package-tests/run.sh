#!/bin/sh
# Compile and run the diagnostic-package checks against the real source.
# Builds a real archive with ditto and unzips it again, so the round trip —
# not just the call — is what's verified. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Diagnostics/DiagnosticPackage.swift"
TEST="$DIR/DiagnosticPackageTests.swift"
BIN="$(mktemp -d)/diagnostic-package-tests"

swiftc -O "$SRC" "$TEST" -o "$BIN"
# The source path is passed through: some checks read the flags ditto is given
# rather than the archive, because the staging strip hides them at runtime.
"$BIN" "$SRC"
