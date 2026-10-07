#!/usr/bin/env python3
"""Rebuild corpus.json from local captures (Notes/Scratch, untracked) and
public recordings cloned under Notes/Scratch/upstream: bentiss/hid-devices
and the kernel's HID selftests. Descriptors from linuxwacom/wacom-hid-descriptors
go to corpus-linuxwacom.json, which keeps that database's ODbL license.

Keeps only what routing reads: each interface's top-level collections, per
product ID and transport. No reports, serials, or submitter details.

Usage (from the repo root): tools/tests/interface-routing-tests/build-corpus.py
"""
import json, os, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRATCH = ROOT / "Notes" / "Scratch"
OUT = Path(__file__).with_name("corpus.json")
WACOM_VIDS = {"0x056A", "0x0531"}
REGISTRY = ROOT / "TabletKit" / "registry.json"

# Touch sensor PID → its pen display's PID, from the registry's "(pairs 0x…)"
# names. A sensor's capture may carry the display's interfaces too.
_reg = json.load(open(REGISTRY))
_rows = _reg if isinstance(_reg, list) else _reg["devices"]
PAIRED = {}
for r in _rows:
    if "(pairs 0x" in r["name"]:
        pid = r["productID"] if isinstance(r["productID"], str) else f"0x{r['productID']:04X}"
        PAIRED[pid.upper().replace("0X", "0x")] = "0x" + r["name"].split("(pairs 0x")[1][:4].upper()


def items(raw):
    b = bytes.fromhex(raw)
    i = 0
    while i < len(b):
        h = b[i]
        if h == 0xFE:  # long item
            i += 3 + b[i + 1]
            continue
        n = (0, 1, 2, 4)[h & 3]
        yield h & 0xFC, int.from_bytes(b[i + 1:i + 1 + n], "little"), n
        i += 1 + n


def top_level_collections(raw):
    """(page, usage) of each top-level collection, as IOKit's usage pairs."""
    page, usages, depth, out = 0, [], 0, []
    for tag, v, n in items(raw):
        if tag == 0x04:
            page = v
        elif tag == 0x08:
            usages.append((v >> 16, v & 0xFFFF) if n == 4 else (page, v))
        elif tag == 0xA0:
            if depth == 0 and usages:
                out.append(list(usages[0]))
            depth += 1
            usages = []
        elif tag == 0xC0:
            depth -= 1
        elif tag in (0x80, 0x90, 0xB0):
            usages = []
    return out


def captures():
    for dirpath, _, files in os.walk(SCRATCH):
        if "upstream" in dirpath:
            continue
        for f in files:
            p = Path(dirpath) / f
            try:
                if f.endswith(".zip"):
                    z = zipfile.ZipFile(p)
                    for n in z.namelist():
                        if n.endswith("summary.json") and "/._" not in n:
                            yield json.loads(z.read(n))
                elif f.endswith(".json"):
                    d = json.load(open(p))
                    if isinstance(d, dict) and "deviceInfo" in d:
                        yield d
            except (ValueError, OSError, zipfile.BadZipFile):
                pass


devices = {}
for d in captures():
    info = d["deviceInfo"]
    if info.get("vendorID") not in WACOM_VIDS:
        continue
    pid, transport = info.get("productID"), info.get("transport", "USB")
    # Whole-desk diagnostics list other devices too; keep this one's own.
    own = {pid, PAIRED.get(pid)} - {None}
    ifs = [i for i in d.get("interfaces") or [] if i.get("productID") in own]
    if not ifs and d.get("hidReportDescriptor"):
        ifs = [{"hidReportDescriptor": d["hidReportDescriptor"], "productID": pid}]
    for i in ifs:
        raw = (i.get("hidReportDescriptor") or {}).get("rawHex")
        tops = top_level_collections(raw) if raw else []
        if tops:
            key = (i.get("productID", pid), transport)
            devices.setdefault(key, set()).add(json.dumps(tops))

# hid-recorder files: "D:n" starts a device, "I: bus vid pid", "R: len bytes".
BUS = {"3": "USB", "5": "Bluetooth"}
for p in (SCRATCH / "upstream" / "hid-devices").rglob("*.hid"):
    dev = {}
    for line in p.read_text(errors="replace").splitlines():
        if line.startswith("D:"):
            dev = {}
        elif line.startswith("I:"):
            bus, vid, pid = line[2:].split()[:3]
            dev.update(vid="0x" + vid.upper().zfill(4), pid="0x" + pid.upper().zfill(4),
                       transport=BUS.get(bus.lstrip("0") or "0", "other"))
        elif line.startswith("R:"):
            dev["raw"] = "".join(line[2:].split()[1:])
        if {"vid", "raw"} <= dev.keys() and dev["vid"] in WACOM_VIDS:
            tops = top_level_collections(dev.pop("raw"))
            if tops:
                devices.setdefault((dev["pid"], dev["transport"]), set()).add(json.dumps(tops))

# Kernel selftests: {"rdesc": name, "info": (bus, vid, pid)} plus rdesc strings.
selftest = SCRATCH / "upstream" / "linux-hid-selftests" / "test_wacom_generic.py"
if selftest.exists():
    import re
    src = selftest.read_text()
    named = dict(re.findall(r'^(\w+) = \(?\s*"([0-9a-fA-F ]+)"', src, re.M))
    for name, bus, vid, pid in re.findall(
            r'"rdesc": (\w+), "info": \((0x\w+), (0x\w+), (0x\w+)\)', src):
        if name in named and vid.upper() == "0X056A":
            tops = top_level_collections(named[name].replace(" ", ""))
            key = ("0x" + pid[2:].upper().zfill(4), BUS.get(str(int(bus, 16)), "other"))
            devices.setdefault(key, set()).add(json.dumps(tops))

def write(devs, out):
    corpus = [
        {"productID": pid, "transport": t,
         "interfaces": sorted(json.loads(x) for x in ifs)}
        for (pid, t), ifs in sorted(devs.items())
    ]
    out.write_text(json.dumps(corpus, indent=1) + "\n")
    print(f"Wrote {len(corpus)} devices to {out.name}")


write(devices, OUT)

# linuxwacom sysinfo dumps: one "bus:vid:pid.instance.hid.bin" per interface.
import re
LW = SCRATCH / "upstream" / "wacom-hid-descriptors"
lw = {}
for p in LW.rglob("*.hid.bin"):
    m = re.fullmatch(r"([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})\.[0-9A-Fa-f]+\.hid\.bin", p.name)
    if not m or "0x" + m.group(2).upper() not in WACOM_VIDS:
        continue
    tops = top_level_collections(p.read_bytes().hex())
    if tops:
        key = ("0x" + m.group(3).upper(), BUS.get(m.group(1).lstrip("0"), "other"))
        lw.setdefault(key, set()).add(json.dumps(tops))
write(lw, OUT.with_name("corpus-linuxwacom.json"))
