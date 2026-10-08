#!/bin/bash
# Fail unless every executable in an exported MockTab.app runs on both Apple
# silicon and Intel.
#
# Xcode drops Intel from its standard architectures without a warning once
# the deployment target reaches macOS 27, so a universal build can quietly
# become arm64-only. The release scripts call this so that can't ship.
#
# Usage:
#   tools/release/arch-check.sh <path/to/MockTab.app>
set -euo pipefail

APP="${1:?usage: arch-check.sh <MockTab.app>}"
REQUIRED="arm64 x86_64"
status=0
checked=0

while IFS= read -r -d '' file; do
    archs=$(lipo -archs "$file" 2>/dev/null) || continue
    checked=$((checked + 1))
    for arch in $REQUIRED; do
        if [[ " $archs " != *" $arch "* ]]; then
            echo "arch-check: ${file#"$APP"/} lacks $arch (has: $archs)" >&2
            status=1
        fi
    done
done < <(find "$APP/Contents" -type f -perm -u+x -print0)

if [[ $checked -eq 0 ]]; then
    echo "arch-check: no executables found in $APP" >&2
    exit 1
fi
[[ $status -eq 0 ]] && echo "arch-check: $checked executable(s) are universal"
exit $status
