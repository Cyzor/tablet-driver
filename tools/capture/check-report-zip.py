#!/usr/bin/env python3
"""check-report-zip.py — vet an emailed diagnostics zip before unpacking it.

A real report is what Help › Collect Device Data… writes: one folder named
mocktab-diagnostics-*, holding summary.json, README.txt, and optionally
full-log.txt. Anything else is rejected without being extracted.

    tools/capture/check-report-zip.py report.zip            # check and summarize
    tools/capture/check-report-zip.py report.zip --extract DIR
"""

import json
import sys
import zipfile
from pathlib import Path, PurePosixPath

ALLOWED = {"summary.json", "README.txt", "full-log.txt"}
MAX_TOTAL = 50 * 1024 * 1024  # real captures run well under 5 MB


def check(path: Path) -> tuple[list[str], dict | None]:
    problems: list[str] = []
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        return ["not a zip file"], None
    with zf:
        infos = [i for i in zf.infolist() if not i.is_dir()]
        roots = {PurePosixPath(i.filename).parts[0] for i in zf.infolist()}
        if len(roots) != 1 or not next(iter(roots)).startswith("mocktab-diagnostics-"):
            problems.append(f"unexpected top level: {sorted(roots)}")
        for i in infos:
            p = PurePosixPath(i.filename)
            if p.is_absolute() or ".." in p.parts or len(p.parts) != 2:
                problems.append(f"bad path: {i.filename}")
            elif p.name not in ALLOWED:
                problems.append(f"unexpected file: {i.filename}")
            if (i.external_attr >> 16) & 0o170000 == 0o120000:
                problems.append(f"symlink: {i.filename}")
        if sum(i.file_size for i in infos) > MAX_TOTAL:
            problems.append("uncompressed size over 50 MB")
        summary_name = next((i.filename for i in infos if i.filename.endswith("/summary.json")), None)
        if summary_name is None:
            problems.append("no summary.json")
            return problems, None
        try:
            summary = json.loads(zf.read(summary_name))
        except (ValueError, UnicodeDecodeError):
            problems.append("summary.json isn't valid JSON")
            return problems, None
        if not isinstance(summary, dict) or "captureVersion" not in summary or "deviceInfo" not in summary:
            problems.append("summary.json lacks captureVersion/deviceInfo")
            return problems, None
        return problems, summary


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip())
        return 2
    path = Path(args[0])
    problems, summary = check(path)
    if problems:
        print(f"REJECT {path.name}")
        for p in problems:
            print(f"  - {p}")
        return 1
    info = summary["deviceInfo"]
    print(f"OK {path.name}")
    print(f"  device:  {info.get('name')}  {info.get('vendorID')}/{info.get('productID')}  {info.get('transport')}")
    print(f"  app:     {summary.get('appVersion')} (built {summary.get('appBuildDate')}), capture v{summary['captureVersion']}")
    print(f"  length:  {summary.get('duration', 0):.0f} s")
    for f in summary.get("findings") or []:
        print(f"  finding: {f.get('kind')} — {f.get('detail')}")
    if len(args) == 3 and args[1] == "--extract":
        dest = Path(args[2])
        with zipfile.ZipFile(path) as zf:
            zf.extractall(dest)
        print(f"  extracted to {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
