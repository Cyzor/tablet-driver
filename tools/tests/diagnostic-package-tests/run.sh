#!/bin/sh
# Compile and run the diagnostic-package checks against the real source.
# Builds a real archive with ditto and unzips it again, so the round trip —
# not just the call — is what's verified. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Discovery/DiagnosticPackage.swift"
TEST="$DIR/DiagnosticPackageTests.swift"
BIN="$(mktemp -d)/diagnostic-package-tests"

swiftc -O "$SRC" "$TEST" -o "$BIN"
"$BIN"
