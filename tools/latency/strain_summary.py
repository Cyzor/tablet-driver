#!/usr/bin/env python3
"""strain_summary.py — summarize strain-bench.sh logs against baseline.txt.

Usage:
    python3 tools/latency/strain_summary.py <log-dir> [--context TEXT] [--update]

Reads <condition>.log files written by driver_latency_probe.c. Prefers the
probe's exact pairs; falls back to next-event pairing when the driver doesn't
stamp report times. Warns when p95 or p99 grew past the baseline by more than
both limits below. Never fails.
"""

import argparse
import os
import re

from latency_summary import percentile

CONDITIONS = ["idle", "cpu", "gpu", "memory", "quickkeys"]
BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "baseline.txt")
# Two idle runs on 2026-10-09 differed by 42% and 1.1 ms at p95, so smaller
# changes are noise.
LIMIT_PERCENT = 50
LIMIT_MS = 1.0

EXACT = re.compile(r"exact:\s*([\d.]+)\s*ms")
NEXT = re.compile(r"latency:\s*([\d.]+)\s*ms")


def load(path):
    exact, following = [], []
    with open(path) as f:
        for line in f:
            if m := EXACT.search(line):
                exact.append(float(m.group(1)))
            if m := NEXT.search(line):
                following.append(float(m.group(1)))
    if exact and len(exact) >= len(following) / 2:
        return exact, "exact"
    return following, "next"


def stats(values):
    sv = sorted(values)
    return {
        "n": len(sv),
        "p50": percentile(sv, 0.50),
        "p95": percentile(sv, 0.95),
        "p99": percentile(sv, 0.99),
        "max": sv[-1] if sv else float("nan"),
    }


def read_baseline():
    rows = {}
    if not os.path.exists(BASELINE):
        return rows
    with open(BASELINE) as f:
        for line in f:
            parts = line.split()
            if not parts or parts[0].startswith("#"):
                continue
            rows[parts[0]] = {k: float(v) for k, v in zip(parts[1::2], parts[2::2])}
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log_dir")
    ap.add_argument("--context", default="")
    ap.add_argument("--update", action="store_true")
    args = ap.parse_args()

    results = {}
    for cond in CONDITIONS:
        path = os.path.join(args.log_dir, f"{cond}.log")
        if os.path.exists(path):
            values, method = load(path)
            if values:
                results[cond] = (stats(values), method)

    if not results:
        print("strain-bench: no measurements; check the probe's heartbeat lines")
        return

    baseline = read_baseline()
    print(f"{'condition':<10} {'pairing':<7} {'n':>6} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>7}   baseline p95 / p99")
    warnings = []
    for cond, (s, method) in results.items():
        was = baseline.get(cond)
        base = f"{was['p95']:.2f} / {was['p99']:.2f}" if was else "none"
        print(f"{cond:<10} {method:<7} {s['n']:>6} {s['p50']:>7.2f} {s['p95']:>7.2f} {s['p99']:>7.2f} {s['max']:>7.2f}   {base}")
        if was:
            for key in ("p95", "p99"):
                grew = s[key] - was[key]
                if grew > LIMIT_MS and grew > was[key] * LIMIT_PERCENT / 100:
                    warnings.append(f"{cond} {key} {was[key]:.2f} → {s[key]:.2f} ms")
    print("All values in ms.")

    if args.update:
        with open(BASELINE, "w") as f:
            f.write("# strain-bench baseline; record a new one with --update.\n")
            if args.context:
                f.write(f"# {args.context}\n")
            for cond, (s, _) in results.items():
                f.write(f"{cond} n {s['n']} p50 {s['p50']:.2f} p95 {s['p95']:.2f} p99 {s['p99']:.2f} max {s['max']:.2f}\n")
        print(f"strain-bench: baseline updated ({BASELINE})")
        return

    if not baseline:
        print("strain-bench: no baseline; run again with --update to record one")
    for w in warnings:
        print(f"strain-bench: WARNING {w}")
    if warnings:
        print(f"strain-bench: flagged when a percentile grows more than {LIMIT_PERCENT}% and {LIMIT_MS} ms")


if __name__ == "__main__":
    main()
