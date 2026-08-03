#!/usr/bin/env python3
"""triage_discovery.py — first pass over a submitted device-capture file.

MockTab's *Collect Device Data…* flow produces a JSON file that users paste
into a device-support issue.  This tool reads one such file and prints a
Markdown triage report: what the device is, what its HID descriptor already
tells us about coordinate/pressure ranges, an inventory of its reports, how it
compares to the kernel and OpenTabletDriver, and a *draft* registry entry to
start from.

It reads two shapes (see MockTab/Driver/CaptureModels.swift):
  • discovery   — per-report varying/constant byte analysis.  The only shape
                  the app still emits.
  • calibration — guided capture; per-report field roles.  The guided flow was
                  retired, so no new file will have this shape; support stays
                  for captures submitted before then.
The two are told apart by structure, not by captureVersion, since the version
numbers evolve independently of the mode.

Nothing here decides support on its own — the draft entry is a starting point
for human review against real hardware, never a paste-and-ship artifact.

Usage:
    python3 tools/triage_discovery.py path/to/capture.json
    python3 tools/triage_discovery.py capture.json --no-upstream   # skip kernel/OTD
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional

import registry_lib as rl

# HID usage constants (Generic Desktop page 0x01, Digitizer page 0x0D).
UP_GENERIC_DESKTOP = 0x01
UP_DIGITIZER = 0x0D
USAGE_X = 0x30
USAGE_Y = 0x31
USAGE_TIP_PRESSURE = 0x30  # on the digitizer page

# Rough (reportID, length) → decoder-family hints.  Deliberately loose: a match
# is a lead to check against the decoder source, not a decision.  Lengths are
# the common ones seen in captures; None length means "any length with this ID".
DECODER_HINTS = [
    (0x10, None, "intuosV2 (pen position + pressure)"),
    (0x11, None, "intuosV2 (express keys / aux)"),
    (0x02, 10, "graphire / bamboo (pen)"),
    (0x02, None, "bamboo / vendor pen report"),
    (0x03, None, "bamboo (button / aux)"),
    (0x0F, None, "intuos3 (aux)"),
    (0x06, None, "intuos3 (pen)"),
    (0x21, None, "intuosV1/V2 touch (finger contacts)"),
    (0x0D, None, "intuosV1 (pen)"),
]


class TriageError(Exception):
    """A capture that cannot be triaged at all (unreadable / wrong shape)."""


# ── Loading and classification ───────────────────────────────────────────────

def load(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise TriageError(f"no such file: {path}")
    # Submissions are often pasted with surrounding prose, a leading date, or a
    # ```json fence.  Decode the first JSON object in the file rather than
    # insisting the whole file be pure JSON.
    start = text.find("{")
    if start == -1:
        raise TriageError("no JSON object found in file")
    try:
        obj, _end = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as e:
        raise TriageError(f"not valid JSON: {e}")
    if not isinstance(obj, dict):
        raise TriageError("top-level JSON is not an object")
    return obj


def classify(doc: dict) -> str:
    """Return 'discovery' or 'calibration' from structure, not version number."""
    if doc.get("mode") == "discovery":
        return "discovery"
    reports = doc.get("reports")
    if isinstance(reports, dict) and reports:
        sample = next(iter(reports.values()))
        if isinstance(sample, dict):
            if "varyingBytes" in sample:
                return "discovery"
            if "fields" in sample or "sampleAction" in sample:
                return "calibration"
    # Fall back to the version convention only as a last resort.
    return "discovery" if doc.get("captureVersion", 0) >= 3 else "calibration"


# ── Validation ────────────────────────────────────────────────────────────────

def parse_hex_id(raw) -> Optional[int]:
    if raw is None:
        return None
    try:
        return int(str(raw), 16) if str(raw).lower().startswith("0x") else int(str(raw))
    except ValueError:
        return None


def validate(doc: dict, kind: str) -> list[str]:
    """Return a list of human-readable problems ([] means clean)."""
    problems: list[str] = []
    dev = doc.get("deviceInfo")
    if not isinstance(dev, dict):
        problems.append("missing `deviceInfo` object")
        return problems  # nothing else is checkable

    vid = parse_hex_id(dev.get("vendorID"))
    pid = parse_hex_id(dev.get("productID"))
    if vid is None:
        problems.append(f"vendorID not parseable: {dev.get('vendorID')!r}")
    if pid is None:
        problems.append(f"productID not parseable: {dev.get('productID')!r}")
    elif pid == 0:
        problems.append("productID is 0x0000 — the device was not identified; "
                        "capture is not usable for a registry entry")
    if not dev.get("name"):
        problems.append("deviceInfo.name is empty")
    if not doc.get("reports"):
        problems.append("no `reports` captured")

    # Privacy: older captures may still carry a serial.  Flag it so it can be
    # scrubbed before the file is committed anywhere in the repo.
    if dev.get("serialNumber"):
        problems.append("SERIAL PRESENT — `deviceInfo.serialNumber` is set; "
                        "scrub it before committing this file (current app "
                        "builds no longer emit it)")
    return problems


# ── Descriptor-derived specifications ─────────────────────────────────────────

def descriptor_fields(doc: dict) -> list[tuple[str, dict]]:
    """Flatten the parsed HID descriptor to (report_key, field) pairs."""
    out = []
    desc = doc.get("hidReportDescriptor") or {}
    for rkey, rep in (desc.get("reports") or {}).items():
        for f in rep.get("fields", []) or []:
            out.append((rkey, f))
    return out


def find_axis(fields: list[tuple[str, dict]], usage_page: int,
              usage: int) -> Optional[dict]:
    for _rkey, f in fields:
        if f.get("usagePage") == usage_page and f.get("usage") == usage:
            return f
    return None


def physical_mm(field: Optional[dict]) -> Optional[float]:
    """Best-effort physical extent in mm from physicalMax + unitExponent.

    HID length units are centimeters; unitExponent scales the reported value by
    10**exp.  Returns None when the fields needed aren't present or the unit is
    not a length.  This is advisory — declared physical extents are frequently
    wrong, which is why the byte-level analysis exists to cross-check.
    """
    if not field:
        return None
    phys = field.get("physicalMax")
    if not phys:
        return None
    exp = field.get("unitExponent", 0) or 0
    # unitExponent is a 4-bit signed nibble in HID; values 8..15 are -8..-1.
    if exp > 7:
        exp -= 16
    cm = phys * (10 ** exp)
    mm = cm * 10.0
    # Guard against nonsense (e.g. unit not actually length): a tablet is
    # between ~1 cm and ~1.5 m on a side.
    return mm if 5.0 <= mm <= 1500.0 else None


def descriptor_section(doc: dict) -> list[str]:
    fields = descriptor_fields(doc)
    lines = ["## Descriptor-derived specifications", ""]
    if not fields:
        lines += ["_No parsed HID report descriptor in this capture "
                  "(pre-v3 file, or the device did not expose one)._", ""]
        return lines

    x = find_axis(fields, UP_GENERIC_DESKTOP, USAGE_X)
    y = find_axis(fields, UP_GENERIC_DESKTOP, USAGE_Y)
    p = find_axis(fields, UP_DIGITIZER, USAGE_TIP_PRESSURE)

    if not any((x, y, p)):
        lines += ["The descriptor is **opaque** — every field is on a "
                  "vendor-defined page or uses undefined usage codes. No "
                  "coordinate or pressure ranges can be read from it; rely on "
                  "the byte analysis and upstream sources below.", ""]
        return lines

    def row(label, f, mm=None):
        if not f:
            return f"| {label} | — | — | not in descriptor |"
        extra = f"{mm:.0f} mm" if mm else ""
        return (f"| {label} | {f.get('logicalMax')} | "
                f"{f.get('physicalMax', '')} | {extra} |")

    lines += [
        "| Axis | logicalMax (→ registry) | physicalMax | physical size |",
        "|------|------------------------:|------------:|---------------|",
        row("X (maxX)", x, physical_mm(x)),
        row("Y (maxY)", y, physical_mm(y)),
        row("Pressure (maxPressure)", p),
        "",
        "`logicalMax` values map straight onto the registry's `maxX` / `maxY` / "
        "`maxPressure`. Physical size is advisory — verify against the model's "
        "spec sheet.", "",
    ]
    return lines


# ── Report inventory ──────────────────────────────────────────────────────────

def guess_family(report_id: int, length: Optional[int]) -> Optional[str]:
    for rid, rlen, name in DECODER_HINTS:
        if rid == report_id and (rlen is None or rlen == length):
            return name
    return None


def report_inventory(doc: dict, kind: str) -> list[str]:
    lines = ["## Report inventory", ""]
    reports = doc.get("reports") or {}
    if not reports:
        lines += ["_none_", ""]
        return lines

    lines += ["| Report | len | samples | varying bytes | likely decoder |",
              "|--------|----:|--------:|---------------|----------------|"]
    varied_length = []
    for key in sorted(reports, key=lambda k: parse_hex_id(k) or 0):
        rep = reports[key]
        rid = rep.get("reportID", parse_hex_id(key))
        length = rep.get("length")
        if kind == "discovery":
            samples = rep.get("sampleCount", "")
            varying = rep.get("varyingBytes", [])
            varying_str = ", ".join(str(b) for b in varying) if varying else "—"
            # captureVersion >= 5 reports length variation instead of silently
            # analysing only the first sample's worth of bytes.
            if rep.get("lengthVaried"):
                length = f"{length}–{rep.get('maxLength', length)}"
                varied_length.append(key)
        else:
            samples = ""
            fields = rep.get("fields") or {}
            varying_str = ", ".join(sorted(fields)) if fields else "—"
        fam = guess_family(rid, length) or "—"
        lines.append(f"| {key} | {length} | {samples} | {varying_str} | {fam} |")
    lines.append("")
    if varied_length:
        lines.append("Reports with a length range (" + ", ".join(varied_length) +
                     ") arrived at more than one size; their `optionalBytes` "
                     "were present in only some samples and are neither "
                     "constant nor varying.")
        lines.append("")
    lines.append("Decoder guesses match on (report ID, length) only — confirm "
                 "against the matching file in "
                 "`TabletKit/Sources/TabletKit/Decoders/` before trusting one.")
    lines.append("")
    return lines


def byte_ranges_section(doc: dict, kind: str) -> list[str]:
    """Per-byte observed ranges — the strongest hint at what a byte carries.

    Only emitted for captureVersion >= 5, which added `byteStats`.  A byte that
    swept 0–255 is a pressure or coordinate low byte; one that only ever took
    two values is a flag field.  Earlier captures listed a *truncated, sorted*
    sample of values, so their apparent maximum was meaningless.
    """
    if kind != "discovery":
        return []
    reports = doc.get("reports") or {}
    rows = []
    for key in sorted(reports, key=lambda k: parse_hex_id(k) or 0):
        stats = reports[key].get("byteStats") or {}
        for idx in sorted(stats, key=lambda i: int(i)):
            st = stats[idx]
            if not isinstance(st, dict):
                continue
            rows.append((key, int(idx), st.get("min"), st.get("max"),
                         st.get("distinctCount")))
    if not rows:
        return []

    lines = ["## Observed byte ranges", ""]
    lines += ["| Report | byte | min | max | distinct |",
              "|--------|-----:|----:|----:|---------:|"]
    for key, idx, lo, hi, n in rows:
        lines.append(f"| {key} | {idx} | {lo} | {hi} | {n} |")
    lines.append("")
    lines.append("A byte reaching 255 with many distinct values is a likely "
                 "pressure/coordinate byte; two or three distinct values "
                 "suggests a button or flag field.")
    lines.append("")
    return lines


def discriminated_byte_ranges_section(doc: dict, kind: str) -> list[str]:
    """Byte ranges re-split by byte 1 — captureVersion >= 6's
    `byteStatsByDiscriminator`.

    The section above aggregates every sample of a report ID into one
    histogram per byte position. If that report ID actually carries more than
    one packet shape sharing one ID and length — an ordinary coordinate
    report and a tool-change/aux report, on the Wacom IntuosV1 family and
    similar protocols — the aggregate range for a coordinate byte can look
    far wider than the pen's real travel, because a handful of tool-change
    samples (carrying serial/type bytes at the same positions) got folded in
    with thousands of real position samples. This reads the app's own
    pre-split buckets instead of re-deriving anything: each bucket is every
    sample where byte 1 held one particular value, so a genuine coordinate
    sweep and a tool-change packet's fixed fields no longer share a row.

    Present only when the app judged byte 1 to behave like a status/type
    field (2 to 16 distinct values); absent for a report where byte 1 never
    varied, or varied too much to be a plausible discriminator — see
    `CaptureEngine.discriminatorMaxDistinct`.
    """
    if kind != "discovery":
        return []
    reports = doc.get("reports") or {}
    lines = []
    for key in sorted(reports, key=lambda k: parse_hex_id(k) or 0):
        by_disc = reports[key].get("byteStatsByDiscriminator") or {}
        if not by_disc:
            continue
        lines.append(f"## Byte ranges by packet type — report {key}")
        lines.append("")
        lines.append(
            "Byte 1 (the byte right after the report ID) took "
            f"{len(by_disc)} distinct values across this report's samples — "
            "plausibly a packet-type/status field, not more coordinate data. "
            "Each row below is the byte ranges for samples sharing one byte-1 "
            "value; compare against the un-split ranges above.")
        lines.append("")
        lines.append("| Byte 1 | samples | byte | min | max | distinct |")
        lines.append("|-------:|--------:|-----:|----:|----:|---------:|")
        for disc in sorted(by_disc):
            bucket = by_disc[disc]
            n = bucket.get("sampleCount")
            stats = bucket.get("byteStats") or {}
            for idx in sorted(stats, key=lambda i: int(i)):
                st = stats[idx]
                lines.append(
                    f"| 0x{disc} | {n} | {idx} | {st.get('min')} | "
                    f"{st.get('max')} | {st.get('distinctCount')} |")
        lines.append("")
    return lines


def tool_codes_section(doc: dict) -> list[str]:
    """Wacom tool codes seen during collection, when the capture recorded any."""
    codes = doc.get("observedToolCodes")
    if not codes:
        return []
    lines = ["## Tools observed", "", ", ".join(f"`{c}`" for c in codes), ""]
    if any(str(c).lower() == "0x080a" for c in codes):
        lines += ["The eraser tool code (`0x080A`) appeared, so this device "
                  "reports the eraser as a distinct tool.", ""]
    return lines


# ── Upstream cross-reference ──────────────────────────────────────────────────

def upstream_section(pid: Optional[int]) -> list[str]:
    lines = ["## Upstream cross-reference", ""]
    if pid is None:
        lines += ["_no PID to look up_", ""]
        return lines
    try:
        kernel = rl.parse_kernel()
    except FileNotFoundError:
        kernel = None
    try:
        otd = rl.parse_otd()
    except (FileNotFoundError, ValueError):
        otd = None

    if kernel is None and otd is None:
        lines += ["_upstream clones not present under `Notes/Scratch/upstream/` "
                  "— run with them checked out for kernel/OTD comparison._", ""]
        return lines

    k = (kernel or {}).get(pid)
    o = (otd or {}).get(pid)
    lines += ["| Source | name | maxX | maxY | maxPressure |",
              "|--------|------|-----:|-----:|------------:|"]
    if k:
        lines.append(f"| kernel | {k['name']} | {k['maxX']} | {k['maxY']} | "
                     f"{k['maxPressure']} |")
    if o:
        lines.append(f"| OTD | {o['name']} | {o['maxX']} | {o['maxY']} | "
                     f"{o['maxP']} |")
    if not k and not o:
        lines.append("| — | not found in kernel or OTD | | | |")
    lines.append("")
    return lines


# ── Draft registry entry ──────────────────────────────────────────────────────

def draft_entry(doc: dict, pid: Optional[int]) -> list[str]:
    lines = ["## Draft registry entry", ""]
    if pid is None or pid == 0:
        lines += ["_no usable PID — cannot draft an entry_", ""]
        return lines

    fields = descriptor_fields(doc)
    x = find_axis(fields, UP_GENERIC_DESKTOP, USAGE_X)
    y = find_axis(fields, UP_GENERIC_DESKTOP, USAGE_Y)
    p = find_axis(fields, UP_DIGITIZER, USAGE_TIP_PRESSURE)

    kernel = None
    try:
        kernel = rl.parse_kernel().get(pid)
    except FileNotFoundError:
        pass
    otd = None
    try:
        otd = rl.parse_otd().get(pid)
    except (FileNotFoundError, ValueError):
        pass

    warnings: list[str] = []

    def pick(desc_field, kernel_key, otd_key, label):
        # Precedence follows the project convention (see Extending-Support.md):
        # the Linux kernel is most authoritative, then OTD, and the device's own
        # descriptor last — many tablets also expose a low-resolution generic
        # digitizer whose declared ranges are nothing like the real ones.
        desc_val = desc_field.get("logicalMax") if desc_field else None
        chosen = None
        if kernel and kernel.get(kernel_key):
            chosen = kernel[kernel_key]
        elif otd and otd.get(otd_key):
            chosen = otd[otd_key]
        elif desc_val:
            chosen = desc_val
        else:
            chosen = 0
        # Flag the generic-digitizer-fallback signature so a reviewer doesn't
        # trust a descriptor number that upstream contradicts.
        if desc_val and chosen and abs(desc_val - chosen) > max(1, chosen * 0.1):
            warnings.append(
                f"{label}: descriptor says {desc_val} but upstream says {chosen} "
                f"— descriptor likely a generic-digitizer fallback; using {chosen}.")
        return chosen

    max_x = pick(x, "maxX", "maxX", "maxX")
    max_y = pick(y, "maxY", "maxY", "maxY")
    max_p = pick(p, "maxPressure", "maxP", "maxPressure")
    name = doc.get("deviceInfo", {}).get("name", "Unknown")
    captured = (doc.get("capturedAt") or "")[:10]

    for w in warnings:
        lines.append(f"- ⚠ {w}")
    if warnings:
        lines.append("")

    lines += [
        "```swift",
        "        .init(",
        f'            productID: 0x{pid:04X}, name: {rl.swift_string(name)},'
        f'  // ⚠ from submitted capture {captured}',
        f"            parser: .REVIEW, maxX: {max_x}, maxY: {max_y}, "
        f"maxPressure: {max_p},",
        "            buttonCount: 0, hasTouchRing: false, hasEraser: false,",
        "            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],",
        "            confidence: .reported),",
        "```",
        "",
        "`parser` is left as `.REVIEW` on purpose — the report inventory above "
        "suggests a family, but the decoder must be confirmed against real "
        "hardware. Fill in button count, touch, and eraser from the capture and "
        "the model's spec sheet. See `TabletKit/Extending-Support.md`.",
        "",
    ]
    return lines


# ── Report assembly ───────────────────────────────────────────────────────────

def build_report(doc: dict, path: Path, do_upstream: bool) -> str:
    kind = classify(doc)
    dev = doc.get("deviceInfo", {})
    vid = parse_hex_id(dev.get("vendorID"))
    pid = parse_hex_id(dev.get("productID"))
    problems = validate(doc, kind)

    lines = [
        f"# Capture triage — {dev.get('name', '(unnamed)')}",
        "",
        f"- File: `{path.name}`",
        f"- Kind: **{kind}** (captureVersion {doc.get('captureVersion', '?')})",
        f"- VID/PID: `{dev.get('vendorID')}` / `{dev.get('productID')}`",
        f"- Transport: {dev.get('transport', 'unknown')}",
        "",
        "## Validation",
        "",
    ]
    if problems:
        lines += [f"- ⚠ {p}" for p in problems] + [""]
    else:
        lines += ["- ✓ no problems found", ""]

    # Identity vs our own registries.
    lines += ["## Identity", ""]
    if pid is not None:
        wac = rl.resolve_spec(rl.parse_registry(), pid) if vid == rl.WACOM_VID else None
        if wac:
            lines.append(f"- Already in the Wacom registry as **{wac['name']}** "
                         f"(line {wac['line']}, confidence `{wac['confidence']}`). "
                         f"This capture may confirm or correct it.")
        elif vid == rl.WACOM_VID:
            lines.append("- Wacom VID, **not** in the registry — a genuine new "
                         "entry candidate.")
        else:
            lines.append(f"- Non-Wacom VID `0x{vid:04X}` — check "
                         "`VendorDeviceRegistry` for recognition-only coverage; "
                         "decoding a new vendor is a larger effort than a "
                         "registry entry.")
    lines.append("")

    lines += descriptor_section(doc)
    lines += report_inventory(doc, kind)
    lines += byte_ranges_section(doc, kind)
    lines += discriminated_byte_ranges_section(doc, kind)
    lines += tool_codes_section(doc)
    if do_upstream:
        lines += upstream_section(pid)
    lines += draft_entry(doc, pid)
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", type=Path, help="path to a capture JSON file")
    ap.add_argument("--no-upstream", action="store_true",
                    help="skip the kernel/OTD cross-reference")
    args = ap.parse_args()

    try:
        doc = load(args.capture)
        report = build_report(doc, args.capture, do_upstream=not args.no_upstream)
    except TriageError as e:
        print(f"triage failed: {e}", file=sys.stderr)
        return 2

    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
