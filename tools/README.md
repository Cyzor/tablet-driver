# tools/

Scripts for maintaining the registry, triaging submitted captures, capturing
tablet traffic, and releasing the app. None run as part of the build. Run them
by hand from the repo root.

```
tools/
  tests/     standalone test harnesses (no XCTest target); see Contributing.md
  release/   build, sign, notarize, publish
  capture/   capture probes and unused app source
  latency/   latency measurement
  registry/  upstream cross-checks and dimension backfill
```

The registry lives at `TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift`.
Most scripts read it. A few edit it in place or print Swift to paste in.

**Registry parsing, import, and audit scripts live in
[`TabletKit/tools/`](../TabletKit/tools/)**, next to the data they check, so
TabletKit contributors don't need this repo: `registry_lib.py`,
`import_otd_configs.py`, `audit_wacom_hid_descriptors.py`, `audit_registry.py`,
`audit_kernel_registry.py`, `verify_registry.py`, and `triage_discovery.py`.
This folder keeps the app-only tools.

## Registry

### `backfill_libwacom_dimensions.py`
**Fills `activeWidthMM` / `activeHeightMM` from libwacom.**

Reads a [libwacom](https://github.com/linuxwacom/libwacom) data directory and
fills in missing dimensions in `WacomDeviceRegistry.swift`. It leaves
hand-measured `.verified` entries alone, and skips any match whose implied
resolution differs by more than 8% between axes, a sign of a stale libwacom
row or two products sharing an ID.

```
python3 tools/registry/backfill_libwacom_dimensions.py \
    --libwacom-data /path/to/libwacom/data \
    --registry TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift \
    --dry-run
```

### `import_vendor_configs.py`
**Turns OpenTabletDriver configs into `VendorDeviceProfile` entries** for other
makers' tablets that MockTab recognizes but doesn't decode yet.

```
python3 tools/registry/import_vendor_configs.py \
    /path/to/OTD/Configurations \
    --vendors Huion Xencelabs XP-Pen
```

## Unused app source

### `OTDImporter.swift`
A Swift version of `import_otd_configs.py`. Nothing calls it, and it was never
in the Xcode project. It depends only on Foundation and TabletKit, so it's easy
to revive.

## Submitted captures

`triage_discovery.py` lives in [`TabletKit/tools/`](../TabletKit/tools/).

Current builds leave the device serial number out of capture files. Older files
may still have a `serialNumber`, which the triage tool flags. Remove it before
committing a capture, since captures end up in public issues.

## Capture (developer only)

### `hid_traffic_capture.d`, `hid_connect_capture.d`
DTrace scripts that log the setup commands any driver sends a tablet, during
use and on connect. They need System Integrity Protection off. In-app capture
covers most other needs.

### `usb_string_probe.c`
Reads USB string descriptors from any device through the USB device plugin,
without opening it, so it works while MockTab or another driver has the
tablet open. Built to check whether MockTab can read the self-descriptions
Huion (string 200) and XP-Pen or Xencelabs (string 100) tablets give. Build
and run instructions are in the file header.

### `touch_capture.c`
A small C tool that opens a HID device and prints its reports. Written for the
PTH-860 touch work.

### `WacomProbeDevice.swift`
A stand-in driver for an unknown Wacom tablet that uses the 10-byte IntuosV1
format. Copy it into `MockTab/Driver/Devices/` and hook it into
`TabletManager.deviceConnected(_:)`. It logs the highest coordinates and
pressure it sees, so you can read off real ranges before writing a registry
entry. The file header has the steps. It only builds once copied into the app.

## Release

### `ExportOptions.plist`
Archive export settings for `release-and-publish.sh`.

### `release.sh`, `release-and-publish.sh`
`release.sh` builds, signs, notarizes, and packages a numbered release.
`release-and-publish.sh` adds the tag and a draft GitHub release.

### `build-snapshot.sh`, `snapshot-and-publish.sh`
The same, for the rolling, unnumbered snapshot (`dist/MockTab-snapshot.dmg`),
which shares `main` between releases. `snapshot-and-publish.sh` replaces the
`snapshot` pre-release as a **draft**. Nothing goes public until you click
Publish on GitHub. `.github/workflows/snapshot.yml` does the same on manual
dispatch. Use one path per snapshot.
