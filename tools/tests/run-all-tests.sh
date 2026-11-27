#!/bin/sh
# Run every *-tests harness. They don't depend on each other, so they run in
# parallel, one per core; each one's output prints in name order once all
# finish. TabletKit builds first, so the harnesses that link it share one
# build instead of racing to make it.
#
# Usage: tools/tests/run-all-tests.sh [jobs]
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS="${1:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

sh "$DIR/build-tabletkit.sh" >/dev/null || { echo "FAIL: TabletKit build"; exit 1; }

for d in "$DIR"/*-tests; do basename "$d"; done \
    | xargs -P "$JOBS" -I{} sh -c '
        if ( cd "$1/$2" && sh run.sh ) >"$3/$2.log" 2>&1; then
            echo PASS >"$3/$2.result"
        else
            echo FAIL >"$3/$2.result"
        fi' _ "$DIR" {} "$LOGS"

FAILED=""
for d in "$DIR"/*-tests; do
    name="$(basename "$d")"
    echo "=== $name ==="
    cat "$LOGS/$name.log"
    result="$(cat "$LOGS/$name.result" 2>/dev/null || echo FAIL)"
    echo "$result: $name"
    [ "$result" = PASS ] || FAILED="$FAILED $name"
    echo
done

if [ -n "$FAILED" ]; then
    echo "FAILED:$FAILED"
    exit 1
fi

echo "All test harnesses passed."
