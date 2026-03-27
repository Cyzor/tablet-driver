#!/usr/bin/env python3
"""import_otd_configs.py — OTD → WacomDeviceSpec importer

Parses OpenTabletDriver Configurations/Wacom/*.json files and emits Swift
.init(...) entries for WacomDeviceRegistry.knownDevices.

Usage:
    python3 tools/import_otd_configs.py /path/to/OpenTabletDriver/Configurations/Wacom
    python3 tools/import_otd_configs.py /path/to/OTD/Configurations/Wacom --all

Options:
    --all     Include PIDs already present in WacomDeviceRegistry (default: skip them)

Output goes to stdout.  Redirect to a file and paste into WacomDeviceRegistry.swift.
"""

import argparse
import base64
import glob
import json
import os
import sys
from pathlib import Path
from typing import Optional

# ── PIDs already in WacomDeviceRegistry.knownDevices ──────────────────────────
# Skip these by default to avoid duplicating confirmed/hand-tuned entries.
EXISTING_PIDS = {
    # Graphire / PenPartner / Volito
    0x0003, 0x0004, 0x0010, 0x0011, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017,
    0x003F, 0x0060, 0x0061, 0x0062, 0x0065,
    # Intuos 1–2
    0x0020, 0x0021, 0x0022, 0x0023, 0x0024,
    0x0041, 0x0042, 0x0043, 0x0044, 0x0045,
    # Intuos3 (PTZ)
    0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B7,
    # Intuos4 (PTK)
    0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC,
    # Intuos5 (PTH-x50)
    0x0026, 0x0027, 0x0028,
    # Intuos Pro first-gen (PTH-x51)
    0x0314, 0x0316, 0x0317,
    # Intuos Pro second-gen (PTH-x60/x80)
    0x0352, 0x0357, 0x0358,
    # Bamboo / CTL / CTH
    0x00D0, 0x00D1, 0x00D4, 0x00D6, 0x00D7, 0x00DA, 0x00DB,
    # Cintiq pen-displays
    0x00C0, 0x00C4, 0x00C6, 0x00CC, 0x00F4, 0x00F8, 0x00FA, 0x00FB,
    # Wireless dongle
    0x0084,
}

# ── ReportParser class-name → MockTab parser family ───────────────────────────
# Matched against: top-level "ReportParser" string, or $type suffix in Attributes.
TYPE_TO_PARSER = {
    "WacomDriverlessTablet": "graphire",
    "WacomDriverless":       "graphire",
    "Graphire":              "graphire",
    "IntuosV1":              "intuosV1",
    "Intuos4V2":             "intuosV1",  # Intuos4 uses same 10-byte format
    "WacomV1":               "intuosV1",
    "IntuosV2":              "intuosV2",
    "WacomV2":               "intuosV2",
    "Bamboo":                "bamboo",
    "BambooV2":              "bamboo",
}

WACOM_VENDOR_ID = 1386  # 0x056A


def parse_product_id(raw) -> Optional[int]:
    """Accept int, decimal string, or '0xNNNN' hex string."""
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str):
        raw = raw.strip()
        try:
            return int(raw, 0)  # handles "0x0357" or "871"
        except ValueError:
            return None
    return None


def extract_parser(cfg: dict) -> Optional[str]:
    """
    Determine the ReportParser family.

    Priority order:
      1. Top-level "ReportParser" string (older OTD format)
      2. Last $type component in Attributes[0] (newer OTD format)
      3. InputReportLength heuristic (>64 → intuosV2, else → intuosV1)
    """
    # 1. Top-level "ReportParser"
    rp = cfg.get("ReportParser", "")
    if rp:
        # Strip namespace prefix (e.g. "OpenTabletDriver.Parsers.IntuosV2" → "IntuosV2")
        rp_short = rp.split(".")[-1]
        if rp_short in TYPE_TO_PARSER:
            return TYPE_TO_PARSER[rp_short]
        # Partial-match fallback
        for key, val in TYPE_TO_PARSER.items():
            if key.lower() in rp.lower():
                return val

    # 2. Attributes[0].$type
    attrs = cfg.get("Attributes", [])
    if attrs and isinstance(attrs, list) and isinstance(attrs[0], dict):
        t = attrs[0].get("$type", "")
        t_short = t.split(".")[-1].split(",")[0]  # strip assembly suffix
        if t_short in TYPE_TO_PARSER:
            return TYPE_TO_PARSER[t_short]
        for key, val in TYPE_TO_PARSER.items():
            if key.lower() in t.lower():
                return val

    # 3. InputReportLength heuristic
    irl = cfg.get("InputReportLength", 0)
    if irl > 64:
        return "intuosV2"
    if irl > 0:
        return "intuosV1"

    return None  # unknown — will be skipped


def extract_dimensions(cfg: dict) -> tuple[int, int, int]:
    """Return (maxX, maxY, maxPressure)."""
    # Newer OTD format: Specifications sub-objects
    specs = cfg.get("Specifications", {}) or {}
    dig   = specs.get("Digitizer", {}) or {}
    pen   = specs.get("Pen", {}) or {}

    max_x = (cfg.get("MaxX")
              or dig.get("MaxX")
              or 0)
    max_y = (cfg.get("MaxY")
              or dig.get("MaxY")
              or 0)
    max_p = (cfg.get("MaxPressure")
              or pen.get("MaxPressure")
              or 0)

    return int(max_x), int(max_y), int(max_p)


def extract_button_count(cfg: dict) -> int:
    """Express/side key count (not pen side buttons)."""
    # Newer OTD: Specifications.AuxiliaryButtons.ButtonCount
    specs = cfg.get("Specifications", {}) or {}
    aux   = specs.get("AuxiliaryButtons", {}) or {}
    bc    = (cfg.get("ButtonCount")
             or aux.get("ButtonCount")
             or 0)
    return int(bc)


def extract_has_touch_ring(cfg: dict) -> bool:
    """True if the device has a capacitive touch ring or touch strip."""
    # Newer OTD: Specifications.TouchRing or Specifications.TouchStrip
    specs = cfg.get("Specifications", {}) or {}
    if specs.get("TouchRing") or specs.get("TouchStrip"):
        return True
    # Older OTD: top-level boolean
    return bool(cfg.get("HasTouchRing", False))


def extract_has_eraser(cfg: dict) -> bool:
    """True if the pen family includes an eraser tool."""
    specs = cfg.get("Specifications", {}) or {}
    pen   = specs.get("Pen", {}) or {}
    eraser = pen.get("HasEraser")
    if eraser is not None:
        return bool(eraser)
    return bool(cfg.get("HasEraser", True))  # default True for pen tablets


def extract_feature_init(cfg: dict) -> Optional[list[int]]:
    """
    Decode FeatureInitializationReport (base64 string) → byte list.
    Returns nil-equivalent (None) if absent or empty.
    """
    raw = cfg.get("FeatureInitializationReport")
    if not raw:
        return None
    try:
        decoded = base64.b64decode(raw)
        if decoded:
            return list(decoded)
    except Exception:
        pass
    return None


def extract_seize_usb(cfg: dict) -> bool:
    """
    True when this device needs kIOHIDOptionsTypeSeizeDevice.

    OTD signals this via an Interface attribute with Interface == 0
    (the standard HID mouse/keyboard interface) on multi-interface devices.
    """
    # Check explicit top-level flag (some OTD forks add this)
    if cfg.get("SeizeUSB") or cfg.get("RequiresSeize"):
        return True

    # Scan Attributes for an Interface specifier
    for attr in cfg.get("Attributes", []):
        if not isinstance(attr, dict):
            continue
        iface = attr.get("Interface")
        if iface == 0:
            return True
        # Some configs use a string-typed "Interface": "0x0001" style
        if isinstance(iface, str):
            try:
                if int(iface, 0) == 0:
                    return True
            except ValueError:
                pass

    return False


def swift_bytes_literal(byte_list: list[int]) -> str:
    """Format [0x02, 0x02] style literal."""
    return "[" + ", ".join(f"0x{b:02X}" for b in byte_list) + "]"


def swift_bool(b: bool) -> str:
    return "true" if b else "false"


def process_config(path: str, include_existing: bool) -> Optional[str]:
    """
    Parse one OTD JSON config and return a Swift .init(...) string, or None
    if the entry should be skipped (wrong vendor, bad data, already exists).
    """
    with open(path, encoding="utf-8") as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError as e:
            print(f"# WARNING: {os.path.basename(path)}: JSON parse error: {e}",
                  file=sys.stderr)
            return None

    # ── Vendor filter ──────────────────────────────────────────────────────
    vendor_id = cfg.get("VendorID", 0)
    if int(vendor_id) != WACOM_VENDOR_ID:
        return None

    # ── Product ID ─────────────────────────────────────────────────────────
    pid = parse_product_id(cfg.get("ProductID"))
    if pid is None:
        print(f"# WARNING: {os.path.basename(path)}: missing or unparseable ProductID",
              file=sys.stderr)
        return None

    if not include_existing and pid in EXISTING_PIDS:
        return None  # silently skip known PIDs

    # ── Required fields ────────────────────────────────────────────────────
    name = cfg.get("Name", "").strip()
    if not name:
        print(f"# WARNING: 0x{pid:04X}: missing Name, skipping", file=sys.stderr)
        return None

    parser = extract_parser(cfg)
    if parser is None:
        print(f"# WARNING: 0x{pid:04X} ({name}): cannot determine parser family, skipping",
              file=sys.stderr)
        return None

    max_x, max_y, max_p = extract_dimensions(cfg)
    if max_x == 0 or max_y == 0:
        print(f"# WARNING: 0x{pid:04X} ({name}): MaxX/MaxY are 0 — entry included but "
              "verify dimensions", file=sys.stderr)

    button_count  = extract_button_count(cfg)
    has_touch     = extract_has_touch_ring(cfg)
    has_eraser    = extract_has_eraser(cfg)
    feature_init  = extract_feature_init(cfg)
    seize_usb     = extract_seize_usb(cfg)

    # ── Format Swift .init(...) ────────────────────────────────────────────
    fi_str = (swift_bytes_literal(feature_init)
              if feature_init is not None else "nil")

    # Align name field width to 40 chars (matches existing registry style)
    name_repr = f'"{name}"'
    lines = [
        f'        .init(productID: 0x{pid:04X}, name: {name_repr},  // ⚠ from OTD',
        f'              parser: .{parser}, maxX: {max_x:6d}, maxY: {max_y:6d}, '
        f'maxPressure: {max_p:5d},',
        f'              buttonCount: {button_count}, hasTouchRing: '
        f'{swift_bool(has_touch)}, hasEraser: {swift_bool(has_eraser)},',
        f'              featureInit: {fi_str}, seizeUSB: {swift_bool(seize_usb)}),',
    ]
    return "\n".join(lines)


def find_otd_configs(base: str) -> list[str]:
    """Recursively find all *.json files under base."""
    paths = sorted(glob.glob(os.path.join(base, "**", "*.json"), recursive=True))
    return paths


def main():
    parser = argparse.ArgumentParser(
        description="Import OpenTabletDriver Wacom configs → Swift WacomDeviceSpec entries")
    parser.add_argument(
        "configs_dir", nargs="?",
        help="Path to OTD Configurations/Wacom directory (or any dir of Wacom *.json files)")
    parser.add_argument(
        "--all", action="store_true",
        help="Include PIDs already present in WacomDeviceRegistry (default: skip them)")
    args = parser.parse_args()

    # ── Locate configs dir ─────────────────────────────────────────────────
    if args.configs_dir:
        configs_dir = args.configs_dir
    else:
        # Auto-detect common OTD checkout locations
        candidates = [
            os.path.expanduser("~/Documents/OpenTabletDriver/Configurations/Wacom"),
            os.path.expanduser("~/OpenTabletDriver/Configurations/Wacom"),
            "/usr/share/OpenTabletDriver/Configurations/Wacom",
        ]
        configs_dir = next((p for p in candidates if os.path.isdir(p)), None)
        if configs_dir is None:
            print("ERROR: OTD Configurations/Wacom directory not found.\n"
                  "Pass the path as the first argument:\n"
                  "  python3 tools/import_otd_configs.py /path/to/OTD/Configurations/Wacom",
                  file=sys.stderr)
            sys.exit(1)

    if not os.path.isdir(configs_dir):
        print(f"ERROR: not a directory: {configs_dir}", file=sys.stderr)
        sys.exit(1)

    json_files = find_otd_configs(configs_dir)
    if not json_files:
        print(f"ERROR: no *.json files found under {configs_dir}", file=sys.stderr)
        sys.exit(1)

    # ── Emit header ────────────────────────────────────────────────────────
    action = "all" if args.all else "new (skipping existing registry PIDs)"
    print(f"// Generated by tools/import_otd_configs.py")
    print(f"// Source: {os.path.abspath(configs_dir)}")
    print(f"// PIDs: {action}")
    print(f"// Paste these entries into WacomDeviceRegistry.knownDevices.")
    print(f"// Entries marked ⚠ from OTD — verify MaxX/MaxY/MaxPressure against")
    print(f"// Linux input-wacom or live capture before shipping.")
    print()

    # ── Process each file ──────────────────────────────────────────────────
    emitted = 0
    skipped = 0
    errored = 0

    for path in json_files:
        try:
            entry = process_config(path, include_existing=args.all)
            if entry:
                print(entry)
                emitted += 1
            else:
                skipped += 1
        except Exception as e:
            print(f"# ERROR processing {os.path.basename(path)}: {e}", file=sys.stderr)
            errored += 1

    # ── Summary ────────────────────────────────────────────────────────────
    print(file=sys.stderr)
    print(f"Done: {emitted} entries emitted, {skipped} skipped, {errored} errors.",
          file=sys.stderr)
    if emitted == 0 and skipped > 0:
        print("(All PIDs are already in the registry. Run with --all to re-emit them.)",
              file=sys.stderr)


if __name__ == "__main__":
    main()
