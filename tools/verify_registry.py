#!/usr/bin/env python3
"""verify_registry.py — Cross-reference WacomDeviceRegistry against canonical sources.

Compares every entry in MockTab/Driver/WacomDeviceRegistry.swift against:
  • Linux input-wacom feature structs (kernel canonical)
  • OpenTabletDriver JSON configs (community canonical)

Emits a CSV with one row per registry PID, columns:
  pid, registry_name, registry_parser, registry_maxX/maxY/maxP,
  kernel_maxX/maxY/maxP/type, otd_maxX/maxY/maxP/parser,
  verdict, notes

Verdicts:
  agree            — kernel and registry match (dims within tolerance)
  cross_referenced — kernel and OTD agree with each other and with registry
  kernel_disagrees — kernel has different dims; per project convention kernel wins
  otd_disagrees    — OTD has different dims; less authoritative than kernel
  kernel_only      — kernel has it, OTD doesn't
  otd_only         — OTD has it, kernel doesn't (newer hardware, typically)
  unknown          — neither source has the PID
  registry_only    — see "unknown"

Usage:
    python3 tools/verify_registry.py \\
        --registry  MockTab/Driver/WacomDeviceRegistry.swift \\
        --kernel    /path/to/input-wacom/4.18/wacom_wac.c \\
        --otd       /path/to/OpenTabletDriver/Configurations/Wacom \\
        --out       registry_audit.csv
"""

import argparse
import base64
import csv
import glob
import json
import os
import re
import sys
from typing import Optional

DIM_TOLERANCE = 0  # exact match required for now; bump to 50 if rounding noise appears

# ── Kernel parsing ────────────────────────────────────────────────────────────

KERNEL_FEATURE_RE = re.compile(
    r'static const struct wacom_features wacom_features_0x([0-9A-Fa-f]+)\s*=\s*'
    r'\{\s*"([^"]*)"\s*,\s*'
    r'(\d+)\s*,\s*(\d+)\s*,\s*(\d+)',
    re.MULTILINE,
)

KERNEL_TYPE_RE = re.compile(
    r'wacom_features_0x([0-9A-Fa-f]+)\s*=\s*\{[^}]*?,\s*'
    r'(INTUOS[A-Z0-9_]*|GRAPHIRE[A-Z0-9_]*|BAMBOO[A-Z0-9_]*|WACOM_[A-Z0-9_]+|CINTIQ[A-Z0-9_]*|PL[A-Z0-9_]*|DTU[A-Z0-9_]*|PTU|TABLETPC[A-Z0-9_]*|MTSCREEN|MTTPC[A-Z0-9_]*|HID_GENERIC|G9|G14|GD|MO|TPC|REMOTE)',
    re.DOTALL,
)


def parse_kernel(path: str) -> dict:
    """Return {pid_int: {"name", "maxX", "maxY", "maxP", "type"}}."""
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8", errors="ignore").read()
    out = {}
    for m in KERNEL_FEATURE_RE.finditer(text):
        pid = int(m.group(1), 16)
        out[pid] = {
            "name": m.group(2),
            "maxX": int(m.group(3)),
            "maxY": int(m.group(4)),
            "maxP": int(m.group(5)),
            "type": "",
        }
    for m in KERNEL_TYPE_RE.finditer(text):
        pid = int(m.group(1), 16)
        if pid in out:
            out[pid]["type"] = m.group(2)
    return out


# ── OTD parsing ───────────────────────────────────────────────────────────────

WACOM_VID = 1386  # 0x056A


def parse_pid(raw):
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str):
        try:
            return int(raw.strip(), 0)
        except ValueError:
            return None
    return None


def parse_otd(directory: str) -> dict:
    """Return {pid_int: {"name", "maxX", "maxY", "maxP", "parser"}}."""
    if not os.path.isdir(directory):
        return {}
    out = {}
    for fp in glob.glob(os.path.join(directory, "*.json")):
        try:
            cfg = json.load(open(fp, encoding="utf-8"))
        except Exception:
            continue
        name = cfg.get("Name", os.path.splitext(os.path.basename(fp))[0])
        specs = cfg.get("Specifications", {}) or {}
        dig = specs.get("Digitizer", {}) or {}
        pen = specs.get("Pen", {}) or {}
        max_x = int(cfg.get("MaxX") or dig.get("MaxX") or 0)
        max_y = int(cfg.get("MaxY") or dig.get("MaxY") or 0)
        max_p = int(cfg.get("MaxPressure") or pen.get("MaxPressure") or 0)

        # Current schema: DigitizerIdentifiers[]
        for di in cfg.get("DigitizerIdentifiers", []) or []:
            if not isinstance(di, dict):
                continue
            if int(di.get("VendorID", 0)) != WACOM_VID:
                continue
            pid = parse_pid(di.get("ProductID"))
            if not pid:
                continue
            parser = di.get("ReportParser", "").split(".")[-1].split(",")[0]
            out[pid] = {
                "name": name, "maxX": max_x, "maxY": max_y,
                "maxP": max_p, "parser": parser,
            }

        # Legacy schema: top-level VID/PID
        if int(cfg.get("VendorID", 0)) == WACOM_VID:
            pid = parse_pid(cfg.get("ProductID"))
            if pid and pid not in out:
                parser = cfg.get("ReportParser", "").split(".")[-1].split(",")[0]
                out[pid] = {
                    "name": name, "maxX": max_x, "maxY": max_y,
                    "maxP": max_p, "parser": parser,
                }
    return out


# ── Registry parsing ──────────────────────────────────────────────────────────

REGISTRY_RE = re.compile(
    r'\.init\(\s*\n\s*productID:\s*(0x[0-9A-Fa-f]+|\d+),\s*name:\s*"([^"]+)"[^\n]*\n'
    r'\s*parser:\s*\.([A-Za-z0-9]+),\s*maxX:\s*(\d+),\s*maxY:\s*(\d+),\s*maxPressure:\s*(\d+)',
    re.MULTILINE,
)

CONFIDENCE_RE = re.compile(r'confidence:\s*\.([A-Za-z]+)')


def parse_registry(path: str) -> list:
    text = open(path, encoding="utf-8", errors="ignore").read()
    rows = []
    for m in REGISTRY_RE.finditer(text):
        pid_str = m.group(1)
        pid = int(pid_str, 0)
        # Look ahead a few lines for confidence override.
        end = m.end()
        tail = text[end:end + 600]
        conf_match = CONFIDENCE_RE.search(tail)
        confidence = conf_match.group(1) if conf_match else "experimental"
        rows.append({
            "pid": pid,
            "name": m.group(2),
            "parser": m.group(3),
            "maxX": int(m.group(4)),
            "maxY": int(m.group(5)),
            "maxP": int(m.group(6)),
            "confidence": confidence,
        })
    return rows


# ── Kernel type → MockTab parser family ──────────────────────────────────────

KERNEL_TYPE_TO_PARSER = {
    "PENPARTNER": "graphire", "GRAPHIRE": "graphire", "GRAPHIRE_BT": "graphire",
    "G4": "graphire", "PTU": "graphire",
    "BAMBOO_PT": "bamboo", "BAMBOO_PEN": "bamboo", "BAMBOO_TOUCH": "bamboo",
    "INTUOS": "intuosV1", "INTUOSL": "intuosV1", "INTUOSS": "intuosV1",
    "INTUOSPL": "intuosV1", "INTUOSPM": "intuosV1", "INTUOSPS": "intuosV1",
    "INTUOSHT": "intuosV1", "INTUOSHT2": "intuosV1", "INTUOSHT3_BT": "intuosV1",
    "INTUOS3": "intuos3", "INTUOS3S": "intuos3", "INTUOS3L": "intuos3",
    "INTUOS4": "intuosV1", "INTUOS4S": "intuosV1", "INTUOS4L": "intuosV1",
    "INTUOS4WL": "intuosV1", "INTUOS5": "intuosV1", "INTUOS5S": "intuosV1",
    "INTUOS5L": "intuosV1",
    "INTUOSP2_BT": "intuosV2", "INTUOSP2S_BT": "intuosV2",
    "WACOM_24HD": "cintiqV1", "WACOM_24HDT": "cintiqV1",
    "WACOM_22HD": "cintiqV1", "WACOM_21UX2": "cintiqV1",
    "WACOM_BEE": "cintiqV1", "CINTIQ": "cintiqV1", "CINTIQ_COMPANION_2": "cintiqV1",
    "DTUS": "graphire", "DTUSX": "graphire", "DTU": "graphire",
}


def map_kernel_parser(t: str) -> Optional[str]:
    if not t:
        return None
    if t in KERNEL_TYPE_TO_PARSER:
        return KERNEL_TYPE_TO_PARSER[t]
    return None


# OTD class-name suffix → parser (mirrors import_otd_configs.py)
OTD_TYPE_TO_PARSER = {
    "IntuosReportParser": "intuosV1",
    "IntuosV1ReportParser": "intuosV1",
    "WacomDriverIntuosReportParser": "intuosV1",
    "WacomDriverIntuosV1ReportParser": "intuosV1",
    "Intuos3ReportParser": "intuos3",
    "WacomDriverIntuos3ReportParser": "intuos3",
    "Intuos3ExtraAuxReportParser": "intuos3",
    "CintiqV1ReportParser": "cintiqV1",
    "IntuosV2ReportParser": "intuosV2",
    "WacomDriverIntuosV2ReportParser": "intuosV2",
    "IntuosV3ReportParser": "intuosV2",
    "BambooReportParser": "bamboo",
    "BambooPadReportParser": "bamboo",
    "GraphireReportParser": "graphire",
    "WacomDriverlessTablet": "graphire",
    "WacomDriverless": "graphire",
}


def map_otd_parser(name: str) -> Optional[str]:
    if not name:
        return None
    if name in OTD_TYPE_TO_PARSER:
        return OTD_TYPE_TO_PARSER[name]
    return None


# ── Verdict computation ──────────────────────────────────────────────────────

def dims_agree(a, b) -> bool:
    if a is None or b is None:
        return False
    return (
        abs(a["maxX"] - b["maxX"]) <= DIM_TOLERANCE
        and abs(a["maxY"] - b["maxY"]) <= DIM_TOLERANCE
        and a["maxP"] == b["maxP"]
    )


def compute_verdict(reg, kern, otd) -> tuple[str, str]:
    """Return (verdict, notes)."""
    if not kern and not otd:
        return ("unknown", "neither kernel nor OTD has this PID")

    if kern and otd:
        if dims_agree(reg, kern) and dims_agree(reg, otd):
            # Two independent canonical sources concur; flag for promotion.
            return ("cross_referenced", "kernel + OTD both agree with registry")
        if dims_agree(reg, kern):
            return ("otd_disagrees", _diff_notes(reg, otd, "OTD"))
        if dims_agree(reg, otd):
            return ("kernel_disagrees", _diff_notes(reg, kern, "kernel"))
        return ("kernel_disagrees", "registry differs from BOTH kernel AND OTD: " + _diff_notes(reg, kern, "kernel"))

    if kern:
        if dims_agree(reg, kern):
            return ("agree", "kernel agrees; OTD has no entry")
        return ("kernel_disagrees", _diff_notes(reg, kern, "kernel"))

    # otd only
    if dims_agree(reg, otd):
        return ("otd_only", "OTD agrees; kernel has no entry")
    return ("otd_disagrees", _diff_notes(reg, otd, "OTD") + "; kernel has no entry")


def _diff_notes(reg, src, label):
    parts = []
    if reg["maxX"] != src["maxX"]:
        parts.append(f"{label} maxX={src['maxX']} (registry {reg['maxX']})")
    if reg["maxY"] != src["maxY"]:
        parts.append(f"{label} maxY={src['maxY']} (registry {reg['maxY']})")
    if reg["maxP"] != src["maxP"]:
        parts.append(f"{label} maxP={src['maxP']} (registry {reg['maxP']})")
    return "; ".join(parts) if parts else f"{label} agrees on dims"


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--registry", required=True, help="path to WacomDeviceRegistry.swift")
    p.add_argument("--kernel", required=True, help="path to input-wacom wacom_wac.c")
    p.add_argument("--otd", required=True, help="path to OTD Configurations/Wacom directory")
    p.add_argument("--out", default="registry_audit.csv", help="output CSV path")
    args = p.parse_args()

    registry = parse_registry(args.registry)
    kernel = parse_kernel(args.kernel)
    otd = parse_otd(args.otd)

    print(f"Loaded {len(registry)} registry entries, "
          f"{len(kernel)} kernel features, "
          f"{len(otd)} OTD entries.", file=sys.stderr)

    rows = []
    counts = {}
    for reg in registry:
        pid = reg["pid"]
        kern = kernel.get(pid)
        otd_e = otd.get(pid)
        verdict, notes = compute_verdict(reg, kern, otd_e)
        counts[verdict] = counts.get(verdict, 0) + 1

        # parser comparison
        parser_match = []
        if kern and kern.get("type"):
            kp = map_kernel_parser(kern["type"])
            if kp and kp != reg["parser"]:
                parser_match.append(f"kernel parser={kp} (kernel type {kern['type']})")
        if otd_e:
            op = map_otd_parser(otd_e.get("parser", ""))
            if op and op != reg["parser"]:
                parser_match.append(f"OTD parser={op} (OTD class {otd_e['parser']})")
        if parser_match:
            notes = (notes + "; " if notes else "") + "; ".join(parser_match)

        rows.append({
            "pid": f"0x{pid:04X}",
            "registry_name": reg["name"],
            "registry_parser": reg["parser"],
            "registry_maxX": reg["maxX"], "registry_maxY": reg["maxY"], "registry_maxP": reg["maxP"],
            "registry_confidence": reg["confidence"],
            "kernel_name": kern["name"] if kern else "",
            "kernel_maxX": kern["maxX"] if kern else "",
            "kernel_maxY": kern["maxY"] if kern else "",
            "kernel_maxP": kern["maxP"] if kern else "",
            "kernel_type": kern["type"] if kern else "",
            "otd_name": otd_e["name"] if otd_e else "",
            "otd_maxX": otd_e["maxX"] if otd_e else "",
            "otd_maxY": otd_e["maxY"] if otd_e else "",
            "otd_maxP": otd_e["maxP"] if otd_e else "",
            "otd_parser": otd_e["parser"] if otd_e else "",
            "verdict": verdict,
            "notes": notes,
        })

    # PIDs in kernel/OTD that registry doesn't have
    reg_pids = {r["pid"] for r in registry}
    for pid in sorted((set(kernel) | set(otd)) - reg_pids):
        kern = kernel.get(pid)
        otd_e = otd.get(pid)
        rows.append({
            "pid": f"0x{pid:04X}",
            "registry_name": "<missing>",
            "registry_parser": "",
            "registry_maxX": "", "registry_maxY": "", "registry_maxP": "",
            "registry_confidence": "",
            "kernel_name": kern["name"] if kern else "",
            "kernel_maxX": kern["maxX"] if kern else "",
            "kernel_maxY": kern["maxY"] if kern else "",
            "kernel_maxP": kern["maxP"] if kern else "",
            "kernel_type": kern["type"] if kern else "",
            "otd_name": otd_e["name"] if otd_e else "",
            "otd_maxX": otd_e["maxX"] if otd_e else "",
            "otd_maxY": otd_e["maxY"] if otd_e else "",
            "otd_maxP": otd_e["maxP"] if otd_e else "",
            "otd_parser": otd_e["parser"] if otd_e else "",
            "verdict": "missing_from_registry",
            "notes": "kernel and/or OTD know this PID; registry does not",
        })
        counts["missing_from_registry"] = counts.get("missing_from_registry", 0) + 1

    fieldnames = list(rows[0].keys()) if rows else []
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)

    print(f"\nWrote {args.out} with {len(rows)} rows.\n", file=sys.stderr)
    print("Verdict summary:", file=sys.stderr)
    for v in sorted(counts.keys()):
        print(f"  {v:24s} {counts[v]}", file=sys.stderr)


if __name__ == "__main__":
    main()
