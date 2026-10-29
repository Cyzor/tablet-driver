#!/bin/sh
# Build the Wacom import tool and run it on a Wacom settings backup. See
# main.swift's header for the options. Without --apply it writes nothing.
#
# Usage: tools/wacom-import/run.sh [--apply [options]] <backup.wacomprefs>
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(sh "$DIR/../tests/build-tabletkit.sh")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

S="$DIR/../../MockTab/Settings"

# The app's setting types and import decoder, so values are stored as the app
# stores them; the stub stands in for the two app types the decoder names.
swiftc -O -I "$KIT" -L "$KIT" -lTabletKit \
    "$DIR/WacomPrefs.swift" "$DIR/Encoder.swift" "$DIR/Writer.swift" "$DIR/Apply.swift" \
    "$S/Serialization/ConfigurationImporter.swift" "$S/Serialization/ImportPlan.swift" \
    "$S/Serialization/UnknownFieldsCodec.swift" "$S/Model/ButtonBinding.swift" \
    "$S/Model/ControlSlot.swift" "$S/Model/RotaryConfig.swift" "$S/Model/BezierCurve.swift" \
    "$DIR/../tests/configuration-display-region-tests/StubTypes.swift" \
    "$DIR/main.swift" -o "$T/wacom-import"
"$T/wacom-import" "$@"
