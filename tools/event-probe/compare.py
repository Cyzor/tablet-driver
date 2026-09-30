#!/usr/bin/env python3
"""compare.py — field-by-field comparison of two event-probe captures.

    compare.py mocktab.jsonl reference.jsonl            # every event type
    compare.py mocktab.jsonl reference.jsonl --type 22  # scroll events only
    compare.py capture.jsonl --split-source             # one file, by sender
    compare.py ours.jsonl ref.jsonl --from MockTab "pid 59923"   # one sender each

For each event type seen in either capture, lists the fields only one side
sends, and for shared fields, how their values differ. Fields that vary
per event (location, timestamps) are summarized, not listed.
"""

import json
import sys
from collections import defaultdict

TYPE_NAMES = {
    1: "leftMouseDown", 2: "leftMouseUp", 3: "rightMouseDown", 4: "rightMouseUp",
    5: "mouseMoved", 6: "leftMouseDragged", 7: "rightMouseDragged",
    10: "keyDown", 11: "keyUp", 12: "flagsChanged", 22: "scrollWheel",
    23: "tabletPointer", 24: "tabletProximity", 25: "otherMouseDown",
    26: "otherMouseUp", 27: "otherMouseDragged", 29: "gesture", 30: "magnify",
    31: "swipe", 18: "rotate", 19: "beginGesture", 20: "endGesture",
    32: "smartMagnify", 34: "pressure",
}

# Differ on every event by nature; presence matters, values don't.
NOISY = {"eventSourceUnixProcessID", "eventTargetUnixProcessID",
         "eventTargetProcessSerialNumber", "eventSourceStateID", "mouseEventNumber"}


def load(path):
    # Skips anything that isn't an event, such as notes pasted above a capture.
    with open(path) as f:
        return [json.loads(line) for line in f if line.lstrip().startswith("{")]


def by_type(events):
    groups = defaultdict(list)
    for e in events:
        groups[e["type"]].append(e)
    return groups


def summarize(values):
    distinct = sorted(set(values), key=lambda v: (isinstance(v, str), v))
    if len(distinct) <= 4:
        return ", ".join(fmt(v) for v in distinct)
    nums = [v for v in values if isinstance(v, (int, float))]
    return f"{len(distinct)} values, {fmt(min(nums))}…{fmt(max(nums))}"


def fmt(v):
    if isinstance(v, int) and abs(v) > 255:
        return hex(v)
    if isinstance(v, float):
        return f"{v:.4g}"
    return str(v)


def fields_of(events):
    table = defaultdict(list)
    for e in events:
        for k, v in e["fields"].items():
            table[k].append(v)
        table["(flags)"].append(e["flags"])
    return table


def compare(a_events, b_events, a_name, b_name, only_type=None):
    a, b = by_type(a_events), by_type(b_events)
    for t in sorted(set(a) | set(b)):
        if only_type is not None and t != only_type:
            continue
        name = TYPE_NAMES.get(t, f"type {t}")
        ea, eb = a.get(t, []), b.get(t, [])
        print(f"\n=== {name} ({t}): {a_name} {len(ea)} events, {b_name} {len(eb)} events")
        if not ea or not eb:
            print(f"    only in {a_name if ea else b_name}")
            continue
        fa, fb = fields_of(ea), fields_of(eb)
        for k in sorted(set(fa) | set(fb)):
            in_a, in_b = k in fa, k in fb
            if in_a and not in_b:
                print(f"  {a_name} only   {k:32} {summarize(fa[k])}  ({len(fa[k])}/{len(ea)})")
            elif in_b and not in_a:
                print(f"  {b_name} only   {k:32} {summarize(fb[k])}  ({len(fb[k])}/{len(eb)})")
            elif k not in NOISY:
                sa, sb = summarize(fa[k]), summarize(fb[k])
                if sa != sb:
                    print(f"  differs    {k:32} {a_name}: {sa}  |  {b_name}: {sb}")


def main():
    args = sys.argv[1:]
    only_type = None
    if "--type" in args:
        i = args.index("--type")
        only_type = int(args[i + 1])
        del args[i:i + 2]
    senders = None
    if "--from" in args:
        i = args.index("--from")
        senders = (args[i + 1], args[i + 2])
        del args[i:i + 3]
    if "--split-source" in args:
        args.remove("--split-source")
        events = load(args[0])
        sources = defaultdict(list)
        for e in events:
            sources[e["source"]].append(e)
        names = list(sources)
        if len(names) != 2:
            print(f"--split-source needs exactly two senders, found: {names}")
            return 1
        compare(sources[names[0]], sources[names[1]], names[0], names[1], only_type)
        return 0
    if len(args) != 2:
        print(__doc__.strip())
        return 2
    a, b = load(args[0]), load(args[1])
    if senders:
        a = [e for e in a if e["source"] == senders[0]]
        b = [e for e in b if e["source"] == senders[1]]
    compare(a, b, "A", "B", only_type)
    print("\nA =", args[0], "\nB =", args[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
