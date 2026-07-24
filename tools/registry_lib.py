#!/usr/bin/env python3
"""registry_lib.py — shared parsing for the registry maintenance scripts.

Every script in tools/ that reads WacomDeviceRegistry.swift, the Linux kernel's
wacom_wac.c, or an OpenTabletDriver configuration tree used to carry its own
copy of the parser.  Four copies of the registry parser drifted apart, and the
two regex-based ones silently skipped any entry with a comment line between
`.init(` and `productID:` — 42 of 191 entries, disproportionately the
hand-researched ones.  This module is the single implementation.

Nothing here is wired into a build step.  Import it from a tools/ script:

    import registry_lib as rl
    entries = rl.parse_registry(rl.DEFAULT_REGISTRY)
"""

from __future__ import annotations

import glob
import json
import os
import re
from pathlib import Path
from typing import Optional

# ── Paths ─────────────────────────────────────────────────────────────────────

ROOT = Path(__file__).resolve().parent.parent

#: The registry.  Single source of truth for every script's default.
DEFAULT_REGISTRY = (
    ROOT / "TabletKit" / "Sources" / "TabletKit" / "Registry" / "WacomDeviceRegistry.swift"
)

#: Non-Wacom recognition-only registry.
DEFAULT_VENDOR_REGISTRY = (
    ROOT / "TabletKit" / "Sources" / "TabletKit" / "Registry" / "VendorDeviceRegistry.swift"
)

#: Upstream clones (gitignored) — see Notes/Scratch/upstream-pins.md.
UPSTREAM = ROOT / "Notes" / "Scratch" / "upstream"
DEFAULT_KERNEL = UPSTREAM / "input-wacom" / "4.18" / "wacom_wac.c"
DEFAULT_OTD = (
    UPSTREAM / "OpenTabletDriver" / "OpenTabletDriver.Configurations" / "Configurations"
)

WACOM_VID = 0x056A


# ── Registry parsing ──────────────────────────────────────────────────────────

_INIT_OPEN = re.compile(r"^\s*\.init\(\s*$")
_PID = re.compile(r"\bproductID:\s*(0x[0-9A-Fa-f]+|\d+)")
_NAME = re.compile(r'\bname:\s*"([^"]+)"')
_PARSER = re.compile(r"\bparser:\s*\.([A-Za-z0-9_]+)")
_CONFIDENCE = re.compile(r"\bconfidence:\s*\.([A-Za-z0-9_]+)")
_STRING_MATCH = re.compile(r'\bproductStringMatch:\s*"([^"]+)"')

_INT_FIELDS = (
    "maxX", "maxY", "maxPressure", "buttonCount",
    "maxTouchContacts", "touchMaxX", "touchMaxY",
)
_BOOL_FIELDS = (
    "hasTouchRing", "hasEraser", "hasFingerTouch", "isPenDisplay", "seizeUSB",
)
_DOUBLE_FIELDS = ("activeWidthMM", "activeHeightMM")


def _int_field(block: str, field: str) -> Optional[int]:
    m = re.search(rf"\b{field}:\s*(\d+)", block)
    return int(m.group(1)) if m else None


def _bool_field(block: str, field: str) -> Optional[bool]:
    m = re.search(rf"\b{field}:\s*(true|false)", block)
    return (m.group(1) == "true") if m else None


def _double_field(block: str, field: str) -> Optional[float]:
    m = re.search(rf"\b{field}:\s*([0-9.]+)", block)
    return float(m.group(1)) if m else None


def iter_init_blocks(lines: list[str]):
    """Yield (start_index, end_index, block_text) for each `.init(` block.

    `start_index` is the line holding `.init(`; `end_index` is one past the
    line where the parentheses balance.  Both are 0-based indices into `lines`,
    so callers doing in-place edits can splice on them directly.

    Balancing on parentheses rather than matching a fixed field order is what
    makes this tolerant of the comment lines and optional fields that appear
    throughout the registry.
    """
    i = 0
    n = len(lines)
    while i < n:
        if _INIT_OPEN.match(lines[i]):
            depth = 1
            j = i + 1
            while j < n and depth > 0:
                depth += lines[j].count("(") - lines[j].count(")")
                j += 1
            yield i, j, "\n".join(lines[i:j])
            i = j
        else:
            i += 1


def parse_registry(path: Path | str = DEFAULT_REGISTRY) -> list[dict]:
    """Parse WacomDeviceRegistry.swift into a list of entry dicts.

    Returns a *list*, not a dict keyed by PID: the registry legitimately allows
    several entries to share a PID when they are disambiguated by
    `productStringMatch`, and collapsing them would hide exactly the duplicates
    these scripts exist to find.  Order matches the file, which is also the
    order `spec(forProductID:productString:)` resolves in.
    """
    path = Path(path)
    lines = path.read_text(encoding="utf-8", errors="ignore").split("\n")
    out: list[dict] = []
    for start, _end, block in iter_init_blocks(lines):
        pid_m = _PID.search(block)
        if not pid_m:
            continue  # not a device entry (e.g. a nested value initializer)
        name_m = _NAME.search(block)
        parser_m = _PARSER.search(block)
        conf_m = _CONFIDENCE.search(block)
        sm_m = _STRING_MATCH.search(block)

        entry = {
            "pid": int(pid_m.group(1), 0),
            "name": name_m.group(1) if name_m else "",
            "parser": parser_m.group(1) if parser_m else None,
            # Entries without an explicit confidence take the Swift default.
            "confidence": conf_m.group(1) if conf_m else "experimental",
            "productStringMatch": sm_m.group(1) if sm_m else None,
            "hasInitSteps": "initSteps:" in block,
            "line": start + 1,  # 1-based, for citing in reports
        }
        for f in _INT_FIELDS:
            entry[f] = _int_field(block, f)
        for f in _BOOL_FIELDS:
            entry[f] = _bool_field(block, f)
        for f in _DOUBLE_FIELDS:
            entry[f] = _double_field(block, f)
        out.append(entry)
    return out


def registry_by_pid(entries: list[dict]) -> dict[int, list[dict]]:
    """Group parsed entries by PID, preserving file order within each group."""
    out: dict[int, list[dict]] = {}
    for e in entries:
        out.setdefault(e["pid"], []).append(e)
    return out


def resolve_spec(entries: list[dict], pid: int,
                 product_string: Optional[str] = None) -> Optional[dict]:
    """Mirror of `WacomDeviceRegistry.spec(forProductID:productString:)`.

    Kept in step with the Swift at Registry/WacomDeviceRegistry.swift so tools
    can report which entry a device would actually resolve to when a PID has
    more than one candidate.
    """
    matches = [e for e in entries if e["pid"] == pid]
    if not matches:
        return None
    if product_string:
        needle = product_string.lower()
        for e in matches:
            m = (e.get("productStringMatch") or "").lower()
            if m and m in needle:
                return e
    for e in matches:
        if e.get("productStringMatch") is None:
            return e
    return matches[0]


# ── Kernel parsing ────────────────────────────────────────────────────────────

# Struct field order:
#   name, x_max, y_max, pressure_max, distance_max,
#   type, x_resolution, y_resolution, numbered_buttons, …
# Superset of what the individual scripts each used to capture, so one parse
# serves both the dimension audits and the button-count audit.
_KERNEL_RE = re.compile(
    r"wacom_features_0x([0-9A-Fa-f]+)\s*=\s*\{\s*\"([^\"]*)\"\s*,\s*"
    r"(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*"
    r"([A-Z_0-9]+)\s*,\s*([A-Z_0-9]+)\s*,\s*([A-Z_0-9]+)\s*(?:,\s*(\d+))?",
    re.S,
)


def parse_kernel(path: Path | str = DEFAULT_KERNEL) -> dict[int, dict]:
    """Parse wacom_wac.c's `wacom_features` table into {pid: {...}}.

    Touch-only entries that declare no dimensions do not match and are absent
    from the result — the same behavior every caller had before.
    """
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(
            f"kernel source not found: {path}\n"
            f"Clone linuxwacom/input-wacom into {UPSTREAM} "
            f"(see Notes/Scratch/upstream-pins.md)."
        )
    text = path.read_text(encoding="utf-8", errors="ignore")
    out: dict[int, dict] = {}
    for m in _KERNEL_RE.finditer(text):
        out[int(m.group(1), 16)] = {
            "name": m.group(2),
            "maxX": int(m.group(3)),
            "maxY": int(m.group(4)),
            "maxPressure": int(m.group(5)),
            "distanceMax": int(m.group(6)),
            "type": m.group(7),
            "buttonCount": int(m.group(10)) if m.group(10) else 0,
        }
    return out


# ── OpenTabletDriver parsing ──────────────────────────────────────────────────

def parse_pid(raw) -> Optional[int]:
    """Normalize an OTD ProductID, which may be int, "0x1234", or "1234"."""
    if raw is None:
        return None
    if isinstance(raw, int):
        return raw
    s = str(raw).strip()
    if not s:
        return None
    try:
        return int(s, 16) if s.lower().startswith("0x") else int(s)
    except ValueError:
        return None


def find_otd_configs(base: Path | str) -> list[str]:
    """Every *.json under `base`, recursively.

    OTD nests configurations one directory per vendor (Configurations/Wacom/…).
    A non-recursive glob here returns nothing and, worse, reads as "upstream has
    no entry for this device" downstream — which is how the OTD column in
    verify_registry.py silently went empty.
    """
    return sorted(glob.glob(os.path.join(str(base), "**", "*.json"), recursive=True))


def parse_otd(directory: Path | str = DEFAULT_OTD,
              vendor_id: int = WACOM_VID) -> dict[int, dict]:
    """Parse an OTD configuration tree into {pid: {...}} for one vendor.

    Raises if the tree holds no configs at all — an empty result is far more
    often a wrong path than a genuinely empty upstream.
    """
    directory = Path(directory)
    if not directory.is_dir():
        raise FileNotFoundError(
            f"OTD configuration directory not found: {directory}\n"
            f"Clone OpenTabletDriver/OpenTabletDriver into {UPSTREAM} "
            f"(see Notes/Scratch/upstream-pins.md)."
        )
    paths = find_otd_configs(directory)
    if not paths:
        raise ValueError(
            f"no *.json configurations found under {directory} — "
            f"check the path points at the Configurations tree."
        )

    out: dict[int, dict] = {}
    for fp in paths:
        try:
            with open(fp, encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        name = cfg.get("Name", os.path.splitext(os.path.basename(fp))[0])
        specs = cfg.get("Specifications", {}) or {}
        dig = specs.get("Digitizer", {}) or {}
        pen = specs.get("Pen", {}) or {}
        max_x = int(cfg.get("MaxX") or dig.get("MaxX") or 0)
        max_y = int(cfg.get("MaxY") or dig.get("MaxY") or 0)
        max_p = int(cfg.get("MaxPressure") or pen.get("MaxPressure") or 0)

        # Current schema: DigitizerIdentifiers[].
        for di in cfg.get("DigitizerIdentifiers", []) or []:
            if not isinstance(di, dict):
                continue
            if int(di.get("VendorID", 0)) != vendor_id:
                continue
            pid = parse_pid(di.get("ProductID"))
            if pid is None:
                continue
            out[pid] = {
                "name": name, "maxX": max_x, "maxY": max_y,
                "maxP": max_p,
                "parser": di.get("ReportParser", "").split(".")[-1].split(",")[0],
            }

        # Legacy schema: top-level VID/PID.
        if int(cfg.get("VendorID", 0)) == vendor_id:
            pid = parse_pid(cfg.get("ProductID"))
            if pid is not None and pid not in out:
                out[pid] = {
                    "name": name, "maxX": max_x, "maxY": max_y,
                    "maxP": max_p,
                    "parser": cfg.get("ReportParser", "").split(".")[-1].split(",")[0],
                }
    return out


# ── Swift emission helpers ────────────────────────────────────────────────────

def swift_string(s: Optional[str]) -> str:
    if s is None:
        return "nil"
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swift_int(n: Optional[int]) -> str:
    return "nil" if n is None else str(n)


def swift_double(x: Optional[float]) -> str:
    if x is None:
        return "nil"
    return str(int(x)) if float(x).is_integer() else f"{x:g}"


def swift_bool(b: Optional[bool]) -> str:
    return "nil" if b is None else ("true" if b else "false")


def swift_bytes_literal(byte_list: list[int]) -> str:
    return "[" + ", ".join(f"0x{b:02X}" for b in byte_list) + "]"


# ── Geometry ──────────────────────────────────────────────────────────────────

#: Per-axis LPI disagreement beyond this fraction means the coordinate range and
#: the physical dimensions describe different devices — a stale upstream row or
#: a cross-product PID collision.  Shared with backfill_libwacom_dimensions.py
#: so the tools and the registry tests agree on what "consistent" means.
LPI_TOLERANCE = 0.08


def axis_lpi(max_count: Optional[int], mm: Optional[float]) -> Optional[float]:
    """Lines per inch implied by a coordinate range over a physical size."""
    if not max_count or not mm:
        return None
    return max_count / (mm / 25.4)


def lpi_disagreement(entry: dict) -> Optional[float]:
    """Fractional disagreement between an entry's X and Y LPI, or None.

    None when the entry lacks the dimensions needed to compute it.
    """
    lx = axis_lpi(entry.get("maxX"), entry.get("activeWidthMM"))
    ly = axis_lpi(entry.get("maxY"), entry.get("activeHeightMM"))
    if lx is None or ly is None or min(lx, ly) == 0:
        return None
    return abs(lx - ly) / min(lx, ly)
