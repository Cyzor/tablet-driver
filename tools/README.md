# tools/

Project-side scripts that aren't part of the app build but are used to maintain
the registry, audit it against upstream sources, triage submitted captures, and
capture HID traffic.

The registry lives at `TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift`.
Most scripts read it (a few edit it in place) or produce Swift that gets pasted
in.  None are wired into a build step — run them from the repo root by hand,
occasionally, when refreshing against newer upstream data or handling a
submission.

### `registry_lib.py`
**Shared parsing library — not run directly.**

One implementation of every parser the other scripts need: the Swift registry,
the kernel `wacom_features` table, and an OpenTabletDriver configuration tree,
plus the Swift-emission and LPI helpers.  It carries the canonical default paths
(`DEFAULT_REGISTRY`, `DEFAULT_KERNEL`, `DEFAULT_OTD`), so the audit scripts run
with no arguments.  Import it (`import registry_lib as rl`); don't run it.

Its registry parser walks `.init(` blocks by balancing parentheses, so it reads
every entry even when a comment sits between `.init(` and `productID:` — the
regex parsers it replaced silently skipped those, roughly a quarter of the
table.

## Registry maintenance (Wacom)

### `import_otd_configs.py`
**OTD → `WacomDeviceSpec` Swift entries.**

Reads an OpenTabletDriver `Configurations/Wacom/` checkout, emits `.init(…)`
blocks for any Wacom PID not already in the registry.  Output goes to stdout —
paste into `WacomDeviceRegistry.knownDevices`.

```
python3 tools/import_otd_configs.py /path/to/OTD/Configurations/Wacom > new.txt
```

### `backfill_libwacom_dimensions.py`
**libwacom `.tablet` files → `activeWidthMM` / `activeHeightMM` fields.**

Walks a libwacom data directory (https://github.com/linuxwacom/libwacom), builds
a `{PID: (widthMM, heightMM)}` map, and edits `WacomDeviceRegistry.swift`
in place to fill the dimensions on entries missing them.  Hand-measured
`.verified` entries are preserved untouched.  An LPI-consistency guard
rejects pairings whose implied per-axis LPI disagrees by more than 8% — the
signature of a stale libwacom row or a cross-product PID collision.

```
python3 tools/backfill_libwacom_dimensions.py \
    --libwacom-data /path/to/libwacom/data \
    --registry TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift \
    --dry-run
```

### `audit_wacom_hid_descriptors.py`
**Cross-reference registry against linuxwacom HID descriptor corpus.**

Walks `linuxwacom/wacom-hid-descriptors` via the GitHub API, extracts PIDs from
sysinfo filenames (`BUS:VID:PID.NNNN.hid.txt`), and categorizes every registry
entry as: confirmed (`.verified` — no action), promotable (PID present in both
with matching names — candidate for `.crossReferenced`), naming-drift (PIDs
match but names diverge — needs human review), or missing (linuxwacom has it,
the registry doesn't).  Emits a Markdown table to stdout — paste into a
`Notes/Scratch/` audit doc.  `--registry` defaults to the canonical path.

```
python3 tools/audit_wacom_hid_descriptors.py \
    > Notes/Scratch/Wacom-Descriptor-Audit-$(date +%Y-%m-%d).md
```

### `audit_registry.py`
**Internal-consistency + kernel-dimension audit.**

Diffs the registry against the kernel `wacom_features` table: name, maxX/maxY,
maxPressure, and button count per shared PID.  Runs with no arguments.

```
python3 tools/audit_registry.py            # full audit
python3 tools/audit_registry.py --only numeric   # just dimension drift
```

### `audit_kernel_registry.py`
**Structural + coverage audit against the kernel.**

Reports duplicate PIDs that aren't disambiguated by `productStringMatch`, kernel
PIDs the registry doesn't cover, dimension drift, and any entry whose X/Y LPI
disagree grossly (a data-error signature; ordinary old-hardware anisotropy is
tolerated).  Runs with no arguments; exit status is non-zero when it finds
something.

### `verify_registry.py`
**Three-way cross-reference → CSV.**

The most thorough audit: one row per registry entry comparing it to both the
kernel and OpenTabletDriver, with a verdict (`agree`, `cross_referenced`,
`kernel_disagrees`, `otd_only`, `unknown`, …).  All paths default to the
canonical layout.

```
python3 tools/verify_registry.py --out registry_audit.csv
```

## Registry maintenance (non-Wacom)

### `import_vendor_configs.py`
**OTD → `VendorDeviceProfile` Swift entries** for non-Wacom vendors.

Sibling of `import_otd_configs.py`, but produces the recognition-only shape
used by `VendorDeviceRegistry` for devices the registry *names* but doesn't
yet decode.

```
python3 tools/import_vendor_configs.py \
    /path/to/OTD/Configurations \
    --vendors Huion Xencelabs XP-Pen
```

## Processing submitted captures

### `triage_discovery.py`
**Turn one submitted capture JSON into a Markdown triage report.**

Reads the file the app's *Collect Device Data…* flow produces (either the
discovery or the guided-calibration shape) and prints: a validation summary, how
the device compares to our own registries, the coordinate/pressure ranges its
HID descriptor exposes, an inventory of its reports with a decoder-family guess,
a kernel/OTD cross-reference, and a **draft** `.init(…)` registry entry to start
from.  Tolerant of surrounding prose or a ```json fence, so a block pasted
straight out of an issue works.

The draft is a starting point for human review against real hardware, never a
paste-and-ship entry — the `parser` field is intentionally left `.REVIEW`, and
coordinate ranges follow the project convention that the kernel outranks a
device's own descriptor (many tablets also expose a low-resolution generic
digitizer whose declared ranges are nothing like the real ones).

```
python3 tools/triage_discovery.py path/to/capture.json
python3 tools/triage_discovery.py capture.json --no-upstream   # skip kernel/OTD
```

**Serials in older captures.** Current app builds no longer write the device
serial into capture files.  Files produced before that change may still contain
a `serialNumber`; the triage tool flags it in its validation section.  Scrub any
serial before committing a capture into the repo — these files end up in public
issues.

## HID capture (legacy / dev-only)

### `wacom_capture.d`, `wacom_init.d`
DTrace scripts for capturing USB IOKit traffic against Wacom devices.  macOS
only.  Used during the initial reverse-engineering of PTH-660 and PTH-860 BT
behavior.  Superseded by the in-app capture flow for most cases.

### `touch_capture.c`
Standalone C utility that opens a HID device and dumps reports.  Pre-existing,
used during the PTH-860 touch decoder work.

## Build / release

### `ExportOptions.plist`
Xcode archive export config — referenced by `release-and-publish.sh`.

### `release.sh`, `release-and-publish.sh`
App-side release scripts for a numbered version.  `release.sh` builds, signs,
notarizes, and packages; `release-and-publish.sh` wraps it with the tag +
draft-GitHub-release work.  Out of scope for TabletKit (the package has no
release process yet).

### `build-snapshot.sh`, `snapshot-and-publish.sh`
Same shape as `release.sh` / `release-and-publish.sh`, but for the rolling,
unversioned "snapshot" pre-release (`dist/MockTab-snapshot.dmg`, no
`MARKETING_VERSION` bump, no version tag) — for sharing where `main` stands
between formal releases. `snapshot-and-publish.sh` also replaces the single
`snapshot` tag/pre-release as a **draft**; nothing is public until you click
Publish on GitHub. Mirrors `.github/workflows/snapshot.yml`, which does the
same thing on manual dispatch — use one path per snapshot.
