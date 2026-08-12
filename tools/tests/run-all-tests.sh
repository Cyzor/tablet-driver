#!/bin/sh
# Run every standalone test harness under tools/*-tests/ and report a single
# pass/fail summary. Exits non-zero if any harness fails.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED=""

for d in "$DIR"/*-tests; do
    name="$(basename "$d")"
    echo "=== $name ==="
    if ( cd "$d" && sh run.sh ); then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        FAILED="$FAILED $name"
    fi
    echo
done

if [ -n "$FAILED" ]; then
    echo "FAILED:$FAILED"
    exit 1
fi

echo "All test harnesses passed."
