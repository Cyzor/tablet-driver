#!/usr/bin/env python3
"""audit_registry.py — diff WacomDeviceRegistry against kernel wacom_features.

Reads:
  • MockTab/Driver/WacomDeviceRegistry.swift — our authoritative table
  • Notes/Scratch/upstream/input-wacom/<branch>/wacom_wac.c — kernel features

For each PID present in both, compares name, maxX, maxY, maxPressure, and
button count. Emits a per-PID line for any mismatch. Pen-display flag and
parser family are NOT checked — those need protocol-level judgement and
are out of scope for this rote-comparison tool.

Usage:
    python3 tools/audit_registry.py                  # full audit
    python3 tools/audit_registry.py --family X       # filter by name substring
    python3 tools/audit_registry.py --only numeric   # show only maxX/Y/Pressure drift
    python3 tools/audit_registry.py --only name      # show only name-string differences
    python3 tools/audit_registry.py --only buttons   # show only buttonCount differences
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "TabletKit" / "Sources" / "TabletKit" / "WacomDeviceRegistry.swift"
KERNEL = (
    ROOT / "Notes" / "Scratch" / "upstream" / "input-wacom"
    / "4.18" / "wacom_wac.c"
)


def parse_registry() -> dict[int, dict]:
    """Return {pid: {name, maxX, maxY, maxPressure, buttonCount}}."""
    text = REGISTRY.read_text()
    rows: dict[int, dict] = {}
    # Match the .init(...) blocks. Loose; relies on canonical formatting.
    pat = re.compile(
        r"productID:\s*0x([0-9A-Fa-f]+),\s*name:\s*\"([^\"]+)\"[^)]*?"
        r"maxX:\s*(\d+),\s*maxY:\s*(\d+),\s*maxPressure:\s*(\d+),\s*"
        r"buttonCount:\s*(\d+)",
        re.S,
    )
    for m in pat.finditer(text):
        pid = int(m.group(1), 16)
        rows[pid] = {
            "name": m.group(2),
            "maxX": int(m.group(3)),
            "maxY": int(m.group(4)),
            "maxPressure": int(m.group(5)),
            "buttonCount": int(m.group(6)),
        }
    return rows


def parse_kernel() -> dict[int, dict]:
    """Return {pid: {name, maxX, maxY, maxPressure, numbered_buttons}}."""
    text = KERNEL.read_text()
    rows: dict[int, dict] = {}
    # Block form:
    #   static const struct wacom_features wacom_features_0xHEX =
    #     { "Name", MAXX, MAXY, MAXPRESS, MAXDIST,
    #       TYPE, RESX, RESY, NUMBUTTONS, ... };
    # Some entries are touch-only and won't match this pattern (no dims).
    pat = re.compile(
        r"wacom_features_0x([0-9A-Fa-f]+)\s*=\s*"
        r"\{\s*\"([^\"]+)\"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*\d+\s*,\s*"
        r"[A-Z_0-9]+\s*,\s*[A-Z_0-9]+\s*,\s*[A-Z_0-9]+\s*(?:,\s*(\d+))?",
        re.S,
    )
    for m in pat.finditer(text):
        pid = int(m.group(1), 16)
        rows[pid] = {
            "name": m.group(2),
            "maxX": int(m.group(3)),
            "maxY": int(m.group(4)),
            "maxPressure": int(m.group(5)),
            "buttonCount": int(m.group(6)) if m.group(6) else 0,
        }
    return rows


NUMERIC_FIELDS = ("maxX", "maxY", "maxPressure")


def diff(reg: dict, ker: dict, family_filter: str | None,
         only: str | None) -> int:
    common = sorted(set(reg) & set(ker))
    printed = 0
    numeric_count = 0
    button_count = 0
    name_only_count = 0
    for pid in common:
        r = reg[pid]
        k = ker[pid]
        if family_filter and family_filter.lower() not in r["name"].lower():
            continue
        numeric_deltas = [
            f"{f}: {r[f]} -> {k[f]}"
            for f in NUMERIC_FIELDS if r[f] != k[f]
        ]
        button_delta = (
            f"buttonCount: {r['buttonCount']} -> {k['buttonCount']}"
            if r["buttonCount"] != k["buttonCount"] else None
        )
        # Name mismatch reported separately; not all kernel names are
        # user-friendly ("Wacom ISDv5 307" etc.).
        name_delta = r["name"] != k["name"]

        # Bucket classification (priority: numeric > buttons > name).
        if numeric_deltas:
            numeric_count += 1
        elif button_delta:
            button_count += 1
        elif name_delta:
            name_only_count += 1
        else:
            continue

        # Apply --only filter for display.
        if only == "numeric" and not numeric_deltas:
            continue
        if only == "buttons" and not button_delta:
            continue
        if only == "name" and (numeric_deltas or button_delta or not name_delta):
            continue

        printed += 1
        print(f"0x{pid:04X}  registry: {r['name']!r}")
        print(f"        kernel:   {k['name']!r}")
        for d in numeric_deltas:
            print(f"          {d}")
        if button_delta:
            print(f"          {button_delta}")
        print()

    total = numeric_count + button_count + name_only_count
    print(
        f"\n{total} entries with discrepancies"
        f"  (numeric: {numeric_count}, buttons-only: {button_count}, "
        f"name-only: {name_only_count})",
        file=sys.stderr,
    )
    if only:
        print(f"shown ({only}): {printed}", file=sys.stderr)
    return total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", help="filter by name substring")
    ap.add_argument(
        "--only", choices=("numeric", "name", "buttons"),
        help="restrict output to one bucket (summary still totals all)",
    )
    args = ap.parse_args()
    reg = parse_registry()
    ker = parse_kernel()
    print(f"Registry entries parsed: {len(reg)}", file=sys.stderr)
    print(f"Kernel entries parsed:   {len(ker)}", file=sys.stderr)
    print(f"Overlap:                 {len(set(reg) & set(ker))}", file=sys.stderr)
    diff(reg, ker, args.family, args.only)
    return 0


if __name__ == "__main__":
    sys.exit(main())
