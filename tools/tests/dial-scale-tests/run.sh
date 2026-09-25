#!/bin/sh
# Compile and run ring/dial rotate and zoom scale checks. Pure arithmetic —
# InputInjector can't build standalone, so the formulas are restated in the
# test and pinned to the same measured steps/revolution.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
TEST="$DIR/main.swift"
T="$(mktemp -d)"
BIN="$T/dial-scale-tests"

swiftc -O "$TEST" -o "$BIN"
"$BIN"
