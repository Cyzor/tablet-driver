#!/bin/sh
# Build the Wacom import tool if needed and run it on a Wacom settings backup.
# See main.swift's header for the options. Without --apply it writes nothing.
#
# The built tool is cached and rebuilt only when a source file changes, so
# only the first run, or one after an edit, waits for the compiler.
#
# Usage: tools/wacom-import/run.sh [--apply [options]] <backup.wacomprefs>
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
S="$DIR/../../MockTab/Settings"
CACHE="${TMPDIR:-/tmp}/mocktab-wacom-import-cache"
BIN="$CACHE/wacom-import"
KIT="$(sh "$DIR/../tests/build-tabletkit.sh")"

# Runs "$@" with the tool's sources appended. The app's setting types and
# import decoder are in the list, so values are stored as the app stores
# them; the stub stands in for the two app types the decoder names.
with_sources() {
    "$@" \
        "$DIR/WacomPrefs.swift" "$DIR/Encoder.swift" "$DIR/Writer.swift" "$DIR/Apply.swift" \
        "$S/Serialization/ConfigurationImporter.swift" "$S/Serialization/ImportPlan.swift" \
        "$S/Serialization/UnknownFieldsCodec.swift" "$S/Model/ButtonBinding.swift" \
        "$S/Model/ControlSlot.swift" "$S/Model/RotaryConfig.swift" "$S/Model/BezierCurve.swift" \
        "$DIR/../tests/configuration-display-region-tests/StubTypes.swift" \
        "$DIR/main.swift"
}

# Succeeds when the cached tool is missing or older than TabletKit, this
# script (it holds the build flags), or a source.
stale() {
    [ -x "$BIN" ] || return 0
    [ -n "$(find "$KIT/libTabletKit.a" "$DIR/run.sh" "$@" -newer "$BIN")" ]
}

if with_sources stale; then
    echo "Building the Wacom import tool (a few seconds, once per change)..." >&2
    mkdir -p "$CACHE"
    # Unoptimized: it builds in a quarter of the time and runs as fast.
    with_sources swiftc -I "$KIT" -L "$KIT" -lTabletKit -o "$BIN.new"
    mv -f "$BIN.new" "$BIN"
fi

"$BIN" "$@"
