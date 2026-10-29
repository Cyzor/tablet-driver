# tools/

Scripts for testing, releasing, measuring, and maintaining the app. None run as part of the build. Run them by hand from the repo root. Each file's header explains what it does and how to run it.

Registry and capture-triage scripts live in [`TabletKit/tools/`](../TabletKit/tools/), next to the data they check, so TabletKit contributors don't need this repo.

## tests/

Standalone test harnesses for app code. `tests/run-all-tests.sh` runs them all, as CI does. See [`Contributing.md`](../Contributing.md).

## release/

Builds, signs, notarizes, and packages the app.

- `release.sh` builds a numbered release. `release-and-publish.sh` also tags it and creates a draft GitHub release.
- `build-snapshot.sh` and `snapshot-and-publish.sh` do the same for the rolling snapshot between releases.
- `update-latest.sh` records a published build in mocktab-web so the website's update page lists it. GitHub runs it after you publish.
- `size-watch.sh` warns when the app grows or links something new. `arch-check.sh` fails the build unless the app runs on both Apple silicon and Intel. The release scripts run both.
- `idle-check.sh` compares the running app's idle CPU and memory against a budget.
- `floor-check.sh` opens a build in a macOS 13 or 14 virtual machine. Go through `floor-check.md` there before a release.
- `../latency/strain-bench.sh` measures pen latency while the Mac is busy and compares it with a recorded baseline. Run it before a release with a wired tablet.

Publishing creates a draft. Nothing goes public until you click Publish on GitHub.

## registry/

Keeps the app's tablet data in step with outside sources. The scripts that edit TabletKit's registry live in [`TabletKit/tools/`](../TabletKit/tools/).

- `generate_tablet_layouts.py` writes `MockTab/Figures/TabletLayoutTable.swift` from libwacom's layouts: where each model's controls sit, and which button each key is. Run it with `--libwacom-data <libwacom>/data --libwacom-rev <commit>`; `--check` exits 1 and shows a diff if the table is out of date.
- `upstream-sweep.sh` fetches libwacom, input-wacom, and OpenTabletDriver and reports what changed since the last review.

## capture/

Small tools for watching what a tablet sends and what the system does with it. Most are C files with build steps in their header.

- The `.d` scripts log the commands any driver sends a tablet. They need System Integrity Protection off.
- `check-report-zip.py` vets an emailed diagnostics file before you open it.
- `WacomProbeDevice.swift` only builds when copied into the app. It reports the highest coordinates and pressure an unknown tablet sends, so you can write a registry entry.

Older capture files may contain a device serial number. `triage_discovery.py` flags it. Remove the serial before committing, since captures end up in public issues.

## hardware-check/

`hardware-check.sh` runs short checks against the tablets that are connected and skips what's already passed: every key, ring, strip, pen, and touch surface on a Wacom tablet, every Quick Keys and Pen Display control, a Bluetooth-to-USB switch compared across two builds, and, when asked for, pen latency while the Quick Keys updates its display. It builds the commits it needs and relaunches MockTab as it goes. The header lists the checks and options.

`key-order.sh` checks a Wacom tablet's key order for the Buttons pane's tablet diagram. It shows one key at a time where it sits on the tablet, records which control the tablet reports, and writes the result with each key's raw report. Keep MockTab running while it does.

## recording-check/

`run.sh` replays hid-recorder files of Wacom tablets through TabletKit's decoders. It compares each report with the tablet's own bits, read the way the Linux kernel reads them, and counts where they disagree: contact, proximity, eraser, barrel buttons, tool identity, pad keys, rings, strips, and touch. It also counts presses that merge, split, or appear from nothing, with the raw bytes of the worst. Run it before asking for a new capture, to see which report format needs the work. Pass the recordings as arguments; none ship with the repo.

## wacom-import/

`run.sh` reads a settings backup saved by Wacom Center or Tablet Utility (a `.wacomprefs` folder) and lists what each setting would become in MockTab, and what has no equivalent: pen and ExpressKey assignments, keystrokes, ring modes, the tablet area, and per-app settings. Keystrokes are looked up on the current keyboard layout, so run it on the Mac the settings came from.

With `--apply`, it then replaces one tablet's ExpressKeys, ring and dial modes, tablet area, pen buttons and pressure, and per-app settings with the Wacom ones. It asks first, saves the whole settings domain to Application Support, and prints the commands that undo it. Quit MockTab before writing. `--dry-run` shows the change without saving or writing anything. See `main.swift`'s header for the other options.

## latency/ and event-probe/

`latency/` measures the time from a tablet report to the cursor moving. `latency_ab.sh` compares MockTab with another driver, and `strain-bench.sh` measures MockTab with the CPU, GPU, or memory under load. `event-probe/` records the events a driver posts so you can find fields MockTab leaves out.
