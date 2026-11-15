# Shared setup for the run.sh in each *-tests directory. A run.sh sources this
# right after `set -e`:
#
#   DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$DIR/../lib.sh"
#
# It sets TESTS (this directory), ROOT (the repository), and WORK (a scratch
# directory removed on exit), and defines swift_test.

TESTS="$(cd "$DIR/.." && pwd)"
ROOT="$(cd "$TESTS/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Print the directory holding the built TabletKit module and libTabletKit.a.
# TabletKit is shared by every harness that links it; the helper builds it once
# and caches it. See build-tabletkit.sh for why it compiles from source instead
# of using SwiftPM's .build output.
tabletkit_dir() {
    sh "$TESTS/build-tabletkit.sh"
}

# swift_test NAME [--kit] [--no-opt] [--no-check] SWIFTC_ARGS...
# Compiles the sources into $WORK/NAME and sets TEST_BIN to it. Builds with -O,
# the way the app ships, and adds Check.swift, the shared assertion helpers.
#   --kit       link TabletKit
#   --no-opt    build without -O
#   --no-check  leave out Check.swift
swift_test() {
    name="$1"
    shift
    opt="-O"
    kit=""
    check="$TESTS/Check.swift"
    while :; do
        case "$1" in
            --kit) kit=1 ;;
            --no-opt) opt="" ;;
            --no-check) check="" ;;
            *) break ;;
        esac
        shift
    done
    TEST_BIN="$WORK/$name"
    if [ -n "$kit" ]; then
        KIT="$(tabletkit_dir)"
        swiftc $opt -I "$KIT" ${check:+"$check"} "$@" "$KIT/libTabletKit.a" -o "$TEST_BIN"
    else
        swiftc $opt ${check:+"$check"} "$@" -o "$TEST_BIN"
    fi
}
