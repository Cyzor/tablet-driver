#!/usr/bin/env python3
# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Companion to touch_speed_probe.sh. Prepends a header naming the device(s)
# and recording time, then gives a rough per-phase verdict — normal, no
# data, or a gap — so the raw log isn't opaque to the person who ran it or
# to anyone they hand it to.
#
# Deliberately does not decode X/Y position. That byte layout is a different
# shape per tablet generation (TabletKit's BPT3ContainerDecoder.swift vs. the
# IntuosV2 family's own report layout, and others), and hardcoding one into
# a script every tester runs would either be wrong for their specific model
# or need constant upkeep as new families are added. What doesn't need any
# of that: whether reports kept arriving, roughly on schedule, for the whole
# time they were asked to slide a finger. That's timing-only and answers the
# two failure shapes that actually matter here — nothing arrived, or arrival
# stopped partway through — without needing to know a single byte offset.
#
# Usage: touch_speed_summarize.py <capture-file> <readable-timestamp>

import re
import sys

MATCHED_RE = re.compile(r"^\[matched\] (.+?)\s+vid=(0x[0-9a-f]+) pid=(0x[0-9a-f]+)")
REPORT_RE = re.compile(r"^\[t=([\d.]+) dt=")
PHASE_RE = re.compile(r"^===== PHASE: (\w+) =====")

# Above this inter-report gap, during a phase the tester was actively told
# to be touching the tablet, call it a probable dropout rather than normal
# jitter. Calibrated against real captures, not guessed: PTH-660 and
# PTH-850 both showed isolated single-blip gaps of 200-400ms mid-phase —
# a tester briefly lifting to reposition partway through a 5-second window
# is normal, not a defect. The dropouts this tool exists to catch (BT touch
# dying, a stuck proximity signal) have historically lasted seconds to
# indefinitely, not hundreds of milliseconds — so the threshold sits well
# above the largest benign gap actually observed (400ms) and well below the
# shortest real dropout this project has ever fixed.
GAP_THRESHOLD_MS = 750.0
# Fewer than this many reports in a phase reads as "essentially nothing
# happened," not just "a slow trickle."
MIN_REPORTS_FOR_DATA = 5


def main():
    if len(sys.argv) < 3:
        print("usage: touch_speed_summarize.py <capture-file> <readable-timestamp>",
              file=sys.stderr)
        return 1
    path, stamp = sys.argv[1], sys.argv[2]

    devices = []
    seen_pids = set()
    phases = []  # (name, [timestamps])
    current = None
    total_reports = 0

    with open(path, "r", errors="replace") as f:
        for line in f:
            m = MATCHED_RE.match(line)
            if m:
                name, vid, pid = m.groups()
                if pid not in seen_pids:
                    seen_pids.add(pid)
                    devices.append(f"{name.strip()} ({vid}/{pid})")
                continue
            m = PHASE_RE.match(line)
            if m:
                current = (m.group(1), [])
                phases.append(current)
                continue
            m = REPORT_RE.match(line)
            if m and current is not None:
                current[1].append(float(m.group(1)))
                total_reports += 1

    lines = []
    lines.append("=" * 60)
    lines.append("MockTab touch-speed capture — summary")
    lines.append("=" * 60)
    lines.append(f"Recorded: {stamp}")
    if devices:
        lines.append("Device(s) seen: " + "; ".join(devices))
        if len(devices) > 1:
            lines.append(
                "Note: more than one device matched, so the report counts "
                "below are pooled across all of them — this can't tell "
                "which device sent which report.")
    else:
        lines.append("Device(s) seen: none matched — nothing was listening")
    lines.append(f"Total reports captured (all phases): {total_reports}")
    lines.append("")

    any_problem = False
    for name, timestamps in phases:
        n = len(timestamps)
        if n < MIN_REPORTS_FOR_DATA:
            verdict = f"NO DATA — only {n} report(s). Nothing seems to have " \
                      "touched the tablet during this phase, or reports " \
                      "aren't reaching this tool at all."
            any_problem = True
        else:
            gaps = [timestamps[i] - timestamps[i - 1] for i in range(1, n)]
            gaps.sort()
            worst = gaps[-1]
            median = gaps[len(gaps) // 2]
            if worst > GAP_THRESHOLD_MS:
                verdict = (
                    f"POSSIBLE DROPOUT — {n} reports, typical gap "
                    f"{median:.0f} ms, but one gap reached {worst:.0f} ms. "
                    "Reporting stalled briefly partway through this phase.")
                any_problem = True
            else:
                verdict = (
                    f"looks normal — {n} reports, gaps stayed under "
                    f"{worst:.0f} ms throughout (typical {median:.0f} ms).")
        lines.append(f"{name}: {verdict}")

    lines.append("")
    if any_problem:
        lines.append(
            "At least one phase above looks incomplete. Worth trying again "
            "before reading anything into the numbers.")
    else:
        lines.append(
            "All three phases look like clean, steady recordings — the raw "
            "data below should be trustworthy to draw conclusions from.")
    lines.append("=" * 60)
    lines.append("")

    header = "\n".join(lines)

    with open(path, "r", errors="replace") as f:
        body = f.read()
    with open(path, "w") as f:
        f.write(header + "\n" + body)

    print(header)
    return 0


if __name__ == "__main__":
    sys.exit(main())
