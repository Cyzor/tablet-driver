#!/usr/bin/env python3
"""audit_wacom_hid_descriptors.py — cross-reference registry against linuxwacom

Walks the `linuxwacom/wacom-hid-descriptors` GitHub repository, extracts the
USB VID/PID for each Wacom-branded device from its sysinfo dump filenames
(which encode the IDs as `BUS:VID:PID.NNNN.hid.txt`), and cross-references
against MockTab/Driver/WacomDeviceRegistry.swift.

Produces a Markdown audit table for Notes/Scratch/ — promotable entries,
missing entries, and naming discrepancies.  Run via `gh` (no auth needed
for the public repo).

Usage:
    python3 tools/audit_wacom_hid_descriptors.py \\
        --registry MockTab/Driver/WacomDeviceRegistry.swift \\
        > Notes/Scratch/Wacom-Descriptor-Audit-$(date +%Y-%m-%d).md
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = "linuxwacom/wacom-hid-descriptors"
WACOM_VID_HEX = "056A"

PID_LINE = re.compile(r"productID:\s*0x([0-9A-Fa-f]+)")
NAME_LINE = re.compile(r'name:\s*"([^"]+)"')
CONFIDENCE_LINE = re.compile(r"\bconfidence:\s*\.(\w+)")
INIT_OPEN = re.compile(r"^\s*\.init\(\s*$")


def gh(*args: str) -> str:
    """Run a `gh` subcommand and return stdout."""
    r = subprocess.run(["gh", "api"] + list(args),
                       capture_output=True, text=True, check=False)
    if r.returncode != 0:
        sys.stderr.write(f"gh api {' '.join(args)} -> exit {r.returncode}: {r.stderr}\n")
        return ""
    return r.stdout


def list_wacom_devices() -> list[str]:
    """Top-level device folders whose name starts with Wacom/Cintiq/Intuos/Movink/Bamboo."""
    raw = gh(f"repos/{REPO}/contents")
    if not raw:
        return []
    entries = json.loads(raw)
    keywords = ("Wacom", "Cintiq", "Intuos", "Movink", "Bamboo")
    return sorted(
        e["name"] for e in entries
        if e["type"] == "dir" and any(k in e["name"] for k in keywords)
    )


def pids_for_device(folder: str) -> set[int]:
    """Scrape PIDs from sysinfo filenames inside a device folder."""
    # The device folder contains 0+ sysinfo.XXXX subfolders.
    raw = gh(f"repos/{REPO}/contents/{folder}")
    if not raw:
        return set()
    pids: set[int] = set()
    for entry in json.loads(raw):
        if entry["type"] != "dir" or not entry["name"].startswith("sysinfo."):
            continue
        sub_raw = gh(f"repos/{REPO}/contents/{folder}/{entry['name']}")
        if not sub_raw:
            continue
        for f in json.loads(sub_raw):
            # filename pattern: BUS:VID:PID.NNNN.hid.bin/txt/xml
            m = re.match(r"([0-9A-Fa-f]+):([0-9A-Fa-f]+):([0-9A-Fa-f]+)", f["name"])
            if m:
                vid = m.group(2).upper()
                if vid == WACOM_VID_HEX:
                    pids.add(int(m.group(3), 16))
    return pids


def parse_registry(path: Path) -> dict[int, dict]:
    """Return {pid: {name, confidence, has_dims}} for every .init block."""
    lines = path.read_text(encoding="utf-8").split("\n")
    out: dict[int, dict] = {}
    i = 0
    while i < len(lines):
        if INIT_OPEN.match(lines[i]):
            depth = 1
            block = [lines[i]]
            j = i + 1
            while j < len(lines) and depth > 0:
                block.append(lines[j])
                depth += lines[j].count("(") - lines[j].count(")")
                j += 1
            block_text = "\n".join(block)
            pid_m = PID_LINE.search(block_text)
            name_m = NAME_LINE.search(block_text)
            conf_m = CONFIDENCE_LINE.search(block_text)
            if pid_m:
                out[int(pid_m.group(1), 16)] = {
                    "name": name_m.group(1) if name_m else "",
                    "confidence": conf_m.group(1) if conf_m else "experimental",
                    "has_dims": "activeWidthMM" in block_text,
                }
            i = j
        else:
            i += 1
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry", required=True, type=Path)
    args = ap.parse_args()

    sys.stderr.write("# scanning wacom-hid-descriptors device folders…\n")
    devices = list_wacom_devices()
    sys.stderr.write(f"# found {len(devices)} Wacom-branded folders\n")

    desc_pids: dict[int, str] = {}  # pid -> device-folder name (first wins)
    for folder in devices:
        sys.stderr.write(f"#   {folder} ")
        sys.stderr.flush()
        pids = pids_for_device(folder)
        sys.stderr.write(f"-> PIDs {', '.join(f'0x{p:04X}' for p in sorted(pids))}\n")
        for pid in pids:
            desc_pids.setdefault(pid, folder)

    reg = parse_registry(args.registry)
    sys.stderr.write(f"# registry: {len(reg)} entries with productID\n")

    # Build categorised lists.
    confirmed: list[tuple[int, str, str, str]] = []
    promotable: list[tuple[int, str, str]] = []
    missing: list[tuple[int, str]] = []
    name_drift: list[tuple[int, str, str]] = []

    for pid, folder in sorted(desc_pids.items()):
        if pid not in reg:
            missing.append((pid, folder))
            continue
        entry = reg[pid]
        if entry["confidence"] == "verified":
            confirmed.append((pid, entry["name"], folder, "verified"))
            continue
        # Light naming heuristic: do they share at least one significant token?
        toks = lambda s: set(re.findall(r"[A-Za-z0-9-]{3,}", s.replace("Wacom", "")))
        if toks(entry["name"]) & toks(folder):
            promotable.append((pid, entry["name"], folder))
        else:
            name_drift.append((pid, entry["name"], folder))

    # Emit Markdown.
    print(f"# Wacom registry audit against linuxwacom/wacom-hid-descriptors")
    print()
    print(f"Source: https://github.com/{REPO}  ({len(devices)} Wacom-branded device folders)")
    print(f"Registry: `{args.registry}`")
    print()
    print(f"- Confirmed matches: **{len(confirmed)}**")
    print(f"- Promotable (experimental→crossReferenced candidates): **{len(promotable)}**")
    print(f"- Naming discrepancies: **{len(name_drift)}**")
    print(f"- Missing in registry: **{len(missing)}**")
    print()
    print("## Promotable")
    print()
    print("These entries have PIDs that appear in real sysinfo dumps from")
    print("linuxwacom and whose names share at least one significant token")
    print("with the device folder.  Safe candidates for `.experimental` →")
    print("`.crossReferenced` promotion after a spot-check of the relevant")
    print("`.hid.txt` to confirm `maxX`/`maxY`/`maxPressure` agree.")
    print()
    print("| PID | Our name | wacom-hid-descriptors folder |")
    print("|---|---|---|")
    for pid, our, folder in promotable:
        print(f"| `0x{pid:04X}` | {our} | {folder} |")
    print()
    print("## Naming discrepancies")
    print()
    print("PIDs present in both places but with names that share no tokens —")
    print("either a PID collision (same PID, different products across")
    print("Wacom's lineup) or a stale/wrong name in our registry.  Each one")
    print("needs human review against the `.hid.txt` before any action.")
    print()
    print("| PID | Our name | wacom-hid-descriptors folder |")
    print("|---|---|---|")
    for pid, our, folder in name_drift:
        print(f"| `0x{pid:04X}` | {our} | {folder} |")
    print()
    print("## Missing in registry")
    print()
    print("PIDs that have real sysinfo dumps in linuxwacom but no entry in")
    print("our registry — devices the app would fall through on today.")
    print()
    print("| PID | wacom-hid-descriptors folder |")
    print("|---|---|")
    for pid, folder in missing:
        print(f"| `0x{pid:04X}` | {folder} |")
    print()
    print("## Already verified")
    print()
    print("Confirmed against real hardware in this project — no action needed.")
    print()
    print("| PID | Our name | wacom-hid-descriptors folder |")
    print("|---|---|---|")
    for pid, our, folder, _ in confirmed:
        print(f"| `0x{pid:04X}` | {our} | {folder} |")

    return 0


if __name__ == "__main__":
    sys.exit(main())
