#!/bin/sh
# Compile and run the checks for mocktab: links against the real
# MockTabLink.swift and the Help section list. Exits non-zero on failure.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
BIN="$(mktemp -d)/link-tests"

swiftc -O "$ROOT/MockTab/App/MockTabLink.swift" "$ROOT/MockTab/UI/Help/HelpSection.swift" "$ROOT/MockTab/UI/Help/HelpContent.swift" "$DIR/main.swift" -o "$BIN"
"$BIN"
