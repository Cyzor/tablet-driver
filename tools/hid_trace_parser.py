#!/usr/bin/env python3
"""Parses `hid-recorder` trace files (`.hid`).

Reads traces the caller supplies; none ship with this repo.

Format:
  D: n        - selects the active interface index for subsequent R:/E: lines
  R: len ...  - raw HID report descriptor bytes for the interface named by
                the most recent D: line (len includes itself in some dumps;
                we don't rely on it, we just keep the byte list)
  N: ...      - device name string (informational)
  P: ...      - sysfs path (informational)
  I: bus vid pid - bus/vendor/product for the interface
  E: t b0 b1 ... - one captured report at time t; b0 is the HID report ID,
                remaining bytes are the report payload as delivered to
                hidraw. Belongs to whichever interface the last D: selected.

Critically: report IDs are scoped PER INTERFACE, not global. The same
report ID byte on interface 0 and interface 1 can mean unrelated things.
This parser keeps every interface's events strictly separate.
"""
import argparse
import sys
from collections import defaultdict


def parse_trace(text: str):
    """Returns a dict: interface_index -> {
        'descriptor': [int, ...] or None,
        'name': str or None,
        'path': str or None,
        'ident': (bus, vid, pid) or None,
        'reports': {report_id: [ [timestamp, [bytes...]], ... ]}
    }
    """
    interfaces = defaultdict(lambda: {
        "descriptor": None, "name": None, "path": None,
        "ident": None, "reports": defaultdict(list),
    })
    # Newer hid-recorder output omits D: entirely for single-interface
    # devices — R:/N:/I:/E: just apply to interface 0 with no selector line
    # at all. Default to 0 rather than requiring D: first; a real D: line
    # (multi-interface dumps) still overrides it as soon as one appears.
    current = 0

    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.rstrip("\n")
        if not line:
            continue
        # Some dumps write "D:0", others "R: 98 ..." — colon spacing isn't
        # consistent, so split on the bare colon and strip separately.
        tag, _, rest = line.partition(":")
        rest = rest.strip()

        if tag == "D":
            current = int(rest)
        elif tag == "R":
            parts = [int(x, 16) for x in rest.split()]
            # First token is the dump's own descriptor-length field; the
            # remaining tokens are the actual descriptor bytes.
            interfaces[current]["descriptor"] = parts[1:]
        elif tag == "N":
            interfaces[current]["name"] = rest
        elif tag == "P":
            interfaces[current]["path"] = rest
        elif tag == "I":
            bus, vid, pid = rest.split()
            interfaces[current]["ident"] = (bus, vid, int(pid, 16))
        elif tag == "E":
            fields = rest.split()
            timestamp = float(fields[0])
            # The dump prefixes the byte list with its own length count;
            # the actual report starts at fields[2] (fields[1] is that count).
            report_bytes = [int(x, 16) for x in fields[2:]]
            if not report_bytes:
                continue
            report_id = report_bytes[0]
            interfaces[current]["reports"][report_id].append(
                (timestamp, report_bytes))
        # Unknown tags (e.g. "S:", "#": comments) are ignored.

    return interfaces


def summarize(interfaces):
    for idx in sorted(interfaces):
        iface = interfaces[idx]
        ident = iface["ident"]
        ident_str = f"{ident[0]}:{ident[1]}:{ident[2]:04x}" if ident else "?"
        print(f"=== interface D:{idx}  [{ident_str}]  {iface['name'] or ''}")
        desc = iface["descriptor"]
        print(f"    descriptor: {len(desc) if desc else 0} bytes")
        for rid in sorted(iface["reports"]):
            events = iface["reports"][rid]
            lengths = sorted({len(b) for _, b in events})
            print(f"    report 0x{rid:02x}: {len(events)} events, "
                  f"length(s) {lengths}")


def export_json(interfaces, pid: int):
    """Merges every interface whose I: line matches `pid` into one
    chronologically-ordered event list, across all report IDs. Decoders
    self-filter on report[0]/length, so we don't need to guess which
    interface is "the pen one" — feeding everything and letting the decoder
    return [] for reports it doesn't recognize mirrors how IOHIDManager
    actually delivers reports in the real app.
    """
    import json as _json

    merged = []
    for idx in sorted(interfaces):
        iface = interfaces[idx]
        ident = iface["ident"]
        if not ident or ident[2] != pid:
            continue
        for rid, events in iface["reports"].items():
            for t, b in events:
                merged.append((t, idx, b))
    merged.sort(key=lambda e: e[0])
    return _json.dumps({
        "pid": pid,
        "events": [{"t": t, "interface": idx, "bytes": b}
                    for t, idx, b in merged],
    })


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("trace_file")
    ap.add_argument("--report-id", type=lambda s: int(s, 0),
                     help="dump raw events for this report ID only")
    ap.add_argument("--interface", type=int, default=None,
                     help="restrict --report-id dump to this D: index")
    ap.add_argument("--limit", type=int, default=20,
                     help="max events to print with --report-id")
    ap.add_argument("--export-json", type=lambda s: int(s, 0), metavar="PID",
                     help="merge all interfaces matching PID into one "
                          "chronological JSON event stream on stdout")
    args = ap.parse_args()

    with open(args.trace_file) as f:
        text = f.read()
    interfaces = parse_trace(text)

    if args.export_json is not None:
        print(export_json(interfaces, args.export_json))
        return

    if args.report_id is None:
        summarize(interfaces)
        return

    for idx in sorted(interfaces):
        if args.interface is not None and idx != args.interface:
            continue
        events = interfaces[idx]["reports"].get(args.report_id)
        if not events:
            continue
        print(f"--- D:{idx} report 0x{args.report_id:02x} "
              f"({len(events)} events, showing up to {args.limit}) ---")
        for t, b in events[:args.limit]:
            hexstr = " ".join(f"{x:02x}" for x in b)
            print(f"{t:12.6f}  {hexstr}")


if __name__ == "__main__":
    sys.exit(main())
