#!/bin/bash
# Report the running MockTab's idle CPU and memory against a budget.
#
# Run by hand before a release, with a tablet connected, the pen away, and no
# settings window open. Warns only; numbers above budget deserve a look.
#
# Usage: tools/release/idle-check.sh [seconds]
set -euo pipefail

SECONDS_TO_SAMPLE="${1:-10}"
CPU_BUDGET_PERCENT=0.5
FOOTPRINT_BUDGET_MB=40

pid=$(pgrep -x MockTab | head -1) || { echo "idle-check: MockTab isn't running"; exit 1; }

# The first top sample has no prior interval, so average the rest.
cpu=$(top -l $((SECONDS_TO_SAMPLE + 1)) -s 1 -pid "$pid" -stats cpu |
    awk '/^[0-9.]+$/ { n++; if (n > 1) { sum += $1; count++ } } END { printf "%.2f", count ? sum / count : 0 }')
footprint=$(footprint "$pid" | awk '/phys_footprint:/ { print $2; exit }')

echo "idle-check: CPU ${cpu}% over ${SECONDS_TO_SAMPLE} s (budget ${CPU_BUDGET_PERCENT}%)"
echo "idle-check: footprint ${footprint} MB (budget ${FOOTPRINT_BUDGET_MB} MB)"

awk -v c="$cpu" -v b="$CPU_BUDGET_PERCENT" 'BEGIN { exit !(c > b) }' &&
    echo "idle-check: WARNING idle CPU above budget; sample it with: sample $pid 5"
(( ${footprint%.*} > FOOTPRINT_BUDGET_MB )) &&
    echo "idle-check: WARNING footprint above budget; a settings window opened this session keeps about 55 MB until relaunch"
exit 0
