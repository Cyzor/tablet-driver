#!/usr/bin/env python3
"""generate_tablet_layouts.py — write the control layouts MockTab draws tablets from

The Tablet Area pane draws each tablet from a kit of parts: a body, its active
surface, and the keys, rings, dials, and strips along its edges. TabletKit's
registry knows a model's size but not where its controls sit. libwacom's layout
SVGs do, so this script reads them and writes the simplified result into
MockTab/UI/Panes/TabletArea/TabletLayoutTable.swift.

Simplification happens here, not in the app:

  • A part's side is the canvas edge it sits nearest. libwacom's [Buttons]
    Left/Right lists aren't geometry (the PTK-870's keys sit along the top).
  • Keys in a straight line become a run; keys packed in two directions, like
    a four-way pad or a rocker, become one cluster.
  • Buttons inside a ring or dial, mode keys beside a ring, and direction dots
    are dropped; the ring or dial stands for them.
  • Parts at different depths that share a stretch of edge get their own lanes.

Only registry models with a layout are written. Everything else draws as a
plain body, which needs no data.

Usage (from the repo root):
    python3 tools/registry/generate_tablet_layouts.py --libwacom-data /path/to/libwacom/data
    python3 tools/registry/generate_tablet_layouts.py --libwacom-data ... --check

--check writes nothing and exits 1 if the table is out of date.
"""

from __future__ import annotations

import argparse
import configparser
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REGISTRY = ROOT / "TabletKit" / "registry.json"
DEFAULT_OUTPUT = ROOT / "MockTab" / "UI" / "Panes" / "TabletArea" / "TabletLayoutTable.swift"
WACOM_VID = "056a"

NUM = r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"
DIRECTION = re.compile(r"(Ring|Dial|Strip)\d?(CW|CCW|Up|Down)$")

# Keys this much smaller than the median key are direction dots on a rocker.
DOT_AREA = 0.15
# Keys within this distance of each other (canvas height = 1), or within this
# share of the smaller key's short side, touch.
TOUCH = 0.006
NEAR = 0.4
# Keys one behind the other, no further apart than this share of their depth, group.
STACKED = 1.0
# Keys whose centers stray more than this share of their thickness aren't in a line.
LINE_TOLERANCE = 0.3
# Neighboring keys further apart than this share of the edge start a new run.
RUN_BREAK = 0.12
# Depths closer than this (canvas height = 1) are the same lane.
LANE_STEP = 0.03


# MARK: - libwacom files

def read_tablets(data: Path) -> dict[int, configparser.ConfigParser]:
    """Wacom product ID → parsed .tablet file, for USB and Bluetooth matches."""
    out: dict[int, configparser.ConfigParser] = {}
    for path in sorted(data.glob("*.tablet")):
        cp = configparser.ConfigParser(strict=False, interpolation=None)
        cp.optionxform = str
        try:
            cp.read(path, encoding="utf-8")
        except configparser.Error:
            continue
        match = cp.get("Device", "DeviceMatch", fallback="")
        for m in re.finditer(r"(?:usb|bluetooth)\|([0-9a-fA-F]{4})\|([0-9a-fA-F]{4})", match):
            if m.group(1).lower() == WACOM_VID:
                out.setdefault(int(m.group(2), 16), cp)
    return out


# MARK: - SVG geometry

def mat_mul(a, b):
    return (a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
            a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
            a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5])


def parse_transform(text):
    m = (1, 0, 0, 1, 0, 0)
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", text or ""):
        v = [float(x) for x in re.findall(NUM, args)]
        if name == "translate":
            t = (1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0)
        elif name == "matrix":
            t = tuple(v)
        elif name == "scale":
            t = (v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0)
        elif name == "rotate":
            a = math.radians(v[0])
            c, s = math.cos(a), math.sin(a)
            t = (c, s, -s, c, 0, 0)
            if len(v) == 3:
                t = mat_mul(mat_mul((1, 0, 0, 1, v[1], v[2]), t), (1, 0, 0, 1, -v[1], -v[2]))
        else:
            continue
        m = mat_mul(m, t)
    return m


def path_points(d):
    """Endpoints and control points of a path; enough for a bounding box."""
    tokens = re.findall(r"[MmLlHhVvCcSsQqTtAaZz]|" + NUM, d)
    arity = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}
    pts, x, y, sx, sy, cmd, i = [], 0.0, 0.0, 0.0, 0.0, None, 0
    while i < len(tokens):
        t = tokens[i]
        if re.match(r"[A-Za-z]", t):
            cmd = t
            i += 1
        if cmd is None:
            break
        if cmd in "Zz":
            x, y = sx, sy
            continue
        k = arity[cmd.upper()]
        a = [float(v) for v in tokens[i:i + k]]
        i += k
        if len(a) < k:
            break
        rel, up = cmd.islower(), cmd.upper()
        if up == "H":
            x = x + a[0] if rel else a[0]
        elif up == "V":
            y = y + a[0] if rel else a[0]
        elif up == "A":
            x, y = (x + a[5], y + a[6]) if rel else (a[5], a[6])
        else:
            for j in range(0, k - 2, 2):
                pts.append((x + a[j] if rel else a[j], y + a[j + 1] if rel else a[j + 1]))
            x, y = (x + a[k - 2], y + a[k - 1]) if rel else (a[k - 2], a[k - 1])
        pts.append((x, y))
        if up == "M":
            sx, sy = x, y
            cmd = "l" if rel else "L"
    return pts


def bounds(el, m):
    tag = el.tag.split("}")[-1]

    def g(k):
        return float(re.findall(NUM, el.get(k, "0"))[0]) if el.get(k) else 0.0

    if tag == "rect":
        pts = [(g("x"), g("y")), (g("x") + g("width"), g("y") + g("height"))]
    elif tag in ("circle", "ellipse"):
        rx, ry = (g("r"), g("r")) if tag == "circle" else (g("rx"), g("ry"))
        pts = [(g("cx") - rx, g("cy") - ry), (g("cx") + rx, g("cy") + ry)]
    elif tag == "path":
        pts = path_points(el.get("d", ""))
    else:
        return None
    if not pts:
        return None
    q = [(m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]) for x, y in pts]
    xs, ys = [p[0] for p in q], [p[1] for p in q]
    return (min(xs), min(ys), max(xs), max(ys))


# CSS pixels per unit, for a canvas sized in physical units with no viewBox.
UNITS = {"": 1.0, "px": 1.0, "mm": 96 / 25.4, "cm": 96 / 2.54, "in": 96.0, "pt": 96 / 72, "pc": 16.0}


def length(text):
    m = re.match(r"\s*(" + NUM + r")\s*([a-z]*)", text or "")
    return float(m.group(1)) * UNITS.get(m.group(2), 1.0)


def svg_parts(path: Path):
    """(kind, letter, (x0, y0, x1, y1)) in canvas units with the canvas height as 1, plus the canvas aspect."""
    root = ET.parse(path).getroot()
    vb = root.get("viewBox")
    if vb:
        _, _, w, h = (float(v) for v in vb.replace(",", " ").split())
    else:
        w, h = length(root.get("width")), length(root.get("height"))
    found = []

    def walk(el, m):
        m = mat_mul(m, parse_transform(el.get("transform")))
        cls = (el.get("class") or "").split()
        if cls and not {"Label", "Leader"} & set(cls):
            kind = None
            if "TouchRing" in cls or cls == ["Ring"]:
                kind = "ring"
            elif "TouchDial" in cls or cls == ["Dial"]:
                kind = "dial"
            elif "TouchStrip" in cls or cls == ["Strip"]:
                kind = "strip"
            elif "Button" in cls and not any(DIRECTION.match(c) for c in cls):
                kind = "key"
            if kind:
                b = bounds(el, m)
                letter = next((c for c in cls if re.fullmatch(r"[A-Z]{1,2}", c)), "")
                if b and b[2] > b[0] and b[3] > b[1]:
                    found.append((kind, letter, (b[0] / h, b[1] / h, b[2] / h, b[3] / h)))
        for child in el:
            walk(child, m)

    walk(root, (1, 0, 0, 1, 0, 0))
    return found, w / h


# MARK: - Simplification

EDGES = ("L", "R", "T", "B")
# libwacom's side for a button breaks a near tie between the two nearest edges.
TIE = 1.5


def edge_distances(r, aspect):
    cx, cy = (r[0] + r[2]) / 2, (r[1] + r[3]) / 2
    return {"L": cx, "R": aspect - cx, "T": cy, "B": 1 - cy}


def side_of(r, aspect, hint=None):
    """The edge a part sits nearest, or libwacom's side for it when that's nearly as near."""
    d = edge_distances(r, aspect)
    nearest = min(EDGES, key=lambda e: d[e])
    if hint in d and hint != nearest and d[hint] <= max(d[nearest], 1e-6) * TIE:
        return hint
    return nearest


def vertical(side):
    return side in ("L", "R")


def along(r, side):
    return (r[1], r[3]) if vertical(side) else (r[0], r[2])


def thickness(r, side):
    return (r[2] - r[0]) if vertical(side) else (r[3] - r[1])


def area(r):
    return (r[2] - r[0]) * (r[3] - r[1])


def inside(point, r):
    return r[0] <= point[0] <= r[2] and r[1] <= point[1] <= r[3]


def touching(a, b):
    """Overlapping, or closer than a fraction of the smaller key's short side."""
    reach = max(TOUCH, NEAR * min(a[2] - a[0], a[3] - a[1], b[2] - b[0], b[3] - b[1]))
    return a[0] - reach <= b[2] and b[0] - reach <= a[2] and a[1] - reach <= b[3] and b[1] - reach <= a[3]


def union(rects):
    return (min(r[0] for r in rects), min(r[1] for r in rects),
            max(r[2] for r in rects), max(r[3] for r in rects))


def key_shape(keys, side):
    """f, s, or w: keys shorter than they are deep, about square, or longer."""
    ratios = sorted((along(r, side)[1] - along(r, side)[0]) / thickness(r, side) for r in keys)
    ratio = ratios[len(ratios) // 2]
    return "f" if ratio < 0.75 else ("s" if ratio < 1.4 else "w")


def simplify(found, aspect, hints):
    """Parts as dicts of control, side, lane, start, and end, the span in fractions of the edge."""
    rounds = [(k, r) for k, _, r in found if k in ("ring", "dial")]
    strips = [r for k, _, r in found if k == "strip"]
    keys = [(letter, r) for k, letter, r in found if k == "key"]
    if keys:
        median = sorted(area(r) for _, r in keys)[len(keys) // 2]

        def dropped(k):
            center = ((k[0] + k[2]) / 2, (k[1] + k[3]) / 2)
            if area(k) < median * DOT_AREA:
                return True
            for _, r in rounds:
                if inside(center, r):
                    return True
                rs = side_of(r, aspect)
                a0, a1 = along(k, rs)
                b0, b1 = along(r, rs)
                if a0 < b1 and a1 > b0 and area(k) < area(r) * 0.3:
                    return True
            return False

        keys = [(letter, r) for letter, r in keys if not dropped(r)]

    # Keys that touch, or sit one behind the other on the same edge, form groups.
    def related(a, b):
        if touching(a[1], b[1]):
            return True
        sa, sb = side_of(a[1], aspect, hints.get(a[0])), side_of(b[1], aspect, hints.get(b[0]))
        if sa != sb:
            return False
        (a0, a1), (b0, b1) = along(a[1], sa), along(b[1], sa)
        overlap = min(a1, b1) - max(a0, b0)
        gap = abs(edge_distances(a[1], aspect)[sa] - edge_distances(b[1], aspect)[sa]) \
            - (thickness(a[1], sa) + thickness(b[1], sa)) / 2
        short = min(a1 - a0, b1 - b0)
        return overlap >= short / 2 and gap <= STACKED * min(thickness(a[1], sa), thickness(b[1], sa))

    groups = [[k] for k in keys]
    merged = True
    while merged:
        merged = False
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                if any(related(a, b) for a in groups[i] for b in groups[j]):
                    groups[i] += groups.pop(j)
                    merged = True
                    break
            if merged:
                break

    parts = []

    def add(control, r, side):
        a0, a1 = along(r, side)
        edge = 1.0 if vertical(side) else aspect
        parts.append({"control": control, "side": side, "start": a0 / edge, "end": a1 / edge,
                      "depth": edge_distances(r, aspect)[side]})

    for kind, r in rounds:
        add(kind[0], r, side_of(r, aspect))
    for r in strips:
        add("s", r, side_of(r, aspect))

    # A ring or dial set into a block of keys splits it, so the keys on
    # either side read as their own groups.
    for kind, ring in rounds:
        rs = side_of(ring, aspect)
        middle = sum(along(ring, rs)) / 2
        split = []
        for g in groups:
            a0, a1 = along(union([r for _, r in g]), rs)
            b0, b1 = along(ring, rs)
            if len(g) > 1 and a0 < b1 and a1 > b0:
                before = [k for k in g if sum(along(k[1], rs)) / 2 < middle]
                after = [k for k in g if sum(along(k[1], rs)) / 2 >= middle]
                split += [h for h in (before, after) if h]
            else:
                split.append(g)
        groups = split

    singles = []  # (side, rect)
    for g in groups:
        rects = [r for _, r in g]
        letters = [hints.get(letter) for letter, _ in g if hints.get(letter)]
        hint = max(set(letters), key=letters.count) if letters else None
        side = side_of(union(rects), aspect, hint) if len(rects) > 1 else side_of(rects[0], aspect, hint)
        centers = [((r[0] + r[2]) / 2) if vertical(side) else ((r[1] + r[3]) / 2) for r in rects]
        thin = min(thickness(r, side) for r in rects)
        if len(rects) == 1 or max(centers) - min(centers) < thin * LINE_TOLERANCE:
            singles += [(side, r) for r in rects]
        else:
            add("c", union(rects), side)

    # Single keys in a row along one side become runs, unless something at
    # the same depth sits between them.
    by_side: dict[str, list] = {}
    for side, r in singles:
        by_side.setdefault(side, []).append(r)
    for side, ks in by_side.items():
        ks.sort(key=lambda r: along(r, side)[0])
        edge = 1.0 if vertical(side) else aspect
        run = [ks[0]]

        def flush():
            add("k%d%s" % (len(run), key_shape(run, side)), union(run), side)

        for k in ks[1:]:
            last_end = along(run[-1], side)[1]
            start = along(k, side)[0]
            here = edge_distances(k, aspect)[side]
            level = abs(edge_distances(run[-1], aspect)[side] - here) <= thickness(k, side) / 2
            between = any(p["side"] == side and abs(p["depth"] - here) <= LANE_STEP
                          and p["start"] * edge < start and p["end"] * edge > last_end for p in parts)
            if (start - last_end) / edge < RUN_BREAK and level and not between:
                run.append(k)
            else:
                flush()
                run = [k]
        flush()

    # Lanes: parts at clearly different depths sharing a stretch of edge.
    for side in EDGES:
        mine = [p for p in parts if p["side"] == side]
        crowded = any(abs(a["depth"] - b["depth"]) > LANE_STEP and a["start"] < b["end"] and a["end"] > b["start"]
                      for a in mine for b in mine if a is not b)
        levels = []
        for d in sorted(p["depth"] for p in mine):
            if not levels or d - levels[-1] > LANE_STEP:
                levels.append(d)
        for p in mine:
            p["lane"] = max(i for i, lv in enumerate(levels) if p["depth"] >= lv - 1e-9) if crowded else 0

    parts.sort(key=lambda p: (EDGES.index(p["side"]), p["lane"], p["start"]))
    return parts


def side_hints(cp):
    """Button letter → the side libwacom lists it on."""
    hints = {}
    if cp.has_section("Buttons"):
        for key, side in (("Left", "L"), ("Right", "R"), ("Top", "T"), ("Bottom", "B")):
            for letter in cp.get("Buttons", key, fallback="").split(";"):
                if letter.strip():
                    hints[letter.strip()] = side
    return hints


def encode(parts):
    def clamp(v):
        return max(0, min(1000, round(v * 1000)))

    return ", ".join("%s%s%d %d-%d" % (p["control"], p["side"], p["lane"], clamp(p["start"]), clamp(p["end"]))
                     for p in parts)


# MARK: - Output

HEADER = '''\
// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Generated by tools/registry/generate_tablet_layouts.py from libwacom's
// tablet layouts. Don't edit by hand; rerun the script instead.
//
// libwacom carries this notice:
//
// Copyright © 2011 Red Hat, Inc.
//
// Permission to use, copy, modify, distribute, and sell this software
// and its documentation for any purpose is hereby granted without
// fee, provided that the above copyright notice appear in all copies
// and that both that copyright notice and this permission notice
// appear in supporting documentation, and that the name of Red Hat
// not be used in advertising or publicity pertaining to distribution
// of the software without specific, written prior permission.  Red
// Hat makes no representations about the suitability of this software
// for any purpose.  It is provided "as is" without express or implied
// warranty.
//
// THE AUTHORS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
// INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN
// NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR
// CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
// OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
// NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
// CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

/// Where each Wacom model's controls sit, for `TabletFigure`.
///
/// One line per layout: the product IDs that share it, a colon, then its
/// parts. A part reads `<control><side><lane> <start>-<end>`:
///
/// - control: `k` and a count for a run of keys, then `f`, `s`, or `w` for
///   keys shorter than they are deep, about square, or longer; `c` for a
///   cluster of keys; `r` for a ring; `d` for a dial; `s` for a strip.
/// - side: `L`, `R`, `T`, or `B`, the edge it sits on in landscape.
/// - lane: 0 nearest the edge, counting inward.
/// - start-end: its span along that edge in thousandths, from the top or left.
enum TabletLayoutTable {
    static let packed = """
'''

FOOTER = '''\
    """
}
'''


def build(libwacom: Path, registry: Path) -> str:
    tablets = read_tablets(libwacom)
    devices = json.loads(registry.read_text(encoding="utf-8"))["devices"]
    lines: dict[str, list[int]] = {}
    for d in devices:
        pid = d["productID"] if isinstance(d["productID"], int) else int(d["productID"], 16)
        cp = tablets.get(pid)
        if cp is None or cp.get("Device", "IntegratedIn", fallback="").strip() == "Remote":
            continue
        layout = cp.get("Device", "Layout", fallback="").strip()
        svg = libwacom / "layouts" / layout
        if not layout or not svg.exists():
            continue
        found, aspect = svg_parts(svg)
        parts = simplify(found, aspect, side_hints(cp))
        if parts:
            lines.setdefault(encode(parts), []).append(pid)
    rows = sorted(((sorted(pids), parts) for parts, pids in lines.items()), key=lambda r: r[0][0])
    body = "".join("    %s: %s\n" % (" ".join("%04X" % p for p in pids), parts) for pids, parts in rows)
    return HEADER + body + FOOTER


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--libwacom-data", required=True, type=Path, help="libwacom's data directory")
    ap.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--check", action="store_true", help="exit 1 if the output is out of date")
    args = ap.parse_args()
    text = build(args.libwacom_data, args.registry)
    if args.check:
        current = args.output.read_text(encoding="utf-8") if args.output.exists() else ""
        if current != text:
            print("%s is out of date" % args.output, file=sys.stderr)
            return 1
        return 0
    args.output.write_text(text, encoding="utf-8")
    print("wrote %s" % args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
