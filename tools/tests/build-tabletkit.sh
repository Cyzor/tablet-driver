#!/bin/sh
# Build TabletKit once and cache it for the harnesses that link against it.
#
# TabletKit is compiled straight from source rather than located inside its
# SwiftPM .build directory. That layout is not stable across toolchains — newer
# ones emit libTabletKit.a and put the module beside the products, older ones
# emit no archive and use debug/Modules/ — so any `find` for it passes on one
# machine and fails on another. The harnesses therefore build what they need and
# depend on no SwiftPM output at all; they run correctly with .build absent.
# Whether the package itself builds is TabletKit's own `swift test` job.
#
# Three harnesses need this identical archive, so a full-suite run compiled the
# same ~13K lines three times. Output goes to a cache directory that outlives
# each harness's own mktemp dir, and the build is skipped when the archive is
# newer than every source file.
#
# Usage: build-tabletkit.sh [cache-dir]   → prints the directory holding
# TabletKit.swiftmodule and libTabletKit.a.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC_DIR="$ROOT/TabletKit/Sources/TabletKit"
CACHE="${1:-${TMPDIR:-/tmp}/mocktab-testkit-cache}"
LIB="$CACHE/libTabletKit.a"

mkdir -p "$CACHE"

# Rebuild when the archive is missing, or when any source is newer than it.
# `find -newer` lists the offenders; empty means the cache is current.
if [ ! -f "$LIB" ] || [ -n "$(find "$SRC_DIR" -name '*.swift' -newer "$LIB" 2>/dev/null)" ]; then
    KIT_SRCS=$(find "$SRC_DIR" -name '*.swift')
    # Build into a temp dir and move it into place, so an interrupted or failed
    # compile can't leave a truncated archive that later runs treat as current.
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    swiftc -O -emit-module -emit-library -static -module-name TabletKit \
        -emit-module-path "$STAGE/TabletKit.swiftmodule" -o "$STAGE/libTabletKit.a" $KIT_SRCS
    mv "$STAGE/TabletKit.swiftmodule" "$CACHE/TabletKit.swiftmodule"
    mv "$STAGE/libTabletKit.a" "$LIB"
fi

echo "$CACHE"
