#!/bin/bash
# Builds and runs wacom_key_order, which checks a Wacom tablet's key order
# against the Buttons pane's control map one key at a time. Keep MockTab
# running. The terminal needs Input Monitoring.
#
# Usage: tools/hardware-check/key-order.sh [--out <dir>]
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)"
HERE="$ROOT/tools/hardware-check"
WORK=/tmp/mocktab-hwcheck
KIT="$WORK/tabletkit"
FIGURES="$ROOT/MockTab/Figures"
SOURCES=("$HERE/wacom_key_order.swift" "$FIGURES/TabletControlMap.swift" "$FIGURES/TabletLayoutIdentity.swift"
         "$FIGURES/TabletLayoutTable.swift" "$FIGURES/TabletFigure.swift" "$ROOT/MockTab/Settings/Model/TabletOrientation.swift")

mkdir -p "$WORK/bin" "$KIT"
# Same TabletKit build as hardware-check.sh.
if [[ ! -f "$KIT/libTabletKit.a" || -n $(find "$ROOT/TabletKit/Sources/TabletKit" -name '*.swift' -newer "$KIT/libTabletKit.a") ]]; then
    echo "key-order: building TabletKit"
    swiftc -O -parse-as-library -module-name TabletKit -package-name TabletKit -emit-module \
        -emit-module-path "$KIT/TabletKit.swiftmodule" -emit-library -static -o "$KIT/libTabletKit.a" \
        $(find "$ROOT/TabletKit/Sources/TabletKit" -name '*.swift')
    rm -f "$WORK/bin/wacom_key_order"
fi
BIN="$WORK/bin/wacom_key_order"
if [[ ! -x "$BIN" || -n $(find "${SOURCES[@]}" -newer "$BIN") ]]; then
    swiftc -O -parse-as-library -I "$KIT" -L "$KIT" -lTabletKit "${SOURCES[@]}" -o "$BIN"
fi
exec "$BIN" "$@"
