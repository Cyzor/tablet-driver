# tools/

Project-side scripts that aren't part of the app build but are used to maintain
the registry, audit it against upstream sources, and capture HID traffic.

Most of these scripts touch `../mocktab-kit/Sources/TabletKit/WacomDeviceRegistry.swift` directly
or produce input that gets pasted in.  None of them are wired into a build step
— they're meant to be run from the repo root by hand, occasionally, when you
want to refresh against newer upstream data.

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
    --registry ../mocktab-kit/Sources/TabletKit/WacomDeviceRegistry.swift \
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
`Notes/Scratch/` audit doc.

```
python3 tools/audit_wacom_hid_descriptors.py \
    --registry ../mocktab-kit/Sources/TabletKit/WacomDeviceRegistry.swift \
    > Notes/Scratch/Wacom-Descriptor-Audit-$(date +%Y-%m-%d).md
```

### `audit_registry.py`
**Internal-consistency audit.**

Pre-existing.  Checks the registry for shape problems (duplicate PIDs,
missing required fields, etc.).

### `verify_registry.py`
**Pre-existing internal verification pass.**

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
App-side release scripts.  Build, sign, notarize, package.  Out of scope for
TabletKit (the package has no release process yet).

## Generated files

### `registry_audit.csv`
Pre-existing snapshot of `audit_registry.py` output.  Regenerate by running
that script.
