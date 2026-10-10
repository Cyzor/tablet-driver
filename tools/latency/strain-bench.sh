#!/bin/bash
# Measure MockTab's pen latency under system strain, against a baseline.
#
# Runs driver_latency_probe for a fixed window under each condition: idle,
# every core busy, GPU memory traffic, memory pressure, and Quick Keys display
# writes. Prints p50, p95, p99, and maximum per condition, and warns when one
# grew past baseline.txt. It never fails; run it by hand before a release.
#
# - Run it from Terminal, which needs Input Monitoring.
# - Use a Release build of MockTab; Debug builds are slower and not comparable.
# - Use a wired tablet. MockTab stamps Bluetooth samples it paces with their
#   scheduled time, so the probe can't pair them with their reports.
# - Memory pressure slows the whole Mac for a minute. Save your work first.
#
# Usage:
#   tools/latency/strain-bench.sh <vid-hex> <pid-hex>            # compare
#   tools/latency/strain-bench.sh <vid-hex> <pid-hex> --update   # accept as new baseline
#   STRAIN_SECONDS=30 STRAIN_CONDITIONS="idle cpu" tools/latency/strain-bench.sh ...
set -euo pipefail

VID="${1:?usage: strain-bench.sh <vid-hex> <pid-hex> [--update]}"
PID="${2:?usage: strain-bench.sh <vid-hex> <pid-hex> [--update]}"
UPDATE="${3:-}"
WINDOW="${STRAIN_SECONDS:-20}"
CONDITIONS="${STRAIN_CONDITIONS:-idle cpu gpu memory quickkeys}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="/tmp/mocktab-strain-$(date +%Y%m%d-%H%M%S)"
PROBE=/tmp/driver_latency_probe
GPU_LOAD=/tmp/gpu_bandwidth_stress_probe
RAM_LOAD=/tmp/ram_pressure_probe
mkdir -p "$LOG_DIR"

build() {
    local src=$1 bin=$2
    shift 2
    if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
        echo "strain-bench: building $(basename "$bin")"
        "$@" "$src" -o "$bin"
    fi
}
build "$ROOT/tools/latency/driver_latency_probe.c" "$PROBE" \
    clang -framework IOKit -framework CoreFoundation -framework ApplicationServices
build "$ROOT/tools/capture/gpu_bandwidth_stress_probe.swift" "$GPU_LOAD" swiftc -O -framework Metal
build "$ROOT/tools/capture/ram_pressure_probe.swift" "$RAM_LOAD" swiftc -O

app_pid=$(pgrep -x MockTab | head -1) || { echo "strain-bench: MockTab isn't running"; exit 1; }
app_path=$(ps -o comm= -p "$app_pid" | sed 's#/Contents/MacOS/MockTab$##')
app_version=$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
app_build=$(defaults read "$app_path/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
case "$app_path" in
    *DerivedData*|*/Debug/*) echo "strain-bench: WARNING $app_path looks like a Debug build" ;;
esac

stop_load() {
    local pids
    pids=$(jobs -p)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        wait 2>/dev/null || true
    fi
}
trap stop_load EXIT

start_load() {
    case $1 in
        cpu)
            for _ in $(seq "$(sysctl -n hw.logicalcpu)"); do yes >/dev/null & done
            ;;
        gpu)
            "$GPU_LOAD" $((WINDOW + 10)) >"$LOG_DIR/gpu-load.txt" &
            sleep 2
            ;;
        memory)
            "$RAM_LOAD" $((WINDOW + 10)) >"$LOG_DIR/memory-load.txt" &
            echo "strain-bench: filling memory, which can take a minute…"
            local waited=0
            until grep -q "^Committed" "$LOG_DIR/memory-load.txt" 2>/dev/null; do
                sleep 1
                waited=$((waited + 1))
                if ((waited > 180)); then
                    echo "strain-bench: memory never filled; measuring anyway"
                    break
                fi
            done
            ;;
    esac
}

describe() {
    case $1 in
        idle) echo "Nothing else running." ;;
        cpu) echo "Every core busy." ;;
        gpu) echo "Heavy GPU memory traffic." ;;
        memory) echo "Memory nearly full, so the system compresses and swaps." ;;
        quickkeys) echo "With your other hand, press the Quick Keys mode button about once a second. Each press sends the mode name and dial color. Skip this one without Quick Keys." ;;
    esac
}

echo "strain-bench: MockTab $app_version ($app_build), $WINDOW s per condition, logs in $LOG_DIR"
echo "For every condition, draw the same way: circles over the middle of the screen,"
echo "about one a second, alternating hover and touch, for the whole window."
for cond in $CONDITIONS; do
    echo
    echo "== $cond: $(describe "$cond")"
    printf "Press Enter, then start drawing (or type s to skip): "
    read -r answer
    [[ "$answer" == s ]] && continue
    start_load "$cond"
    "$PROBE" "$VID" "$PID" "$WINDOW" >"$LOG_DIR/$cond.log"
    stop_load
    echo "Done. Stop drawing."
done

tablet=$(sed -n 's/^\[matched\] \(.*\) — .*/\1/p' "$LOG_DIR"/*.log 2>/dev/null | head -1 || true)
context="$(date +%Y-%m-%d), $tablet,"
context+=" macOS $(sw_vers -productVersion), $(sysctl -n hw.model), MockTab $app_version ($app_build)"
echo
python3 "$ROOT/tools/latency/strain_summary.py" "$LOG_DIR" --context "$context" ${UPDATE:+"$UPDATE"}
