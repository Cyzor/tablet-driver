#!/usr/bin/env python3
"""Measure Bluetooth touch-frame delivery against the tablet's own clock.

Each 361-byte Bluetooth container (report 0x80) holds 4 touch sub-frames of
43 bytes at offset 109. Neither this project's decoder nor the kernel's
wacom_intuos_pro2_bt_touch() reads the trailing 2 bytes of each sub-frame.
They are a 16-bit little-endian device timestamp:

    value = frame[42] * 256 + frame[41]     # byte 42 high, byte 41 low

Hardware-measured on a PTH-660 (2026-09-03, two live sessions): one count is
0.225 ms, consecutive sub-frames are stamped exactly 100 counts (22.5 ms)
apart, and the field wraps every 14.75 s. Unverified on the PTH-860.

The host only knows when a *container* arrived. This reads when the tablet
actually *sampled*, which is the difference between "the link is slow" and
"the link dropped frames" — a distinction no host-side arrival histogram can
draw. Use it to check whether a session that felt bad actually lost frames:
loss is session-dependent, not a fixed property of the transport (one
archived session lost none, another lost 893).

Feed it hid_input_capture output:

    clang -framework IOKit -framework CoreFoundation \
        tools/capture/hid_input_capture.c -o /tmp/hid_input_capture
    /tmp/hid_input_capture 056a 0360 > /tmp/bt.txt     # PTH-660 BT
    /tmp/hid_input_capture 056a 0361 > /tmp/bt.txt     # PTH-860 BT
    tools/capture/bt_subframe_counter.py /tmp/bt.txt

Touch the tablet for ~30s with varied pacing, then Ctrl-C.

Loss is reported only across waits short enough that the field cannot have
wrapped. Counting a wrapped interval as a short one invents losses that did
not happen — an earlier version did exactly that and reported ~1500 phantom
drops, including intervals claiming more device time than host time elapsed.
The clock check below exists to catch that class of error: if it does not
report a steady rate, do not trust the loss figure above it.
"""

import re
import sys

FRAME_BASE = 109
FRAME_LEN = 43
FRAME_COUNT = 4
FIELD_BITS = 16
FIELD_MOD = 1 << FIELD_BITS
# Hardware-measured on a PTH-660 (2026-09-03): 0.225 ms per count, and the
# sub-frames inside one container are stamped exactly 100 counts (22.5 ms)
# apart. The field wraps every FIELD_MOD * TICK_MS = 14.75 s.
TICK_MS = 0.225
INTRA_CONTAINER_STEP = 100

# `hid_input_capture` prints this once per matched device, before any report.
# Echoed into this tool's output so an analysis names the hardware it came
# from — a filename is not evidence once a file is passed along, and two
# tablets in one session are indistinguishable without it.
MATCHED_RE = re.compile(
    r"^\[matched\] (.+?)\s+vid=(0x[0-9a-f]+) pid=(0x[0-9a-f]+)")

LINE_RE = re.compile(
    r"\[t=(?P<t>[\d.]+)\s+dt=\s*(?P<dt>[\d.]+)\]\s+"
    r"\[(?P<type>\w+)\s+id=0x(?P<id>[0-9a-f]+)\s+len=\s*(?P<len>\d+)\]\s+"
    r"(?P<bytes>[0-9a-f ]+)"
)


def devices(path):
    """Product name and VID/PID for each device the capture matched."""
    seen, out = set(), []
    with open(path) as fh:
        for line in fh:
            m = MATCHED_RE.match(line)
            if m:
                name, vid, pid = m.groups()
                if pid not in seen:
                    seen.add(pid)
                    out.append(f"{name.strip()} ({vid}/{pid})")
    return out


def parse(path):
    """Yield (t_ms, [(frame_index, counter, contact_count), ...]) per 0x80 report."""
    with open(path) as fh:
        for line in fh:
            m = LINE_RE.search(line)
            if not m or int(m.group("id"), 16) != 0x80:
                continue
            data = bytes.fromhex(m.group("bytes").replace(" ", ""))
            if len(data) < FRAME_BASE + FRAME_LEN * FRAME_COUNT:
                continue
            frames = []
            for i in range(FRAME_COUNT):
                off = FRAME_BASE + i * FRAME_LEN
                header = data[off]
                if not header & 0x80:          # frame-valid bit clear
                    continue
                counter = data[off + 42] * 256 + data[off + 41]
                frames.append((i, counter, header & 0x7F))
            yield float(m.group("t")), frames


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    reports = list(parse(sys.argv[1]))
    if not reports:
        sys.exit("No 0x80 reports of the expected length found. "
                 "Is this a Bluetooth capture from hid_input_capture?")

    found = devices(sys.argv[1])
    if found:
        print("Device(s): " + "; ".join(found))
        if len(found) > 1:
            print("  More than one device matched — reports below are pooled "
                  "across all of them.")
    else:
        print("Device(s): none named in this capture — no [matched] line found.")

    flat = [(t, i, c, n) for t, frames in reports for (i, c, n) in frames]
    print(f"{len(reports)} containers, {len(flat)} valid sub-frames, "
          f"{flat[-1][0] - flat[0][0]:.0f} ms elapsed\n")

    WRAP_MS = FIELD_MOD * TICK_MS

    # ---- Delivery: the measurement this tool exists for --------------------
    # A gap counts only when the device-time step agrees with the host-time
    # wait. Past one wrap the elapsed device time is unrecoverable from the
    # value alone, so those intervals are reported as unmeasurable rather
    # than guessed at.
    countable = ambiguous = missed = 0
    stalls = []
    for (t0, _, c0, _), (t1, _, c1, _) in zip(flat, flat[1:]):
        dt = t1 - t0
        if dt <= 0.05:                      # same container, no elapsed time
            continue
        raw = (c1 - c0) % FIELD_MOD
        predicted = dt / TICK_MS
        # Tolerance must stay tight in absolute counts, not scale with the
        # wait. A proportional band lets a long interval accept almost any
        # value: at 0.225 ms/count the field wraps in 14.75 s, so a wait of a
        # few hundred ms can already have wrapped and still land inside a
        # generous band — which is how an earlier version turned wrapped
        # intervals into hundreds of phantom "lost" frames. One sub-frame
        # stride of slack is enough for real jitter; anything beyond it is
        # unresolvable, not evidence of loss.
        if abs(raw - predicted) > INTRA_CONTAINER_STEP:
            ambiguous += 1
            if dt > 200:
                stalls.append(dt)
            continue
        countable += 1
        n = round(raw / INTRA_CONTAINER_STEP) - 1
        if n > 0:
            missed += n

    print(f"FRAMES LOST IN TRANSIT: {missed}"
          f"   (sampled by the tablet, never delivered to the host)")
    print(f"  measured across {countable} intervals short enough to be unambiguous")
    if missed == 0 and countable:
        print("  This session's link was clean — every frame the tablet stamped arrived.")
    elif countable:
        print(f"  Roughly {missed / countable:.2f} lost per delivered interval.")
    if ambiguous:
        print(f"  {ambiguous} intervals unmeasurable — the wait exceeded what the "
              f"{WRAP_MS / 1000:.2f} s wrap resolves")
    if stalls:
        stalls.sort(reverse=True)
        print(f"    of those, {len(stalls)} were stalls over 200 ms "
              f"(longest {stalls[0]:.0f} ms)")
        print("    Whether the tablet kept sampling through these cannot be read\n"
              "    from this field — the counter wrapped. That needs a wider\n"
              "    timestamp or a host-side arrival log spanning the stall.")

    # ---- Clock check: does the field still behave as measured? -------------
    # Guards the figure above. Sub-frames inside one container share a host
    # arrival time, so only cross-container intervals carry real elapsed time.
    print()
    rates = [((c1 - c0) % FIELD_MOD) / (t1 - t0)
             for (t0, _, c0, _), (t1, _, c1, _) in zip(flat, flat[1:])
             if 0.05 < t1 - t0 < WRAP_MS / 2]
    if len(rates) >= 20:
        rates.sort()
        med = rates[len(rates) // 2]
        lo, hi = rates[len(rates) // 20], rates[-len(rates) // 20 - 1]
        if lo > 0 and hi / lo < 1.10:
            print(f"clock check: OK — {1/med:.4f} ms per count, holding to "
                  f"+/-{max(hi/med - 1, 1 - lo/med):.1%} "
                  f"(expected {TICK_MS} ms)")
        else:
            print(f"clock check: FAILED — rate spread {lo:.3f}-{hi:.3f} counts/ms "
                  f"is too wide for a steady clock.")
            print("  Do not trust the loss figure above. Either this device's field\n"
                  "  differs from the PTH-660's, or loss is frequent enough to\n"
                  "  corrupt the rate itself.")
    else:
        print("clock check: too few cross-container intervals to verify.")

    intra = [(c1 - c0) % FIELD_MOD
             for (t0, _, c0, _), (t1, _, c1, _) in zip(flat, flat[1:])
             if t1 - t0 <= 0.05]
    if intra:
        common = max(set(intra), key=intra.count)
        share = intra.count(common) / len(intra)
        note = "" if common == INTRA_CONTAINER_STEP else \
               f"  (expected {INTRA_CONTAINER_STEP} — this device may differ)"
        print(f"sub-frame stride: {common} counts = {common * TICK_MS:.2f} ms, "
              f"{share:.0%} of frames{note}")


if __name__ == "__main__":
    main()
