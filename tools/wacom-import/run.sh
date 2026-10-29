#!/bin/sh
# Build the Wacom import report and run it on a Wacom settings backup. See
# main.swift's header for what it reports. Writes nothing.
#
# Usage: tools/wacom-import/run.sh <backup.wacomprefs>
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(sh "$DIR/../tests/build-tabletkit.sh")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

swiftc -O -I "$KIT" -L "$KIT" -lTabletKit "$DIR/WacomPrefs.swift" "$DIR/main.swift" -o "$T/wacom-import"
"$T/wacom-import" "$@"
