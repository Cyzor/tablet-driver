#!/bin/sh
# Compile and run touch-state intent checks against the real source file.
# The app has no XCTest target, so this builds a small executable from
# TouchStateTracker.swift plus the test main and runs it.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
SRC="$ROOT/MockTab/Driver/Injection/TouchStateTracker.swift"
TEST="$DIR/TouchStateTrackerTests.swift"
T="$(mktemp -d)"
BIN="$T/touch-state-tracker-tests"

# TabletKit is compiled straight from source rather than located inside its
# SwiftPM .build directory. That layout is not stable across toolchains — newer
# ones emit libTabletKit.a and put the module beside the products, older ones
# emit no archive and use debug/Modules/ — so any `find` for it passes on one
# machine and fails on another. This harness therefore builds what it needs and
# depends on no SwiftPM output at all; it runs correctly with .build absent.
# Whether the package itself builds is TabletKit's own `swift test` job.
KIT_SRCS=$(find "$ROOT/TabletKit/Sources/TabletKit" -name '*.swift')
swiftc -O -emit-module -emit-library -static -module-name TabletKit \
  -emit-module-path "$T/TabletKit.swiftmodule" -o "$T/libTabletKit.a" $KIT_SRCS

swiftc -O -I "$T" "$SRC" "$TEST" "$T/libTabletKit.a" -o "$BIN"
"$BIN"
