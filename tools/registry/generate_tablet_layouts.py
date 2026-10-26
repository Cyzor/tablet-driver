#!/usr/bin/env python3
"""generate_tablet_layouts.py — write the control layouts MockTab draws tablets from

The Tablet Area pane draws each tablet from a kit of parts: a body, its active
surface, and the keys, rings, dials, and strips along its edges. TabletKit's
registry knows a model's size but not where its controls sit. libwacom's layout
SVGs do, so this script reads them and writes the simplified result into
MockTab/Figures/TabletLayoutTable.swift.

Simplification happens here, not in the app:

  • A part's side is the canvas edge it sits nearest. libwacom's [Buttons]
    Left/Right lists aren't geometry (the PTK-870's keys sit along the top).
  • Keys in a straight line become a run; keys packed in two directions, like
    a four-way pad or a rocker, become one cluster.
  • Buttons inside a ring or dial, mode keys beside a ring, and direction dots
    are dropped; the ring or dial stands for them.
  • Parts at different depths that share a stretch of edge get their own lanes.

A second table, `identity`, records which button each part stands for: the
libwacom letter of every key, including those the layout table drops.

Only registry models with a layout are written. Everything else draws as a
plain body, which needs no data.

Usage (from the repo root):
    python3 tools/registry/generate_tablet_layouts.py --libwacom-data /path/to/libwacom/data --libwacom-rev fea1650
    python3 tools/registry/generate_tablet_layouts.py --libwacom-data ... --check

--libwacom-rev is the libwacom commit the data comes from, recorded in the
output's header. --check writes nothing, takes the revision from the current
output unless given, and exits 1 with a diff if the table is out of date.
"""

from __future__ import annotations

import argparse
import configparser
import difflib
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REGISTRY = ROOT / "TabletKit" / "registry.json"
DEFAULT_OUTPUT = ROOT / "MockTab" / "Figures" / "TabletLayoutTable.swift"
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
                if kind == "key" and len(letter) != 1:
                    # The identity grammar runs letters together, so each must be one character.
                    raise SystemExit("%s: key %r needs a one-letter class" % (path.name, el.get("id")))
                if kind != "key":
                    # Ring, Ring2, Dial2…: which of the tablet's rings, dials, or strips it is.
                    letter = "2" if (el.get("id") or "").endswith("2") else "1"
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
    """Parts as dicts of control, side, lane, start, end, the span in fractions of the edge, and the
    letters of the keys each one stands for; plus the keys dropped beside or inside a ring or dial,
    as (letter, rect)."""
    rounds = [(k, r) for k, _, r in found if k in ("ring", "dial")]
    strips = [r for k, _, r in found if k == "strip"]
    dropped_keys = []
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

        dropped_keys = [(letter, r) for letter, r in keys if dropped(r)]
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

    def add(control, r, side, keys=()):
        a0, a1 = along(r, side)
        edge = 1.0 if vertical(side) else aspect
        parts.append({"control": control, "side": side, "start": a0 / edge, "end": a1 / edge,
                      "depth": edge_distances(r, aspect)[side], "rect": r, "keys": list(keys)})

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
            singles += [(side, k) for k in g]
        else:
            add("c", union(rects), side, g)

    # Single keys in a row along one side become runs, unless something at
    # the same depth sits between them.
    by_side: dict[str, list] = {}
    for side, k in singles:
        by_side.setdefault(side, []).append(k)
    for side, ks in by_side.items():
        ks.sort(key=lambda k: along(k[1], side)[0])
        edge = 1.0 if vertical(side) else aspect
        run = [ks[0]]

        def flush():
            rects = [r for _, r in run]
            add("k%d%s" % (len(run), key_shape(rects, side)), union(rects), side, run)

        for letter, k in ks[1:]:
            last_end = along(run[-1][1], side)[1]
            start = along(k, side)[0]
            here = edge_distances(k, aspect)[side]
            level = abs(edge_distances(run[-1][1], aspect)[side] - here) <= thickness(k, side) / 2
            between = any(p["side"] == side and abs(p["depth"] - here) <= LANE_STEP
                          and p["start"] * edge < start and p["end"] * edge > last_end for p in parts)
            if (start - last_end) / edge < RUN_BREAK and level and not between:
                run.append((letter, k))
            else:
                flush()
                run = [(letter, k)]
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
    return parts, dropped_keys


def side_hints(cp):
    """Button letter → the side libwacom lists it on."""
    hints = {}
    if cp.has_section("Buttons"):
        for key, side in (("Left", "L"), ("Right", "R"), ("Top", "T"), ("Bottom", "B")):
            for letter in cp.get("Buttons", key, fallback="").split(";"):
                if letter.strip():
                    hints[letter.strip()] = side
    return hints


# MARK: - Identity

# Evdev codes by name, for EvdevCodes; and the codes libwacom assumes without one.
EVDEV = {"BTN_LEFT": 0x110, "BTN_RIGHT": 0x111, "BTN_MIDDLE": 0x112, "BTN_SIDE": 0x113, "BTN_EXTRA": 0x114,
         "BTN_FORWARD": 0x115, "BTN_BACK": 0x116, "BTN_A": 0x130, "BTN_B": 0x131, "BTN_C": 0x132,
         "BTN_X": 0x133, "BTN_Y": 0x134, "BTN_Z": 0x135, "BTN_BASE": 0x126, "BTN_BASE2": 0x127,
         **{"BTN_%d" % i: 0x100 + i for i in range(10)}}
EXPRESS_CODES = [0x100 + i for i in range(10)] + [0x130, 0x131, 0x132, 0x133, 0x134, 0x135, 0x126, 0x127]
MOUSE_CODES = [0x110, 0x111, 0x115, 0x116]
MODE_LISTS = (("Ring", "r1"), ("Ring2", "r2"), ("Strip", "s1"), ("Strip2", "s2"), ("Dial", "d1"), ("Dial2", "d2"))

# Models whose libwacom data breaks an identity invariant, and why. The
# build fails when an entry no longer applies, so a libwacom update gets a look.
IDENTITY_EXCEPTIONS = {
    0x003A: "DTI-520: libwacom draws key B twice (ButtonB and ButtonB2)",
}


def button_list(cp, key):
    return [t.strip() for t in cp.get("Buttons", key, fallback="").split(";") if t.strip()]


def button_facts(cp):
    """Number of buttons, each letter's evdev code, and each mode-switch letter's target."""
    letters = set()
    for key in ("Left", "Right", "Top", "Bottom") + tuple(k for k, _ in MODE_LISTS):
        letters |= set(button_list(cp, key))
    n = len(letters)
    codes = button_list(cp, "EvdevCodes")
    if codes:
        ev = [EVDEV[c] if c in EVDEV else int(c, 16) for c in codes[:n]]
    elif cp.get("Device", "Class", fallback="") in ("Bamboo", "Graphire"):
        ev = [MOUSE_CODES[i] if i < len(MOUSE_CODES) else 0 for i in range(n)]
    else:
        ev = [EXPRESS_CODES[i] if i < len(EXPRESS_CODES) else 0 for i in range(n)]
    modes = {}
    for key, tag in MODE_LISTS:
        ls = button_list(cp, key)
        for i, letter in enumerate(ls):
            modes[letter] = "%s.%d" % (tag, i) if len(ls) > 1 else tag
    return n, ev, modes


def depth_span(r, side, aspect):
    d = edge_distances(r, aspect)[side]
    t = thickness(r, side) / 2
    return (d - t, d + t)


def grid(keys, side, aspect, body=None):
    """Keys as rows along the edge and columns of depth from it, nearest first.

    Slices come from key centers merged within half the smallest key's short
    side. A key fills every slice whose center lies inside it; "." is empty
    and "@" is the ring or dial the keys sit beside. Slices holding nothing
    of their own are dropped.
    """
    items = list(keys) + ([("@", body)] if body else [])
    tol = min(min(r[2] - r[0], r[3] - r[1]) for _, r in keys) / 2

    def slices(span):
        merged = []
        for v in sorted(sum(span(r)) / 2 for _, r in items):
            if merged and v - merged[-1][-1] <= tol:
                merged[-1].append(v)
            else:
                merged.append([v])
        return [sum(m) / len(m) for m in merged]

    def ax(r):
        return along(r, side)

    def dp(r):
        return depth_span(r, side, aspect)

    def cell(a, d):
        eps = 1e-9
        hits = [(letter == "@", area(r), letter) for letter, r in items
                if ax(r)[0] - eps <= a <= ax(r)[1] + eps and dp(r)[0] - eps <= d <= dp(r)[1] + eps]
        if hits:
            return min(hits)[2]
        dist, letter = min((abs(sum(ax(r)) / 2 - a) + abs(sum(dp(r)) / 2 - d), letter) for letter, r in items)
        return letter if dist <= tol else "."

    def prune(rows, keep_body):
        changed = True
        while changed and len(rows) > 1:
            changed = False
            for i, row in enumerate(rows):
                others = {c for j, other in enumerate(rows) if j != i for c in other}
                mine = {c for c in row if c != "."}
                if (mine <= others and "@" not in mine) or (not any(c.isalpha() for c in row)
                                                           and (not keep_body or "@" not in mine)):
                    rows = rows[:i] + rows[i + 1:]
                    changed = True
                    break
        return rows

    cells = [[cell(a, d) for d in slices(dp)] for a in slices(ax)]
    beside = body is not None and not any(
        ax(r)[0] <= sum(ax(body)) / 2 <= ax(r)[1] and dp(r)[0] <= sum(dp(body)) / 2 <= dp(r)[1] for _, r in keys)
    cells = prune(cells, False)
    columns = prune([list(c) for c in zip(*cells)], beside)
    return "/".join("".join(row) for row in zip(*columns))


def identity(found, aspect, parts, dropped, cp):
    """The identity line for a layout, one entry per part in `parts`' order, and the letters it used.

    - `k ABCD`: a run's letters from start to end.
    - `c <grid>`: a cluster's keys (see `grid`).
    - `r 1 [<letter> | <grid>]`, `d 2 …`: which ring or dial, and the keys
      inside it (its center button) or beside it.
    - `s 1`: which strip.
    - ` | m A=r1 …`: mode-switch keys; `.k` picks mode k, none cycles.
    - ` | ev …`: evdev codes from A on, when they aren't the ExpressKey defaults.
    """
    n, ev, modes = button_facts(cp)
    numbers = {r: letter for kind, letter, r in found if kind != "key"}
    rounds = [p for p in parts if p["control"] in ("r", "d")]
    owned: dict[int, list] = {}
    for letter, r in dropped:
        c = ((r[0] + r[2]) / 2, (r[1] + r[3]) / 2)
        if rounds:
            nearest = min(rounds, key=lambda p: (sum(p["rect"][0::2]) / 2 - c[0]) ** 2
                          + (sum(p["rect"][1::2]) / 2 - c[1]) ** 2)
            owned.setdefault(id(nearest), []).append((letter, r))
    entries, used = [], []
    for p in parts:
        control = p["control"]
        if control.startswith("k"):
            entries.append("k " + "".join(letter for letter, _ in p["keys"]))
            used += [letter for letter, _ in p["keys"]]
        elif control == "c":
            entries.append("c " + grid(p["keys"], p["side"], aspect))
            used += [letter for letter, _ in p["keys"]]
        else:
            text = "%s %s" % (control, numbers[p["rect"]])
            keys = owned.get(id(p), [])
            if len(keys) == 1 and inside(((keys[0][1][0] + keys[0][1][2]) / 2,
                                          (keys[0][1][1] + keys[0][1][3]) / 2), p["rect"]):
                text += " " + keys[0][0]
            elif keys:
                text += " " + grid(keys, p["side"], aspect, body=p["rect"])
            entries.append(text)
            used += [letter for letter, _ in keys]
    text = "; ".join(entries)
    if modes:
        text += " | m " + " ".join("%s=%s" % (letter, modes[letter]) for letter in sorted(modes))
    if any(code != (EXPRESS_CODES[i] if i < len(EXPRESS_CODES) else 0) for i, code in enumerate(ev)):
        text += " | ev " + " ".join("%X" % code for code in ev)
    return text, sorted(used), n


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
// tablet layouts at revision {rev}. Don't edit by hand; rerun the script instead.
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
///   A trailing `b` marks a part on the tablet's back.
/// - start-end: its span along that edge in thousandths, from the top or left.
enum TabletLayoutTable {
    static let packed = """
'''

IDENTITY_HEADER = '''\
    """

    /// Which button each part's keys are, from libwacom, for drawing a
    /// tablet whose controls light up. Lines group product IDs their own
    /// way; each lists one entry per part of that model's `packed` line, in
    /// the same order. Buttons are libwacom's letters, A on, in evdev order.
    ///
    /// - `k ABCD`: a run's keys from start to end.
    /// - `c <grid>`: a cluster's keys. Rows run along the edge from the top
    ///   or left, columns from the edge inward; `.` is empty, and a letter in
    ///   several cells is one key spanning them.
    /// - `r 1`, `d 2`, `s 1`: which ring, dial, or strip, then the key set
    ///   into it (its center button) or a grid of the keys beside it, where
    ///   `@` is the ring or dial itself.
    /// - ` | m A=r1 …`: keys that switch a ring, dial, or strip's mode;
    ///   `.k` picks mode k, and none cycles through them.
    /// - ` | ev …`: each button's evdev code from A on, in hex, when they
    ///   aren't the ExpressKey defaults.
    static let identity = """
'''

FOOTER = '''\
    """
}
'''


def build(libwacom: Path, registry: Path, rev: str) -> str:
    tablets = read_tablets(libwacom)
    devices = json.loads(registry.read_text(encoding="utf-8"))["devices"]
    lines: dict[str, list[int]] = {}
    identities: dict[str, list[int]] = {}
    problems, exceptions_used = [], set()
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
        parts, dropped = simplify(found, aspect, side_hints(cp))
        if parts:
            lines.setdefault(encode(parts), []).append(pid)
            text, used, n = identity(found, aspect, parts, dropped, cp)
            identities.setdefault(text, []).append(pid)
            expected = [chr(ord("A") + i) for i in range(n)]
            if used != expected:
                if pid in IDENTITY_EXCEPTIONS:
                    exceptions_used.add(pid)
                else:
                    problems.append("%04X: letters %s, libwacom has %s" % (pid, "".join(used), "".join(expected)))
    for pid in sorted(set(IDENTITY_EXCEPTIONS) - exceptions_used):
        problems.append("%04X: exception no longer applies (%s)" % (pid, IDENTITY_EXCEPTIONS[pid]))
    if problems:
        raise SystemExit("identity check failed:\n  " + "\n  ".join(problems))

    def table(entries):
        rows = sorted(((sorted(pids), text) for text, pids in entries.items()), key=lambda r: r[0][0])
        return "".join("    %s: %s\n" % (" ".join("%04X" % p for p in pids), text) for pids, text in rows)

    return HEADER.replace("{rev}", rev) + table(lines) + IDENTITY_HEADER + table(identities) + FOOTER


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--libwacom-data", required=True, type=Path, help="libwacom's data directory")
    ap.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--libwacom-rev", help="the libwacom commit the data comes from")
    ap.add_argument("--check", action="store_true", help="exit 1 if the output is out of date")
    args = ap.parse_args()
    current = args.output.read_text(encoding="utf-8") if args.output.exists() else ""
    rev = args.libwacom_rev
    if rev is None and args.check:
        found = re.search(r"tablet layouts at revision (\S+)\. ", current)
        rev = found.group(1) if found else "unknown"
    if not rev:
        ap.error("--libwacom-rev is required when writing")
    text = build(args.libwacom_data, args.registry, rev)
    if args.check:
        if current != text:
            print("%s is out of date:" % args.output, file=sys.stderr)
            diff = list(difflib.unified_diff(current.splitlines(), text.splitlines(),
                                             "current", "generated", lineterm=""))
            for line in diff[:60]:
                print(line, file=sys.stderr)
            if len(diff) > 60:
                print("… %d more diff lines" % (len(diff) - 60), file=sys.stderr)
            return 1
        return 0
    args.output.write_text(text, encoding="utf-8")
    print("wrote %s" % args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
