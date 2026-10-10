# tools/

Scripts for testing, releasing, measuring, and maintaining the app. None run as part of the build. Run them by hand from the repo root. Each file's header explains what it does and how to run it.

Registry and capture-triage scripts live in [`TabletKit/tools/`](../TabletKit/tools/), next to the data they check, so TabletKit contributors don't need this repo.

## tests/

Standalone test harnesses for app code. `tests/run-all-tests.sh` runs them all, as CI does. See [`Contributing.md`](../Contributing.md).

## release/

Builds, signs, notarizes, and packages the app.

- `release.sh` builds a numbered release. `release-and-publish.sh` also tags it and creates a draft GitHub release.
- `build-snapshot.sh` and `snapshot-and-publish.sh` do the same for the rolling snapshot between releases. `.github/workflows/snapshot.yml` can also build one. Pick one path per snapshot.
- `update-latest.sh` records a published build in mocktab-web so the website's update page lists it. GitHub runs it after you publish.
- `size-watch.sh` warns when the app grows or links something new. `arch-check.sh` fails the build unless the app runs on both Apple silicon and Intel. The release scripts run both.
- `idle-check.sh` compares the running app's idle CPU and memory against a budget.
- `floor-check.sh` opens a build in a macOS 13 or 14 virtual machine. Go through `floor-check.md` there before a release.
- `../latency/strain-bench.sh` measures pen latency while the Mac is busy and compares it with a recorded baseline. Run it before a release with a wired tablet.

Publishing creates a draft. Nothing goes public until you click Publish on GitHub.

## registry/

Keeps the Wacom registry (`TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift`) in step with outside sources.

- `backfill_libwacom_dimensions.py` fills in missing tablet sizes from [libwacom](https://github.com/linuxwacom/libwacom). It leaves hand-measured entries alone. Try it with `--dry-run` first.
- `import_vendor_configs.py` turns OpenTabletDriver configs into entries for other brands' tablets.
- `upstream-sweep.sh` fetches libwacom, input-wacom, and OpenTabletDriver and reports what changed since the last review.

## capture/

Small tools for watching what a tablet sends and what the system does with it. Most are C files with build steps in their header.

- The `.d` scripts log the commands any driver sends a tablet. They need System Integrity Protection off.
- `check-report-zip.py` vets an emailed diagnostics file before you open it.
- `WacomProbeDevice.swift` only builds when copied into the app. It reports the highest coordinates and pressure an unknown tablet sends, so you can write a registry entry.
- `OTDImporter.swift` is unused, but it's easy to bring back.

Older capture files may contain a device serial number. `triage_discovery.py` flags it. Remove the serial before committing, since captures end up in public issues.

## latency/ and event-probe/

`latency/` measures the time from a tablet report to the cursor moving. `latency_ab.sh` compares MockTab with another driver, and `strain-bench.sh` measures MockTab with the CPU, GPU, or memory under load. `event-probe/` records the events a driver posts so you can find fields MockTab leaves out.
