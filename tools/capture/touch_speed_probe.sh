#!/bin/sh
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# One-file, one-command capture for the "touch feels different depending on
# how fast I slide my finger" family of reports. Wraps hid_input_capture.c
# (raw, per-report timestamps, no vendor driver conflict) so a tester never
# has to clone the repo, know their tablet's hex product ID, run clang by
# hand, or time three separate recordings themselves.
#
# What it asks of the tester: paste one command, press Return, then slide one
# finger across the tablet three times, each time only as fast as an
# on-screen countdown asks for. That's the whole task. Everything else —
# compiling, finding the device, timing each phase, tagging the log so the
# three sweeps can be told apart later, naming the file, revealing it in
# Finder — is this script's job, not theirs.
#
# Usage:
#   sh touch_speed_probe.sh
#
# Default vendor ID is Wacom's (0x056A) and matches every connected Wacom
# device at once — no product ID needed. Override for another vendor:
#   sh touch_speed_probe.sh 28bd
#
# First run may prompt for Input Monitoring access for Terminal (or whatever
# is running this script) — that's macOS gating raw HID reports, completely
# separate from any permission already granted to MockTab itself. Grant it
# and run the command again; nothing is captured until it's allowed, and
# there's no other symptom to explain why the log came back empty.

set -eu

VID="${1:-056a}"
CACHE_DIR="${TMPDIR:-/tmp}/mocktab-touch-speed-probe"
BIN="$CACHE_DIR/hid_input_capture"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/hid_input_capture.c"
STAMP="$(date +%Y%m%d_%H%M%S)"
READABLE_STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
OUT="$HOME/Desktop/mocktab-touch-speed-$STAMP.txt"

mkdir -p "$CACHE_DIR"

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    echo "Preparing the capture tool (one-time, a few seconds)..."
    clang -O2 -framework IOKit -framework CoreFoundation "$SRC" -o "$BIN"
fi

banner() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

countdown() {
    n=$1
    while [ "$n" -gt 0 ]; do
        echo "  starting in $n..."
        sleep 1
        n=$((n - 1))
    done
    echo "  GO — slide now!"
}

mark() {
    # A line easy to find in the log later, sharing the same file the
    # capture's own [t=...] lines go into, so the phases never need
    # separate files to stay distinguishable.
    echo "===== PHASE: $1 =====" >> "$OUT"
}

banner "MockTab touch-speed capture — 3 short sweeps, ~30 seconds total"
cat <<'EOF'
This records exactly what your tablet sends while you slide one finger
across it at three different speeds, so a genuine sensor limitation can be
told apart from something MockTab is doing.

For each of the three phases:
  - Rest your finger, wait for "GO", then slide it once across the tablet
    at the requested speed and lift.
  - Doesn't need to be exact — "clearly slow" / "normal" / "clearly fast"
    is enough.

The capture starts now and stops itself after all three phases. No need to
press Ctrl-C, and nothing else on the tablet needs to be closed first.
EOF

# Both this script's own phase markers (below) and the capture binary's
# report lines write into $OUT concurrently. `>` here would give the capture
# process a file descriptor with its own fixed, non-append write position —
# a later `mark()` append can jump the file's real end past that position,
# and the capture's next line would then land at its old position and
# silently clobber the marker. `>>` puts every writer's fd in O_APPEND mode,
# so each individual write — from either process — atomically goes to
# wherever the file actually ends at that instant. (First run verified this
# the hard way: with plain `>`, every PHASE line vanished from the output.)
"$BIN" "$VID" >> "$OUT" 2>&1 &
CAPTURE_PID=$!
# The tool needs a moment after launch to find the device and register its
# report callback before anything slid across the tablet would be caught.
sleep 1

banner "Phase 1 of 3 — SLOW"
countdown 3
mark "SLOW"
sleep 5

banner "Phase 2 of 3 — NORMAL"
countdown 3
mark "NORMAL"
sleep 5

banner "Phase 3 of 3 — FAST"
countdown 3
mark "FAST"
sleep 5

kill "$CAPTURE_PID" 2>/dev/null || true
wait "$CAPTURE_PID" 2>/dev/null || true

# grep -c always prints a count, but exits 1 when that count is zero — under
# `set -e` that would abort the script right here on the empty-capture path,
# which is exactly the path this message exists to explain. The `|| true`
# neutralizes the exit status without touching the printed count.
LINES=$(grep -c '^\[t=' "$OUT" 2>/dev/null || true)
LINES=${LINES:-0}
banner "Done"
if [ "$LINES" -eq 0 ]; then
    cat <<EOF
No touch reports were recorded ($OUT is empty of them).

The most common reason: this needs Input Monitoring access, separate from
any permission MockTab already has. Open System Settings > Privacy &
Security > Input Monitoring, enable it for Terminal (or whichever app ran
this script), then run the command again.
EOF
else
    echo "Captured $LINES reports across all three phases."

    # A header naming the device and stamping when this ran, plus a rough
    # per-phase read of whether reports arrived steadily. Deliberately
    # protocol-agnostic: it never decodes X/Y (that byte layout differs by
    # tablet generation and belongs in TabletKit, not in a script every
    # tester runs) — it only asks "did reports keep arriving, roughly on
    # schedule, throughout each phase," which needs no per-device knowledge
    # and already catches the two failure shapes that matter here: nothing
    # arrived, or arrival stopped partway through.
    if command -v python3 >/dev/null 2>&1; then
        python3 "$SCRIPT_DIR/touch_speed_summarize.py" "$OUT" "$READABLE_STAMP" || true
    fi

    echo
    echo "Attach this one file to the GitHub issue — that's the whole ask:"
    echo "  $OUT"
    open -R "$OUT" 2>/dev/null || true
fi
