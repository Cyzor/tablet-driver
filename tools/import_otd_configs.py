#!/usr/bin/env python3
"""import_otd_configs.py — OTD → WacomDeviceSpec importer

Parses OpenTabletDriver Configurations/Wacom/*.json files and emits Swift
.init(...) entries for WacomDeviceRegistry.knownDevices.

Supports both OTD schema versions:
  Legacy:  top-level VendorID / ProductID / ReportParser / FeatureInitializationReport
  Current: DigitizerIdentifiers[].VendorID / ProductID / ReportParser / FeatureInitReport
           Specifications.Digitizer.MaxX/MaxY, Specifications.Pen.MaxPressure
           Attributes dict with FeatureInitDelayMs

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
from typing import Optional

# ── PIDs already in WacomDeviceRegistry.knownDevices ──────────────────────────
# Skip these by default to avoid duplicating confirmed/hand-tuned entries.
EXISTING_PIDS = {
    # Graphire / PenPartner / Volito
    0x0003, 0x0004, 0x0010, 0x0011, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017,
    0x003F, 0x0060, 0x0061, 0x0062, 0x0065,
    # Graphire-era CTE / CTF consumer line
    0x0018, 0x0069, 0x006A, 0x006B,
    # Intuos 1–2
    0x0020, 0x0021, 0x0022, 0x0023, 0x0024,
    0x0041, 0x0042, 0x0043, 0x0044, 0x0045,
    # Intuos3 (PTZ)
    0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B7,
    # Intuos4 (PTK)
    0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC,
    0x0029, 0x002A,
    # Intuos5 (PTH-x50)
    0x0026, 0x0027, 0x0028,
    # Intuos Pro first-gen (PTH-x51)
    0x0314, 0x0315, 0x0316, 0x0317,
    # Intuos Pro second-gen (PTH-x60/x80 + alt PIDs)
    0x0352, 0x0357, 0x0358, 0x0360, 0x0392, 0x03DC,
    # Bamboo CTH (pen + touch)
    0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D6, 0x00D7, 0x00D8,
    0x00DA, 0x00DB, 0x00DE, 0x00DF,
    0x0302, 0x0303, 0x0318, 0x0319, 0x033C, 0x033E,
    # Wacom One / Intuos CTL (pen-only)
    0x00DD,
    0x0300, 0x0301, 0x030E, 0x0323, 0x033B, 0x033D,
    0x037A, 0x037B,
    0x0374, 0x0375, 0x0376, 0x0377, 0x0378, 0x03C5, 0x03C7,
    # Cintiq pen-displays
    0x00C0, 0x00C4, 0x00C6, 0x00CC, 0x00F4, 0x00F8, 0x00F9, 0x00FA, 0x00FB,
    0x0304, 0x034F, 0x0390, 0x03A6, 0x03AE, 0x03C0, 0x03F0,
    # Wireless dongle
    0x0084,
}

# ── ReportParser class-name → MockTab parser family ───────────────────────────
# Matched against the class-name suffix of ReportParser strings in either schema.
TYPE_TO_PARSER = {
    # Legacy / old-format names
    "WacomDriverlessTablet":        "graphire",
    "WacomDriverless":              "graphire",
    "Graphire":                     "graphire",
    "IntuosV1":                     "intuosV1",
    "Intuos4V2":                    "intuosV1",  # Intuos4 uses same 10-byte format
    "WacomV1":                      "intuosV1",
    "IntuosV2":                     "intuosV2",
    "WacomV2":                      "intuosV2",
    "Bamboo":                       "bamboo",
    "BambooV2":                     "bamboo",

    # Current OTD class-name suffixes
    "IntuosReportParser":           "intuosV1",   # Intuos 1/2
    "IntuosV1ReportParser":         "intuosV1",
    "WacomDriverIntuosReportParser":   "intuosV1",
    "WacomDriverIntuosV1ReportParser": "intuosV1",
    "Intuos3ReportParser":             "intuos3",
    "WacomDriverIntuos3ReportParser":  "intuos3",
    "Intuos3ExtraAuxReportParser":     "intuos3",
    "CintiqV1ReportParser":            "intuosV1",  # Cintiq (DTK/DTZ) same 10-byte format
    "IntuosV2ReportParser":            "intuosV2",
    "WacomDriverIntuosV2ReportParser": "intuosV2",
    "BambooReportParser":              "bamboo",
    "BambooPadReportParser":           "bamboo",
    "IntuosV3ReportParser":            "intuosV3",  # PTK-470/670/870 (experimental)
    # Parsers we deliberately do NOT map — MockTab has no compatible decoder
    # and an automatic fallback would produce silently-broken registry entries.
    # If you add a decoder here, also remove the corresponding `is None` warning
    # in extract_parser.
    #   PLReportParser        — old Cintiq PL series (8-byte reports, bit-6
    #                           in-range flag); incompatible with intuosV1.
    #   PTUReportParser, SkipByteTabletReportParser, TabletReportParser,
    #   Wacom64bAuxReportParser — aux-only or otherwise out of scope.
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


def map_parser_name(name: str) -> Optional[str]:
    """
    Map a full ReportParser class name (or its suffix) to a MockTab parser family.
    Returns None if the parser is aux-only or unrecognised.
    """
    suffix = name.split(".")[-1].split(",")[0]
    if suffix in TYPE_TO_PARSER:
        return TYPE_TO_PARSER[suffix]
    # Partial-match fallback against the full string
    name_lower = name.lower()
    for key, val in TYPE_TO_PARSER.items():
        if key.lower() in name_lower:
            return val
    return None


# ── Per-device-identifier extraction ─────────────────────────────────────────

class DeviceIdent:
    """One entry from DigitizerIdentifiers (or synthesised from legacy top-level fields)."""
    def __init__(self, vendor_id: int, product_id: int, report_len: int,
                 parser_name: str, feature_init_reports: list[list[int]]):
        self.vendor_id            = vendor_id
        self.product_id           = product_id
        self.report_len           = report_len
        self.parser_name          = parser_name
        self.feature_init_reports = feature_init_reports  # list of byte-lists


def decode_feature_init_reports(raw) -> list[list[int]]:
    """
    Decode FeatureInitReport / FeatureInitializationReport.
    Accepts a string (legacy) or list of strings (current OTD).
    Returns a list of byte-lists (one per stage).
    """
    if not raw:
        return []
    if isinstance(raw, str):
        raw = [raw]
    result = []
    for item in raw:
        if not isinstance(item, str):
            continue
        try:
            decoded = list(base64.b64decode(item))
            if decoded:
                result.append(decoded)
        except Exception:
            pass
    return result


def extract_identifiers(cfg: dict) -> list[DeviceIdent]:
    """
    Return a list of DeviceIdent objects for this config.

    Handles both schema versions:
      Current: cfg["DigitizerIdentifiers"] array
      Legacy:  top-level VendorID / ProductID / ReportParser
    """
    idents = []

    # ── Current format ────────────────────────────────────────────────────────
    di_list = cfg.get("DigitizerIdentifiers", [])
    if di_list and isinstance(di_list, list):
        for di in di_list:
            if not isinstance(di, dict):
                continue
            vid = di.get("VendorID", 0)
            pid = parse_product_id(di.get("ProductID"))
            if not pid or int(vid) != WACOM_VENDOR_ID:
                continue
            rp  = di.get("ReportParser", "")
            irl = int(di.get("InputReportLength", 0))
            fir = decode_feature_init_reports(di.get("FeatureInitReport"))
            idents.append(DeviceIdent(int(vid), pid, irl, rp, fir))
        return idents

    # ── Legacy format ─────────────────────────────────────────────────────────
    vid = cfg.get("VendorID", 0)
    pid = parse_product_id(cfg.get("ProductID"))
    if pid and int(vid) == WACOM_VENDOR_ID:
        rp  = cfg.get("ReportParser", "")
        irl = int(cfg.get("InputReportLength", 0))
        fir = decode_feature_init_reports(cfg.get("FeatureInitializationReport"))
        idents.append(DeviceIdent(int(vid), pid, irl, rp, fir))

    return idents


def pick_primary_ident(idents: list[DeviceIdent]) -> Optional[DeviceIdent]:
    """
    Given multiple identifiers for the same device, prefer the one whose
    parser maps to a known family.  If tied, prefer the one with the
    longer report (pen interface over aux).
    """
    mapped = [d for d in idents if map_parser_name(d.parser_name) is not None]
    pool   = mapped if mapped else idents
    return max(pool, key=lambda d: d.report_len) if pool else None


# ── Spec-level extraction ─────────────────────────────────────────────────────

def extract_parser(ident: DeviceIdent) -> Optional[str]:
    """
    Resolve parser family from the identifier's ReportParser class name.
    Returns None if the parser is unknown or known-incompatible — the
    caller should skip those entries with a warning rather than guess.

    The previous version of this function had an InputReportLength
    heuristic (>64 → intuosV2, >0 → intuosV1) that silently produced
    broken registry entries for IntuosV3 and PL devices. Don't bring
    it back without first wiring up a decoder for the missing family.
    """
    return map_parser_name(ident.parser_name)


def extract_dimensions(cfg: dict) -> tuple[int, int, int]:
    """Return (maxX, maxY, maxPressure)."""
    specs = cfg.get("Specifications", {}) or {}
    dig   = specs.get("Digitizer", {}) or {}
    pen   = specs.get("Pen", {}) or {}

    max_x = cfg.get("MaxX") or dig.get("MaxX") or 0
    max_y = cfg.get("MaxY") or dig.get("MaxY") or 0
    max_p = cfg.get("MaxPressure") or pen.get("MaxPressure") or 0

    return int(max_x), int(max_y), int(max_p)


def extract_button_count(cfg: dict) -> int:
    specs = cfg.get("Specifications", {}) or {}
    aux   = specs.get("AuxiliaryButtons", {}) or {}
    bc    = cfg.get("ButtonCount") or aux.get("ButtonCount") or 0
    return int(bc)


def extract_has_touch_ring(cfg: dict) -> bool:
    specs = cfg.get("Specifications", {}) or {}
    if specs.get("TouchRing") or specs.get("TouchStrip"):
        return True
    return bool(cfg.get("HasTouchRing", False))


def extract_has_eraser(cfg: dict) -> bool:
    specs = cfg.get("Specifications", {}) or {}
    pen   = specs.get("Pen", {}) or {}
    eraser = pen.get("HasEraser")
    if eraser is not None:
        return bool(eraser)
    return bool(cfg.get("HasEraser", True))


def extract_feature_init_delay(cfg: dict) -> float:
    """
    Return featureInit2 delay in seconds.
    Current OTD: Attributes["FeatureInitDelayMs"] (dict, string value).
    Legacy OTD:  Attributes[n]["FeatureInitDelayMs"] (list of dicts).
    Default: 0.15 s.
    """
    attrs = cfg.get("Attributes")
    if not attrs:
        return 0.15
    # Current format: attrs is a dict
    if isinstance(attrs, dict):
        raw = attrs.get("FeatureInitDelayMs")
        if raw is not None:
            try:
                return float(raw) / 1000.0
            except (ValueError, TypeError):
                pass
    # Legacy format: attrs is a list of dicts
    if isinstance(attrs, list):
        for attr in attrs:
            if not isinstance(attr, dict):
                continue
            raw = attr.get("FeatureInitDelayMs")
            if raw is not None:
                try:
                    return float(raw) / 1000.0
                except (ValueError, TypeError):
                    pass
    return 0.15


def extract_seize_usb(cfg: dict) -> bool:
    """
    True when this device needs kIOHIDOptionsTypeSeizeDevice.
    OTD signals this via an Interface attribute with Interface == 0.
    """
    if cfg.get("SeizeUSB") or cfg.get("RequiresSeize"):
        return True
    attrs = cfg.get("Attributes", [])
    # Current format: attrs is a dict — no Interface key, so no seize signal
    if isinstance(attrs, dict):
        return False
    # Legacy format: attrs is a list of dicts
    if isinstance(attrs, list):
        for attr in attrs:
            if not isinstance(attr, dict):
                continue
            iface = attr.get("Interface")
            if iface == 0:
                return True
            if isinstance(iface, str):
                try:
                    if int(iface, 0) == 0:
                        return True
                except ValueError:
                    pass
    return False


# ── Swift formatting ──────────────────────────────────────────────────────────

def swift_bytes_literal(byte_list: list[int]) -> str:
    return "[" + ", ".join(f"0x{b:02X}" for b in byte_list) + "]"


def swift_bool(b: bool) -> str:
    return "true" if b else "false"


# ── Main per-file processing ──────────────────────────────────────────────────

def process_config(path: str, include_existing: bool) -> list[str]:
    """
    Parse one OTD JSON config and return a list of Swift .init(...) strings
    (one per unique PID found in DigitizerIdentifiers).
    Returns an empty list if the file should be skipped.
    Raises on unexpected errors (caller handles).
    """
    with open(path, encoding="utf-8") as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError as e:
            print(f"# WARNING: {os.path.basename(path)}: JSON parse error: {e}",
                  file=sys.stderr)
            return []

    idents = extract_identifiers(cfg)
    if not idents:
        # No Wacom identifiers found — wrong vendor or missing ProductID
        return []

    name     = cfg.get("Name", "").strip()
    max_x, max_y, max_p = extract_dimensions(cfg)
    button_count         = extract_button_count(cfg)
    has_touch            = extract_has_touch_ring(cfg)
    has_eraser           = extract_has_eraser(cfg)
    seize_usb            = extract_seize_usb(cfg)
    init_delay           = extract_feature_init_delay(cfg)

    # Deduplicate: one entry per unique PID, using the best ident for that PID.
    by_pid: dict[int, DeviceIdent] = {}
    for ident in idents:
        pid = ident.product_id
        if pid not in by_pid:
            by_pid[pid] = ident
        else:
            # Prefer the ident whose parser maps to a known family
            existing_mapped = map_parser_name(by_pid[pid].parser_name) is not None
            this_mapped     = map_parser_name(ident.parser_name) is not None
            if this_mapped and not existing_mapped:
                by_pid[pid] = ident

    entries = []
    for pid, ident in sorted(by_pid.items()):
        if not include_existing and pid in EXISTING_PIDS:
            continue

        parser = extract_parser(ident)
        if parser is None:
            print(f"# WARNING: 0x{pid:04X} ({name}): cannot determine parser family, skipping",
                  file=sys.stderr)
            continue

        if not name:
            print(f"# WARNING: 0x{pid:04X}: missing Name, skipping", file=sys.stderr)
            continue

        if max_x == 0 or max_y == 0:
            print(f"# WARNING: 0x{pid:04X} ({name}): MaxX/MaxY are 0 — entry included but "
                  "verify dimensions", file=sys.stderr)

        # Build featureInit / featureInit2 from the init reports on this ident.
        # If the ident has none, fall back to the shared config-level reports
        # (legacy FeatureInitializationReport already decoded into ident.feature_init_reports).
        init_reports = ident.feature_init_reports
        fi1 = init_reports[0] if len(init_reports) >= 1 else None
        fi2 = init_reports[1] if len(init_reports) >= 2 else None

        fi1_str = swift_bytes_literal(fi1) if fi1 else "nil"
        fi2_str = swift_bytes_literal(fi2) if fi2 else "nil"

        # Emit featureInit2Delay only when non-default (0.15 s)
        delay_str = ""
        if fi2 is not None and abs(init_delay - 0.15) > 0.001:
            delay_str = f",\n              featureInit2Delay: {init_delay:.3f}"

        # Emit featureInit2 line only when present
        fi2_line = ""
        if fi2 is not None:
            fi2_line = f",\n              featureInit2: {fi2_str}{delay_str}"

        lines = [
            f'        .init(productID: 0x{pid:04X}, name: "{name}",  // ⚠ from OTD',
            f'              parser: .{parser}, maxX: {max_x:6d}, maxY: {max_y:6d}, '
            f'maxPressure: {max_p:5d},',
            f'              buttonCount: {button_count}, hasTouchRing: '
            f'{swift_bool(has_touch)}, hasEraser: {swift_bool(has_eraser)},',
            f'              featureInit: {fi1_str}, seizeUSB: {swift_bool(seize_usb)}'
            + fi2_line + '),',
        ]
        entries.append("\n".join(lines))

    return entries


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
            entries = process_config(path, include_existing=args.all)
            if entries:
                for entry in entries:
                    print(entry)
                emitted += len(entries)
            else:
                skipped += 1
        except Exception as e:
            print(f"# ERROR processing {os.path.basename(path)}: {e}", file=sys.stderr)
            errored += 1

    # ── Summary ────────────────────────────────────────────────────────────
    print(file=sys.stderr)
    print(f"Done: {emitted} entries emitted, {skipped} files skipped, {errored} errors.",
          file=sys.stderr)


if __name__ == "__main__":
    main()
