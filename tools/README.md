# tools/

Project-side scripts that aren't part of the app build but are used to maintain
the registry, audit it against upstream sources, triage submitted captures, and
capture HID traffic.

```
tools/
  tests/     standalone test harnesses (no XCTest target) — see Contributing.md
  release/   build, sign, notarize, publish
  capture/   HID capture probes + unwired app source
  latency/   latency measurement suite
  registry/  upstream cross-check + dimension backfill (non-Wacom)
```

The registry lives at `TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift`.
Most scripts read it (a few edit it in place) or produce Swift that gets pasted
in.  None are wired into a build step — run them from the repo root by hand,
occasionally, when refreshing against newer upstream data or handling a
submission.

**Registry parsing, import, and audit scripts now live in
[`TabletKit/tools/`](../TabletKit/tools/)**, next to the data they validate,
so a TabletKit-only contributor has the same guardrails without needing the
app repo: `registry_lib.py` (shared parser), `import_otd_configs.py`,
`audit_wacom_hid_descriptors.py`, `audit_registry.py`,
`audit_kernel_registry.py`, `verify_registry.py`, and `triage_discovery.py`.
What remains below is app-repo-specific: release/snapshot tooling, legacy
capture utilities, and the non-Wacom vendor import (which isn't registry data
in the same sense — see below).

### `backfill_libwacom_dimensions.py`
**libwacom `.tablet` files → `activeWidthMM` / `activeHeightMM` fields.**

Walks a libwacom data directory (https://github.com/linuxwacom/libwacom), builds
a `{PID: (widthMM, heightMM)}` map, and edits `WacomDeviceRegistry.swift`
in place to fill the dimensions on entries missing them.  Hand-measured
`.verified` entries are preserved untouched.  An LPI-consistency guard
rejects pairings whose implied per-axis LPI disagrees by more than 8% — the
signature of a stale libwacom row or a cross-product PID collision.

```
python3 tools/registry/backfill_libwacom_dimensions.py \
    --libwacom-data /path/to/libwacom/data \
    --registry TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift \
    --dry-run
```

## Registry maintenance (non-Wacom)

### `import_vendor_configs.py`
**OTD → `VendorDeviceProfile` Swift entries** for non-Wacom vendors.

Sibling of `import_otd_configs.py`, but produces the recognition-only shape
used by `VendorDeviceRegistry` for devices the registry *names* but doesn't
yet decode.

```
python3 tools/registry/import_vendor_configs.py \
    /path/to/OTD/Configurations \
    --vendors Huion Xencelabs XP-Pen
```

## Unwired app source (not in the Xcode target)

### `OTDImporter.swift`
**Swift-native OTD JSON → registry entry converter — unused.**

Parses the same OTD configuration JSON as `import_otd_configs.py`, but in
Swift, emitting `WacomDeviceSpec`/`VendorDeviceProfile`-shaped entries.
Nothing calls it and it was never wired into the pbxproj; it depends only on
`Foundation` and `TabletKit`, so it's portable if it's ever picked back up.
Moved here from `MockTab/Driver/` rather than deleted, since it's real,
working-looking logic, not a stub.

## Processing submitted captures

Submitted-capture triage (`triage_discovery.py`) now lives in
[`TabletKit/tools/`](../TabletKit/tools/) alongside the registry it
cross-references.

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

### `WacomProbeDevice.swift`
A `TabletDevice` shim you temporarily copy into `MockTab/Driver/Devices/` and
wire into `TabletManager.deviceConnected(_:)` when researching an unrecognized
Wacom device that speaks the 10-byte IntuosV1 wire format: it logs running
coordinate/pressure maxima to Console so you can read off real ranges before
writing a proper registry entry. See the file header for the exact steps.
Not part of the Xcode target — it depends on app-internal helpers that only
resolve once it's copied into `Devices/`.

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
