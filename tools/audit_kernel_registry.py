#!/usr/bin/env python3
"""Audit WacomDeviceRegistry against the input-wacom kernel device table.

Reports four things:
  1. PIDs in the kernel's USB/BT device table with no registry entry and no
     canonicalPIDMap key (candidates for new entries).
  2. Dimensioned registry entries whose maxX/maxY/maxPressure disagree with
     the kernel feature struct for the same PID (estimation drift).
  3. Duplicate productIDs inside the registry that are not disambiguated by
     productStringMatch.
  4. Entries whose coordinate range and physical dimensions imply wildly
     different per-axis LPI (informational — old hardware really is
     anisotropic; only gross disagreement suggests a data error).

Known acceptable findings (do not "fix" without thought):
  - ISDv4/ISDv5 PIDs are built-in tablet-PC digitizers; skipped deliberately.
  - 0x00D0 (CTT-460) pressure 0 is intentional: touch-only device.
  - 0x0100 is a kernel PID collision (ISDv4 100 vs modern CTC-4110WL).
  - Graphire/Volito-era entries sit around 10% X-vs-Y LPI disagreement.  That
    is real: those tablets have genuinely different per-axis resolution.

Usage:
    python3 tools/audit_kernel_registry.py \
        [path/to/wacom_wac.c] [path/to/WacomDeviceRegistry.swift]

Both default to the standard in-repo layout (see registry_lib).
"""

import collections
import re
import sys
from pathlib import Path

import registry_lib as rl

DEFAULT_KERNEL = rl.DEFAULT_KERNEL
DEFAULT_REGISTRY = rl.DEFAULT_REGISTRY

#: Beyond this, per-axis LPI disagreement is a data error rather than genuine
#: hardware anisotropy.  The tighter rl.LPI_TOLERANCE is the auto-fill guard;
#: this is the "something is clearly wrong" line.
GROSS_LPI_DISAGREEMENT = 0.25

# Documented intentional disagreements with the kernel.
KERNEL_DRIFT_EXEMPT = (0x00D0, 0x0100)


def main() -> int:
    kernel_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_KERNEL
    registry_path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_REGISTRY

    src = kernel_path.read_text(encoding="utf-8", errors="ignore")
    entries = rl.parse_registry(registry_path)
    reg_text = Path(registry_path).read_text(encoding="utf-8", errors="ignore")

    kernel_pids = {
        int(m, 16)
        for m in re.findall(r"(?:USB|BT)_DEVICE_WACOM\(0x([0-9A-Fa-f]+)\)", src)
    }
    kernel = rl.parse_kernel(kernel_path)
    # Names come from a looser pattern than parse_kernel's — touch-only entries
    # declare a name but no dimensions, and they matter for the coverage list.
    feature_names = {
        int(m.group(1), 16): m.group(2)
        for m in re.finditer(r'wacom_features_0x([0-9A-Fa-f]+) =[^{]*\{ "([^"]+)"', src)
    }

    reg_pids = {e["pid"] for e in entries}
    canon_keys = {
        int(m, 16)
        for m in re.findall(r"0x([0-9A-Fa-f]+): 0x[0-9A-Fa-f]+,", reg_text)
    }

    failures = 0

    # ── 1. Duplicate PIDs ────────────────────────────────────────────────────
    # Several entries may share a PID only when productStringMatch tells them
    # apart, with at most one catch-all (nil) among them — the precedence
    # spec(forProductID:productString:) implements.
    dupes = []
    for pid, group in rl.registry_by_pid(entries).items():
        if len(group) < 2:
            continue
        catch_alls = [e for e in group if e["productStringMatch"] is None]
        named = [e["productStringMatch"] for e in group if e["productStringMatch"]]
        if len(catch_alls) > 1 or len(named) != len(set(named)):
            dupes.append((pid, group))
    if dupes:
        failures += 1
        print(f"DUPLICATE registry PIDs: {[hex(p) for p, _ in dupes]}")
        for pid, group in dupes:
            for e in group:
                print(f"    0x{pid:04X} line {e['line']:5d}  {e['name']!r} "
                      f"(productStringMatch={e['productStringMatch']!r})")

    # ── 2. Kernel PIDs we don't cover ────────────────────────────────────────
    missing = sorted(kernel_pids - reg_pids - canon_keys)
    interesting = [
        p for p in missing
        if "ISDv4" not in feature_names.get(p, "ISDv4")
        and "ISDv5" not in feature_names.get(p, "")
    ]
    print(f"kernel PIDs without registry coverage: {len(missing)} "
          f"({len(interesting)} non-ISDv4/v5)")
    for pid in interesting:
        print(f"  0x{pid:04X}  {feature_names.get(pid, '(no feature struct)')}")
    if interesting:
        failures += 1

    # ── 3. Dimension drift vs kernel ─────────────────────────────────────────
    drift = 0
    for e in entries:
        pid = e["pid"]
        k = kernel.get(pid)
        if not k or pid in KERNEL_DRIFT_EXEMPT:
            continue
        ours = (e["maxX"] or 0, e["maxY"] or 0, e["maxPressure"] or 0)
        theirs = (k["maxX"], k["maxY"], k["maxPressure"])
        if ours[0] > 0 and ours != theirs:
            drift += 1
            print(f"  drift 0x{pid:04X} {e['name']}: ours {ours} vs kernel {theirs}")
    print(f"dimensioned drift vs kernel: {drift}")
    if drift:
        failures += 1

    # ── 4. Gross per-axis LPI disagreement ───────────────────────────────────
    gross = []
    for e in entries:
        d = rl.lpi_disagreement(e)
        if d is not None and d > GROSS_LPI_DISAGREEMENT:
            gross.append((e, d))
    print(f"gross LPI disagreement (>{GROSS_LPI_DISAGREEMENT:.0%}): {len(gross)}")
    for e, d in gross:
        print(f"  0x{e['pid']:04X} {e['name']}: {d:.0%} "
              f"({e['maxX']}/{e['activeWidthMM']}mm vs "
              f"{e['maxY']}/{e['activeHeightMM']}mm)")
    if gross:
        failures += 1

    print("OK" if failures == 0 else f"{failures} finding categories")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
