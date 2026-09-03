#!/usr/bin/env python3
"""Decode the unread 14-bit field in Wacom BT (0x80) touch sub-frames.

Each 361-byte Bluetooth container holds 4 touch sub-frames of 43 bytes at
offset 109. Both our decoder and the kernel's wacom_intuos_pro2_bt_touch()
read only 41 of those bytes (header + 5 contacts x 8); the trailing 2 --
relative offsets 41 and 42 -- are unread. Across archived captures the byte
at rel 41 takes only multiples of 4 (64 distinct values) while rel 42 spans
0-255, which is the shape of a 14-bit little-endian field:

    value = frame[42] * 256 + frame[41]     # byte 42 high, byte 41 low

This script says what that field actually counts, which aggregate byte
statistics cannot: a constant per-frame step means a sequence number, a step
proportional to elapsed wall-clock time means a device timestamp.

Feed it hid_input_capture output:

    clang -framework IOKit -framework CoreFoundation \
        tools/capture/hid_input_capture.c -o /tmp/hid_input_capture
    /tmp/hid_input_capture 056a 0360 > /tmp/bt.txt     # PTH-660 BT
    /tmp/hid_input_capture 056a 0361 > /tmp/bt.txt     # PTH-860 BT
    tools/capture/bt_subframe_counter.py /tmp/bt.txt

Touch the tablet in slow sweeps for ~30s, including a pause or two, then
Ctrl-C. Pauses matter: a sequence number freezes while nothing is sampled,
a timestamp keeps running.
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


    # Steps between consecutive sub-frames, in container order.
    steps, per_ms = [], []
    for (t0, _, c0, _), (t1, _, c1, _) in zip(flat, flat[1:]):
        step = (c1 - c0) % FIELD_MOD
        steps.append(step)
        dt = t1 - t0
        if 0.05 < dt < 200:           # skip same-container frames and stalls
            per_ms.append(step / dt)

    uniq = sorted(set(steps))
    print(f"distinct steps: {len(uniq)}  ->  {uniq[:12]}"
          f"{' ...' if len(uniq) > 12 else ''}")
    never_backward = all(s < FIELD_MOD // 2 for s in steps)
    zero_steps = steps.count(0)
    print(f"never runs backward (mod 2^{FIELD_BITS}): {never_backward}")
    if zero_steps:
        print(f"repeats within a container: {zero_steps}/{len(steps)} steps are 0 "
              f"-- consistent with one value stamped per container, not per frame")

    if steps:
        common = max(set(steps), key=steps.count)
        share = steps.count(common) / len(steps)
        print(f"most common step: {common} ({share:.0%} of steps)")

    print()
    # Rate between containers. Sub-frames inside one container share a host
    # arrival time, so only cross-container intervals carry real elapsed time.
    # Gaps beyond half the wrap period are excluded: the field wraps every
    # 14.75 s and the wrap count cannot be recovered from the value alone.
    WRAP_MS = FIELD_MOD * TICK_MS
    rates = [((c1 - c0) % FIELD_MOD) / (t1 - t0)
             for (t0, _, c0, _), (t1, _, c1, _) in zip(flat, flat[1:])
             if 0.05 < t1 - t0 < WRAP_MS / 2]
    if len(rates) >= 20:
        rates.sort()
        med = rates[len(rates) // 2]
        lo, hi = rates[len(rates) // 20], rates[-len(rates) // 20 - 1]
        print(f"counts per ms between containers: median {med:.3f}  "
              f"5-95% {lo:.3f}-{hi:.3f}")
        if lo > 0 and hi / lo < 1.10:
            print(f"  -> TIMESTAMP: {1/med:.4f} ms per count, holding to "
                  f"+/-{max(hi/med - 1, 1 - lo/med):.1%} — a crystal, not a counter")
        else:
            print("  -> not a steady clock; spread is too wide for a timestamp")

    intra = [(c1 - c0) % FIELD_MOD
             for (t0, _, c0, _), (t1, _, c1, _) in zip(flat, flat[1:])
             if t1 - t0 <= 0.05]
    if intra:
        common = max(set(intra), key=intra.count)
        print(f"step between sub-frames in one container: {common} counts "
              f"= {common * TICK_MS:.2f} ms ({intra.count(common)/len(intra):.0%} of them)")

    # Frame loss. A gap is only countable when the device-time step agrees
    # with the host-time wait: the field wraps every 14.75 s, and past one
    # wrap the elapsed device time is unrecoverable from the value alone.
    # Counting a wrapped interval as if it were a short one invents losses,
    # so those are reported as unmeasurable rather than guessed at.
    print()
    countable = ambiguous = missed = 0
    stalls = []
    for (t0, _, c0, _), (t1, _, c1, _) in zip(flat, flat[1:]):
        dt = t1 - t0
        if dt <= 0.05:
            continue
        raw = (c1 - c0) % FIELD_MOD
        predicted = dt / TICK_MS
        if predicted > FIELD_MOD * 0.9 or abs(raw - predicted) > 0.25 * predicted + 50:
            ambiguous += 1
            if dt > 200:
                stalls.append(dt)
            continue
        countable += 1
        n = round(raw / INTRA_CONTAINER_STEP) - 1
        if n > 0:
            missed += n

    print(f"frames stamped by the device but never delivered: {missed}"
          f"  (over {countable} measurable intervals)")
    if ambiguous:
        print(f"unmeasurable intervals: {ambiguous} — the wait exceeded what the "
              f"{FIELD_MOD * TICK_MS / 1000:.2f} s wrap can resolve")
    if stalls:
        stalls.sort(reverse=True)
        print(f"  of those, {len(stalls)} were stalls over 200 ms "
              f"(longest {stalls[0]:.0f} ms)")
        print("  Whether the device kept sampling through these cannot be read\n"
              "  from this field — the counter wrapped. Answering that needs a\n"
              "  wider timestamp or a host-side arrival log through the stall.")


if __name__ == "__main__":
    main()
