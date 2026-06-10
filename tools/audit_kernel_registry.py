#!/usr/bin/env python3
"""Audit WacomDeviceRegistry against the input-wacom kernel device table.

Reports three things:
  1. PIDs in the kernel's USB/BT device table with no registry entry and no
     canonicalPIDMap key (candidates for new entries).
  2. Dimensioned registry entries whose maxX/maxY/maxPressure disagree with
     the kernel feature struct for the same PID (estimation drift).
  3. Duplicate productIDs inside the registry.

Known acceptable findings (do not "fix" without thought):
  - ISDv4/ISDv5 PIDs are built-in tablet-PC digitizers; skipped deliberately.
  - 0x00D0 (CTT-460) pressure 0 is intentional: touch-only device.
  - 0x0100 is a kernel PID collision (ISDv4 100 vs modern CTC-4110WL).

Usage:
    python3 tools/audit_kernel_registry.py \
        [path/to/wacom_wac.c] [path/to/WacomDeviceRegistry.swift]

Defaults assume the standard layout: kernel source in
Notes/Scratch/upstream/input-wacom/4.18/wacom_wac.c and the registry in the
sibling mocktab-kit checkout.
"""

import collections
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_KERNEL = ROOT / "Notes/Scratch/upstream/input-wacom/4.18/wacom_wac.c"
DEFAULT_REGISTRY = (
    ROOT.parent / "mocktab-kit/Sources/TabletKit/WacomDeviceRegistry.swift"
)


def main() -> int:
    kernel_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_KERNEL
    registry_path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_REGISTRY
    src = kernel_path.read_text()
    reg = registry_path.read_text()

    kernel_pids = {
        int(m, 16)
        for m in re.findall(r"(?:USB|BT)_DEVICE_WACOM\(0x([0-9A-Fa-f]+)\)", src)
    }
    feature_names = {}
    feature_dims = {}
    for m in re.finditer(
        r'wacom_features_0x([0-9A-Fa-f]+) =[^{]*\{ "([^"]+)"'
        r"(?:,\s*(\d+),\s*(\d+),\s*(\d+),)?",
        src,
    ):
        pid = int(m.group(1), 16)
        feature_names[pid] = m.group(2)
        if m.group(3):
            feature_dims[pid] = (
                int(m.group(3)),
                int(m.group(4)),
                int(m.group(5)),
            )

    reg_pid_strings = re.findall(r"productID: 0x([0-9A-Fa-f]+),", reg)
    reg_pids = {int(p, 16) for p in reg_pid_strings}
    canon_keys = {
        int(m, 16) for m in re.findall(r"0x([0-9A-Fa-f]+): 0x[0-9A-Fa-f]+,", reg)
    }

    failures = 0

    dupes = [
        pid
        for pid, count in collections.Counter(
            int(p, 16) for p in reg_pid_strings
        ).items()
        if count > 1
    ]
    if dupes:
        failures += 1
        print(f"DUPLICATE registry PIDs: {[hex(d) for d in dupes]}")

    missing = sorted(kernel_pids - reg_pids - canon_keys)
    interesting = [
        p for p in missing if "ISDv4" not in feature_names.get(p, "ISDv4")
        and "ISDv5" not in feature_names.get(p, "")
    ]
    print(f"kernel PIDs without registry coverage: {len(missing)} "
          f"({len(interesting)} non-ISDv4/v5)")
    for pid in interesting:
        print(f"  0x{pid:04X}  {feature_names.get(pid, '(no feature struct)')}")
    if interesting:
        failures += 1

    drift = 0
    for m in re.finditer(
        r'productID: 0x([0-9A-Fa-f]+), name: "([^"]+)",\s*//[^\n]*\n'
        r"(?:\s*//[^\n]*\n)*"
        r"\s*parser: \.(\w+), maxX: (\d+), maxY: (\d+), maxPressure: (\d+)",
        reg,
    ):
        pid = int(m.group(1), 16)
        ours = (int(m.group(4)), int(m.group(5)), int(m.group(6)))
        if pid in feature_dims and ours[0] > 0 and feature_dims[pid] != ours:
            # Documented intentional disagreements.
            if pid in (0x00D0, 0x0100):
                continue
            drift += 1
            print(
                f"  drift 0x{pid:04X} {m.group(2)}: "
                f"ours {ours} vs kernel {feature_dims[pid]}"
            )
    print(f"dimensioned drift vs kernel: {drift}")
    if drift:
        failures += 1

    print("OK" if failures == 0 else f"{failures} finding categories")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
