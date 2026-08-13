#!/usr/bin/env python3
"""backfill_libwacom_dimensions.py — fill activeWidthMM/Height from libwacom

Reads every Wacom-branded `.tablet` file from a local libwacom checkout, builds
a {PID → (widthMM, heightMM, modelName)} map, then walks
TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift and inserts `activeWidthMM` /
`activeHeightMM` arguments into entries that don't already have them.

libwacom Width/Height are **manufacturer-advertised drawing-area dimensions
in millimetres**, confirmed via the `wacom.example` file ("Width in mm, as
advertised by the manufacturer ... drawing area, not the full tablet").
They are typically within 1–3% of the precise active-area dimensions we
hand-measure for `.verified` entries — close enough to drive the `lpi`
accessor's cursor-mapping logic, but slightly less precise than a live
capture.  We therefore:

  • never overwrite entries that already declare `activeWidthMM`,
  • leave the existing 6 hand-measured `.verified` entries untouched,
  • clearly mark new entries (via the script's commit message) as
    libwacom-advertised rather than hand-measured.

Usage:
    python3 tools/registry/backfill_libwacom_dimensions.py \\
        --libwacom-data /path/to/libwacom/data \\
        --registry TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift
    python3 tools/registry/backfill_libwacom_dimensions.py ... --dry-run   # preview only
"""

import argparse
import re
import sys
from pathlib import Path

WACOM_VID = 0x056A


def parse_tablet_file(path: Path) -> tuple[list[int], float | None, float | None, str]:
    """Return (pid_list, widthMM, heightMM, modelName) from a .tablet file."""
    pids: list[int] = []
    width = height = None
    model = ""
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line.startswith("Width="):
            try:
                width = float(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("Height="):
            try:
                height = float(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("ModelName="):
            model = line.split("=", 1)[1].strip()
        elif line.startswith("DeviceMatch="):
            # DeviceMatch=usb|056a|0317;bluetooth|056a|0360;
            for tok in line.split("=", 1)[1].split(";"):
                tok = tok.strip()
                if not tok:
                    continue
                parts = tok.split("|")
                # usb|056a|0317  or  bluetooth|056a|0360  or  usb|056a|0357|Wacom Intuos
                if len(parts) >= 3 and parts[0] in ("usb", "bluetooth"):
                    try:
                        vid = int(parts[1], 16)
                        pid = int(parts[2], 16)
                        if vid == WACOM_VID and pid not in pids:
                            pids.append(pid)
                    except ValueError:
                        pass
    return pids, width, height, model


def build_libwacom_map(data_dir: Path) -> dict[int, tuple[float, float, str, str]]:
    """{pid: (widthMM, heightMM, modelName, source_filename)} for all Wacom devices.

    When multiple files cover the same PID (transport variants, alt PIDs),
    later files win — libwacom convention keeps the more-specific match late.
    """
    out: dict[int, tuple[float, float, str, str]] = {}
    for path in sorted(data_dir.glob("wacom-*.tablet")):
        pids, w, h, model = parse_tablet_file(path)
        if w is None or h is None:
            continue
        for pid in pids:
            out[pid] = (w, h, model, path.name)
    return out


# Match `.init(` … balanced `)` blocks.  Greedy/state-machine approach.
INIT_OPEN = re.compile(r"^\s*\.init\(\s*$")
PID_LINE = re.compile(r"productID:\s*0x([0-9A-Fa-f]+)")
HAS_DIM = re.compile(r"\bactiveWidthMM:")
MAX_X = re.compile(r"\bmaxX:\s*(\d+)")
MAX_Y = re.compile(r"\bmaxY:\s*(\d+)")

# Reject the libwacom dimensions if the implied LPI on the two axes
# disagrees by more than this much.  Wacom publishes 5080 LPI nominal
# and real devices vary ±4% between axes; 8% leaves headroom for
# normal variance while catching outright wrong-device matches
# (PID collisions across product lines).
LPI_AXIS_DISAGREEMENT_THRESHOLD = 0.08


def find_init_blocks(lines: list[str]) -> list[tuple[int, int]]:
    """Return list of (start_idx, end_idx_inclusive) for each `.init(...)` block."""
    blocks = []
    i = 0
    while i < len(lines):
        if INIT_OPEN.match(lines[i]):
            depth = 1
            j = i + 1
            while j < len(lines) and depth > 0:
                # Count parens conservatively; the registry doesn't put a
                # bare `(` inside an entry except via balanced sub-exprs
                # (initSteps [.featureReport([0x02, 0x02])]).  Counting
                # all `(` vs `)` across the whole line handles it.
                depth += lines[j].count("(") - lines[j].count(")")
                if depth <= 0:
                    blocks.append((i, j))
                    i = j
                    break
                j += 1
        i += 1
    return blocks


def patch_block(
    lines: list[str], start: int, end: int,
    libwacom: dict[int, tuple[float, float, str, str]]
) -> tuple[bool, str | None]:
    """Inject activeWidthMM/Height into the block.  Returns (changed, reason_skipped)."""
    block = lines[start:end + 1]
    pid_match = None
    max_x: int | None = None
    max_y: int | None = None
    for line in block:
        if pid_match is None:
            m = PID_LINE.search(line)
            if m:
                pid_match = int(m.group(1), 16)
        if max_x is None:
            m = MAX_X.search(line)
            if m:
                max_x = int(m.group(1))
        if max_y is None:
            m = MAX_Y.search(line)
            if m:
                max_y = int(m.group(1))
    if pid_match is None:
        return False, "no productID"

    # Already has dimensions? leave alone.
    if any(HAS_DIM.search(l) for l in block):
        return False, "already has activeWidthMM"

    if pid_match not in libwacom:
        return False, f"PID 0x{pid_match:04X} not in libwacom"

    w, h, model, src = libwacom[pid_match]

    # LPI consistency guard: if our maxX/maxY don't imply roughly the
    # same DPI on both axes when divided by libwacom's mm, our entry
    # and libwacom's entry are probably describing different devices
    # that happen to share a PID (Wacom does reuse PIDs across
    # product lines).  Skip with a loud warning so the human reviewing
    # the dry-run output can investigate.
    if max_x is not None and max_y is not None and w > 0 and h > 0:
        lpi_x = max_x / w * 25.4
        lpi_y = max_y / h * 25.4
        avg = (lpi_x + lpi_y) / 2
        if avg > 0:
            disagreement = abs(lpi_x - lpi_y) / avg
            if disagreement > LPI_AXIS_DISAGREEMENT_THRESHOLD:
                return False, (
                    f"LPI mismatch PID 0x{pid_match:04X}: "
                    f"X={lpi_x:.0f} Y={lpi_y:.0f} ({disagreement * 100:.1f}%) "
                    f"— our entry and {src} likely describe different devices"
                )

    # Insert just before the closing `)` on the last line of the block.
    last = lines[end]
    # Strategy: find the last `)` on the line and insert `, activeWidthMM: …` before it.
    last_paren = last.rfind(")")
    if last_paren < 0:
        return False, "no closing paren on final line"

    # Pick indentation: match the leading whitespace + 4 extra spaces aren't
    # needed — single line insert is what every other dim entry uses.  But
    # we keep the dimensions on the same line as the closing `)` to mirror
    # the existing convention (`activeWidthMM: X, activeHeightMM: Y),`).
    def fmt(x: float) -> str:
        # Drop trailing ".0" so "270.0" becomes "270".
        s = f"{x:g}"
        return s

    insert = f", activeWidthMM: {fmt(w)}, activeHeightMM: {fmt(h)}"
    lines[end] = last[:last_paren] + insert + last[last_paren:]
    return True, f"PID 0x{pid_match:04X}: {fmt(w)} × {fmt(h)} mm ({src})"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--libwacom-data", required=True, type=Path,
                    help="Path to libwacom data/ directory (e.g. ~/Documents/Develop/libwacom/data)")
    ap.add_argument("--registry", required=True, type=Path,
                    help="Path to TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print proposed changes without writing the file")
    args = ap.parse_args()

    if not args.libwacom_data.is_dir():
        print(f"error: libwacom data dir not found: {args.libwacom_data}", file=sys.stderr)
        return 1
    if not args.registry.is_file():
        print(f"error: registry file not found: {args.registry}", file=sys.stderr)
        return 1

    libwacom = build_libwacom_map(args.libwacom_data)
    print(f"# libwacom map: {len(libwacom)} Wacom PIDs covered", file=sys.stderr)

    lines = args.registry.read_text(encoding="utf-8").splitlines(keepends=True)
    # splitlines(keepends=True) preserves \n; but we need plain strings for indexing.
    # Easier: split without keepends, then re-join with \n.
    raw = args.registry.read_text(encoding="utf-8")
    lines = raw.split("\n")

    blocks = find_init_blocks(lines)
    print(f"# found {len(blocks)} .init(...) blocks in registry", file=sys.stderr)

    changed_blocks = 0
    skipped_no_pid = 0
    skipped_already = 0
    skipped_no_libwacom = 0
    skipped_lpi = 0
    for start, end in blocks:
        ok, reason = patch_block(lines, start, end, libwacom)
        if ok:
            changed_blocks += 1
            print(f"  + {reason}", file=sys.stderr)
        else:
            if reason and reason.startswith("already"):
                skipped_already += 1
            elif reason and reason.startswith("PID 0x"):
                skipped_no_libwacom += 1
            elif reason and reason.startswith("LPI mismatch"):
                print(f"  ! SKIP: {reason}", file=sys.stderr)
                skipped_lpi += 1
            else:
                skipped_no_pid += 1

    print(f"# proposed updates: {changed_blocks} entries", file=sys.stderr)
    print(f"# skipped (already filled): {skipped_already}", file=sys.stderr)
    print(f"# skipped (PID not in libwacom): {skipped_no_libwacom}", file=sys.stderr)
    print(f"# skipped (LPI sanity mismatch): {skipped_lpi}", file=sys.stderr)
    print(f"# skipped (no productID found): {skipped_no_pid}", file=sys.stderr)

    if args.dry_run:
        print("# dry-run: no file written", file=sys.stderr)
        return 0

    args.registry.write_text("\n".join(lines), encoding="utf-8")
    print(f"# wrote {args.registry}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
