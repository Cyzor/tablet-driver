#!/bin/sh
# Build TabletKit and the recording check, then replay the hid-recorder files
# given. See main.swift's header for what it compares.
#
# Usage: tools/recording-check/run.sh [-v] [-n examples] recording.hid...
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(sh "$DIR/../tests/build-tabletkit.sh")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

swiftc -O -I "$KIT" -L "$KIT" -lTabletKit "$DIR/main.swift" -o "$T/recording-check"
"$T/recording-check" "$@"
