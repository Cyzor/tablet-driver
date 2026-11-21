#!/bin/sh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build every tool that only runs by hand, so a change to the app or
# TabletKit that breaks one fails here, not at the next hardware session.
# Scripts with their own build steps build through --build-only.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"

T="$ROOT/tools"
failed=0
build() {
    name="$1"
    shift
    if "$@" >"$WORK/$name.log" 2>&1; then
        echo "built $name"
    else
        failed=$((failed + 1))
        echo "FAIL: $name"
        grep -m 5 'error' "$WORK/$name.log" || tail -n 5 "$WORK/$name.log"
    fi
}

export MOCKTAB_HWCHECK_WORK="$WORK/hardware-check"
build hardware-check bash "$T/hardware-check/hardware-check.sh" --build-only
build key-order bash "$T/hardware-check/key-order.sh" --build-only
build recording-check sh "$T/recording-check/run.sh" --build-only
build wacom-settings sh "$T/wacom-settings/run.sh" --build-only
build event-probe swiftc -O "$T/event-probe/main.swift" -o "$WORK/event-probe"
build gpu-probe swiftc -O "$T/capture/gpu_bandwidth_stress_probe.swift" -framework Metal -o "$WORK/gpu-probe"
build ram-probe swiftc -O "$T/capture/ram_pressure_probe.swift" -o "$WORK/ram-probe"
for c in capture/hid_descriptor_dump capture/hid_feature_get capture/hid_input_capture latency/driver_latency_probe; do
    build "${c#*/}" clang -framework IOKit -framework CoreFoundation -framework ApplicationServices \
        "$T/$c.c" -o "$WORK/${c#*/}"
done

echo "tool builds: $failed failed"
[ "$failed" -eq 0 ]
