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
    python3 tools/audit_registry.py            # full audit
    python3 tools/audit_registry.py --family X # filter by name substring
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "MockTab" / "Driver" / "WacomDeviceRegistry.swift"
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


def diff(reg: dict, ker: dict, family_filter: str | None) -> int:
    common = sorted(set(reg) & set(ker))
    mismatches = 0
    for pid in common:
        r = reg[pid]
        k = ker[pid]
        if family_filter and family_filter.lower() not in r["name"].lower():
            continue
        # Strict numeric diff; name diff is "fuzzy" (kernel often uses
        # marketing-free names like "Wacom ISDv5 307" — flag but not fail).
        deltas = []
        for field in ("maxX", "maxY", "maxPressure", "buttonCount"):
            if r[field] != k[field]:
                deltas.append(f"{field}: {r[field]} -> {k[field]}")
        # Name mismatch reported separately so callers can choose to fix
        # those as well; not all kernel names are user-friendly.
        name_delta = r["name"] != k["name"]
        if deltas or name_delta:
            mismatches += 1
            print(f"0x{pid:04X}  registry: {r['name']!r}")
            print(f"        kernel:   {k['name']!r}")
            for d in deltas:
                print(f"          {d}")
            print()
    return mismatches


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", help="filter by name substring")
    args = ap.parse_args()
    reg = parse_registry()
    ker = parse_kernel()
    print(f"Registry entries parsed: {len(reg)}", file=sys.stderr)
    print(f"Kernel entries parsed:   {len(ker)}", file=sys.stderr)
    print(f"Overlap:                 {len(set(reg) & set(ker))}", file=sys.stderr)
    n = diff(reg, ker, args.family)
    print(f"\n{n} entries with discrepancies", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
