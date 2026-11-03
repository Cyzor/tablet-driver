# MockTab — native macOS driver for supported drawing tablets
# SPDX-FileCopyrightText: 2026 MockTab contributors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Checks every dotted string literal in MockTab/ against the symbol
availability table that ships with macOS. Literals the table doesn't know
are skipped, so a symbol newer than the Mac running this check goes
unnoticed; run it on a current macOS before a release."""

import pathlib
import plistlib
import re
import sys

TABLE = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"

# Newer symbols the code checks for at runtime, with the stand-in it uses.
# A fallback counts only if its name appears in the same file.
FALLBACKS = {
    "button.horizontal": "capsule",
    "square.arrowtriangle.4.outward": "arrow.up.left.and.arrow.down.right",
    "rectangle.landscape.rotate": "crop.rotate",
}


def version(text):
    return tuple(int(p) for p in text.split("."))


def main(root):
    root = pathlib.Path(root)
    pbx = (root / "MockTab.xcodeproj/project.pbxproj").read_text()
    floor = min(version(v) for v in re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([\d.]+);", pbx))
    table = plistlib.load(open(TABLE, "rb"))
    years, releases = table["symbols"], table["year_to_release"]

    def first_macos(name):
        year = years.get(name)
        return version(releases[year]["macOS"]) if year in releases else None

    problems = []
    checked = set()
    for path in sorted((root / "MockTab").rglob("*.swift")):
        source = path.read_text()
        for number, line in enumerate(source.splitlines(), 1):
            for name in re.findall(r'"([a-z0-9]+(?:\.[a-z0-9]+)+)"', line):
                since = first_macos(name)
                if since is None:
                    continue
                checked.add(name)
                if since <= floor:
                    continue
                where = f"{path.relative_to(root)}:{number}"
                fallback = FALLBACKS.get(name)
                if fallback is None:
                    problems.append(f"{where}: {name} needs macOS {'.'.join(map(str, since))}, and has no fallback")
                elif f'"{fallback}"' not in source:
                    problems.append(f"{where}: {name} has no {fallback} fallback in this file")
                elif (first_macos(fallback) or (99,)) > floor:
                    problems.append(f"{where}: {name}'s fallback {fallback} is also too new")

    floor_text = ".".join(map(str, floor))
    for p in problems:
        print(p)
    print(f"{len(checked)} symbols checked against macOS {floor_text}; {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
