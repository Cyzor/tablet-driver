#!/bin/sh
# latency_ab.sh — friendly wrapper around driver_latency_probe.c.
#
# Builds the probe if needed, walks you through one leg of the A/B (vendor
# driver OR MockTab, not both), and saves the output to a log file with a
# name you'll recognize later. Run it twice — once per driver — then pass
# the two logs to latency_summary.py.
#
# Usage:
#   tools/latency_ab.sh <vid-hex> <pid-hex> <label>
#   e.g. tools/latency_ab.sh 28bd 0914 vendor
#        tools/latency_ab.sh 28bd 0914 mocktab

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN=/tmp/driver_latency_probe
LOG_DIR=/tmp/mocktab-latency-logs

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <vid-hex> <pid-hex> <label>"
    echo "  e.g.  $0 28bd 0914 vendor"
    echo "        $0 28bd 0914 mocktab"
    exit 1
fi

VID="$1"
PID="$2"
LABEL="$3"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$LABEL-$(date +%Y%m%d-%H%M%S).log"

if [ ! -x "$BIN" ]; then
    echo "Building probe..."
    clang -framework IOKit -framework CoreFoundation -framework ApplicationServices \
        "$SCRIPT_DIR/driver_latency_probe.c" -o "$BIN"
fi

echo "=========================================================="
echo " Latency probe — leg: '$LABEL'"
echo "=========================================================="
echo "Before you continue, double-check:"
echo "  - Only ONE driver is running right now (the one this leg"
echo "    is meant to measure — quit the other one first)."
echo
echo "Log will be saved to:"
echo "  $LOG_FILE"
echo
echo "Press Enter when ready to start listening..."
read -r _

echo "Listening. Watch for [heartbeat] lines every 5s on stderr —"
echo "they tell you whether reports and pointer events are actually"
echo "being seen, instead of just staring at silence. Draw a few"
echo "seconds of varied pen strokes on the tablet now. Ctrl-C when done."
echo

# tee so you still see live output while it's also saved.
"$BIN" "$VID" "$PID" | tee "$LOG_FILE"

echo
echo "Saved: $LOG_FILE"
echo "Run the other leg next (vendor or mocktab, whichever you"
echo "haven't done yet), then:"
echo "  python3 tools/latency_summary.py $LOG_DIR/<vendor-log> $LOG_DIR/<mocktab-log>"
