#!/usr/bin/env python3
"""latency_summary.py — summarize and compare driver_latency_probe.c logs.

Usage:
    python3 tools/latency/latency_summary.py <log-a> <log-b>
    python3 tools/latency/latency_summary.py <log-a> <log-b> --label-a vendor --label-b mocktab

Reads lines of the form:
    report->pointer-event latency: 12.34 ms
(as produced by tools/latency/latency_ab.sh / driver_latency_probe.c) and prints
count, p50, p90, and max for each log side by side.
"""

import re
import sys
import argparse

PATTERN = re.compile(r"latency:\s*([\d.]+)\s*ms")


def load(path):
    values = []
    with open(path) as f:
        for line in f:
            m = PATTERN.search(line)
            if m:
                values.append(float(m.group(1)))
    return values


def percentile(sorted_values, pct):
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * pct
    f = int(k)
    c = min(f + 1, len(sorted_values) - 1)
    if f == c:
        return sorted_values[f]
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)


def summarize(values, label):
    sv = sorted(values)
    return {
        "label": label,
        "n": len(sv),
        "p50": percentile(sv, 0.50),
        "p90": percentile(sv, 0.90),
        "max": sv[-1] if sv else float("nan"),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log_a")
    ap.add_argument("log_b")
    ap.add_argument("--label-a", default=None)
    ap.add_argument("--label-b", default=None)
    args = ap.parse_args()

    label_a = args.label_a or args.log_a.split("/")[-1]
    label_b = args.label_b or args.log_b.split("/")[-1]

    values_a = load(args.log_a)
    values_b = load(args.log_b)

    if not values_a:
        print(f"warning: no latency lines found in {args.log_a}", file=sys.stderr)
    if not values_b:
        print(f"warning: no latency lines found in {args.log_b}", file=sys.stderr)

    stats_a = summarize(values_a, label_a)
    stats_b = summarize(values_b, label_b)

    col_w = max(len(label_a), len(label_b), 10) + 2

    def row(name, key, fmt="{:.2f} ms"):
        va = fmt.format(stats_a[key]) if stats_a["n"] else "n/a"
        vb = fmt.format(stats_b[key]) if stats_b["n"] else "n/a"
        print(f"{name:<8}{va:>{col_w}}{vb:>{col_w}}")

    print(f"{'':<8}{label_a:>{col_w}}{label_b:>{col_w}}")
    print("-" * (8 + col_w * 2))
    row("samples", "n", "{:d}")
    row("p50", "p50")
    row("p90", "p90")
    row("max", "max")

    if stats_a["n"] and stats_b["n"]:
        print()
        delta = stats_b["p50"] - stats_a["p50"]
        faster = label_b if delta < 0 else label_a
        print(f"At p50, {faster} is {abs(delta):.2f} ms faster.")
        print("Reminder: this measures decode+injection latency only — not")
        print("USB/BT polling interval or anything past event injection.")


if __name__ == "__main__":
    main()
