#!/usr/bin/env bash
# Periodic upstream sweep: fetch libwacom, input-wacom, OTD and diff each
# from the pin recorded in Notes/Scratch/upstream-pins.md to current HEAD.
#
# Output is a single markdown report under Notes/Scratch/upstream-sweep-<date>.md.
# Bump the SHAs in upstream-pins.md by hand after reviewing the report.
#
# Usage: tools/upstream-sweep.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="$REPO_ROOT/Notes/Scratch/upstream"
PINS="$REPO_ROOT/Notes/Scratch/upstream-pins.md"
OUT="$REPO_ROOT/Notes/Scratch/upstream-sweep-$(date +%Y-%m-%d).md"

if [[ ! -f "$PINS" ]]; then
  echo "missing $PINS" >&2
  exit 1
fi

# Extract pinned short SHAs from the table in upstream-pins.md.
pin_for() {
  grep -E "\| $1 " "$PINS" | sed -E 's/.*`([a-f0-9]+)`.*/\1/' | head -1
}

LIBWACOM_PIN=$(pin_for "linuxwacom/libwacom")
INPUTWACOM_PIN=$(pin_for "linuxwacom/input-wacom")
OTD_PIN=$(pin_for "OpenTabletDriver/OpenTabletDriver")

echo "# Upstream sweep $(date +%Y-%m-%d)" >"$OUT"
echo >>"$OUT"
echo "Pins: libwacom=\`$LIBWACOM_PIN\`, input-wacom=\`$INPUTWACOM_PIN\`, OTD=\`$OTD_PIN\`" >>"$OUT"
echo >>"$OUT"

sweep() {
  local name="$1" dir="$2" pin="$3" shift_count=3
  shift 3
  local paths=("$@")

  echo "## $name" >>"$OUT"
  echo >>"$OUT"

  if [[ ! -d "$UPSTREAM/$dir/.git" ]]; then
    echo "_no clone at $UPSTREAM/$dir — skipping_" >>"$OUT"
    echo >>"$OUT"
    return
  fi

  ( cd "$UPSTREAM/$dir" && git fetch --quiet origin )

  local head
  head=$( cd "$UPSTREAM/$dir" \
       && { git rev-parse --short origin/HEAD 2>/dev/null \
            || git rev-parse --short origin/master 2>/dev/null \
            || git rev-parse --short origin/main; } | head -1 )

  echo "HEAD: \`$head\` (pin \`$pin\`)" >>"$OUT"
  echo >>"$OUT"

  if [[ "$head" == "$pin"* || "$pin" == "$head"* ]]; then
    echo "_no new commits_" >>"$OUT"
    echo >>"$OUT"
    return
  fi

  echo "### Commit log" >>"$OUT"
  echo '```' >>"$OUT"
  ( cd "$UPSTREAM/$dir" && git log --oneline "$pin..$head" -- "${paths[@]}" ) >>"$OUT" || true
  echo '```' >>"$OUT"
  echo >>"$OUT"

  echo "### Files changed" >>"$OUT"
  echo '```' >>"$OUT"
  ( cd "$UPSTREAM/$dir" && git diff --stat "$pin..$head" -- "${paths[@]}" ) >>"$OUT" || true
  echo '```' >>"$OUT"
  echo >>"$OUT"
}

sweep "libwacom — data" libwacom "$LIBWACOM_PIN" \
  "data/"

sweep "input-wacom — decoder sources" input-wacom "$INPUTWACOM_PIN" \
  "4.18/wacom_wac.c" "4.18/wacom_wac.h" "4.18/wacom_sys.c"

sweep "OTD — Wacom configs" OpenTabletDriver "$OTD_PIN" \
  "OpenTabletDriver.Configurations/Configurations/Wacom/"

sweep "OTD — non-Wacom vendor configs" OpenTabletDriver "$OTD_PIN" \
  "OpenTabletDriver.Configurations/Configurations/Huion/" \
  "OpenTabletDriver.Configurations/Configurations/Xencelabs/" \
  "OpenTabletDriver.Configurations/Configurations/XPPen/" \
  "OpenTabletDriver.Configurations/Configurations/UCLogic/"

echo "## OTD open device-support issues" >>"$OUT"
echo >>"$OUT"
if command -v gh >/dev/null 2>&1; then
  echo '```' >>"$OUT"
  gh issue list --repo OpenTabletDriver/OpenTabletDriver \
    --label "device support" --state open --limit 50 \
    --json number,title,createdAt \
    --template '{{range .}}#{{.number}} {{.title}} ({{timeago .createdAt}}){{"\n"}}{{end}}' \
    >>"$OUT" 2>/dev/null || echo "(gh failed)" >>"$OUT"
  echo '```' >>"$OUT"
else
  echo "_install gh to include device-support issue feed_" >>"$OUT"
fi
echo >>"$OUT"

echo "Report written to $OUT"
echo "After review, update SHAs in $PINS."
