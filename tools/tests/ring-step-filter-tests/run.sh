#!/bin/sh
# Compile and run the touch ring step checks against the real
# RingStepFilter.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/ring-step-filter-tests"

swiftc -O "$ROOT/MockTab/Driver/Injection/RingStepFilter.swift" "$DIR/main.swift" -o "$BIN"
"$BIN"
