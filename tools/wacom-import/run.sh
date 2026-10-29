#!/bin/sh
# Build the Wacom import report and run it on a Tablet Utility backup. See
# main.swift's header for what it reports. Writes nothing.
#
# Usage: tools/wacom-import/run.sh <backup.wacomprefs>
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

swiftc -O "$DIR/WacomPrefs.swift" "$DIR/main.swift" -o "$T/wacom-import"
"$T/wacom-import" "$@"
