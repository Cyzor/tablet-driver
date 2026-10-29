#!/bin/sh
# Compile and run the touchdown click guard checks against the real
# TouchdownGuard.swift. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/touchdown-guard-tests"

swiftc -O "$ROOT/MockTab/Driver/Injection/TouchdownGuard.swift" "$DIR/main.swift" -o "$BIN"
"$BIN"
