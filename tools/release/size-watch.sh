#!/bin/bash
# Compare an exported MockTab.app against the recorded size baseline.
#
# Warns when the executable or bundle grows more than 15 percent, or when the
# app links a framework the baseline doesn't list. It never fails the build;
# the release scripts call it so growth is seen at snapshot and release time.
#
# Usage:
#   tools/release/size-watch.sh <path/to/MockTab.app>            # compare
#   tools/release/size-watch.sh <path/to/MockTab.app> --update   # accept as new baseline
set -euo pipefail

APP="${1:?usage: size-watch.sh <MockTab.app> [--update]}"
BASELINE="$(cd "$(dirname "$0")" && pwd)/size-baseline.txt"
EXE="$APP/Contents/MacOS/MockTab"
LIMIT_PERCENT=15

exe_bytes=$(stat -f %z "$EXE")
bundle_kb=$(du -sk "$APP" | cut -f1)
frameworks=$(otool -L "$EXE" | tail -n +2 | awk '{print $1}' | sed 's#.*/##' | sort -u)

if [[ "${2:-}" == "--update" ]]; then
    {
        echo "exe_bytes $exe_bytes"
        echo "bundle_kb $bundle_kb"
        for f in $frameworks; do echo "link $f"; done
    } >"$BASELINE"
    echo "size-watch: baseline updated ($exe_bytes B executable, $bundle_kb KB bundle)"
    exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
    echo "size-watch: no baseline; run with --update to record one"
    exit 0
fi

warned=0
check() {
    local name=$1 now=$2 was
    was=$(awk -v k="$name" '$1 == k {print $2}' "$BASELINE")
    local pct=$(( (now - was) * 100 / was ))
    echo "size-watch: $name $was → $now (${pct}%)"
    if (( pct > LIMIT_PERCENT )); then
        echo "size-watch: WARNING $name grew more than ${LIMIT_PERCENT}%"
        warned=1
    fi
}
check exe_bytes "$exe_bytes"
check bundle_kb "$bundle_kb"

for f in $frameworks; do
    if ! grep -qx "link $f" "$BASELINE"; then
        echo "size-watch: WARNING new linked library $f"
        warned=1
    fi
done

if (( warned )); then
    echo "size-watch: if the growth is intended, accept it with --update and commit the baseline"
fi
