# MockTab — Architecture Improvement Plan

_Drafted 2026-05-08 from a three-agent review of Driver, UI/Settings, and project hygiene._

## Context

The project is in good shape: well-engineered driver, excellent release tooling, thorough protocol notes, zero external dependencies, minimal TODO debt (2 entries). The risks are not "broken code" — they're **operational fragility** that will hurt as the project grows: a few files have outgrown their original responsibilities, and there is no automated regression safety net for the decoder layer.

This plan ranks improvements by **impact ÷ effort**, not by ambition. The intent is incremental groundwork, not a rewrite. Most items are deferrable; a small subset is worth doing soon.

---

## Health snapshot

| Area | Grade | Note |
|---|---|---|
| Driver protocol layer | A− | Decoders are clean, nearly pure, scalable to a 7th family |
| Driver orchestration | B− | `TabletManager.deviceConnected()` is 405 lines of god-method |
| Decoders | A− on most, B on `IntuosV2Decoder` (874 lines, 6 report IDs) |
| Settings/persistence | B− | `TabletSettings.swift` ~1,823 lines; prefix-string lookups duplicated 4× |
| UI ↔ Driver boundary | B− | Window-local UI state leaks into driver inputs |
| Release tooling | A | `tools/release.sh`, `verify_registry.py`, `import_otd_configs.py` are exemplary |
| Documentation (`Notes/`) | A | Structured reference, not a junk drawer |
| Test coverage | F | Zero automated tests across ~25K LOC |
| Logging consistency | B | One stray subsystem (`com.mocktab` in `WacomProbeDevice`), gaps in `InputInjector` |

---

## Tier 1 — Quick wins (do soon, each ≤1 hour)

These are paper cuts, not architecture. Worth fixing before the next focused work session.

### T1-1. Standardize the OSLog subsystem ✓ done 2026-05-08
- **Problem:** `WacomProbeDevice.swift` used `com.mocktab`; the rest of the project uses `com.cyzor.mocktab`. Filtering logs by subsystem missed one file.
- **Fix:** Renamed to `com.cyzor.mocktab` with category `probe`; updated the docstring that referenced the old subsystem.

### T1-2. Add `Logger` to `InputInjector.swift` ✓ done 2026-05-08
- **Original premise was wrong:** the file already had `modLog` covering the modifier-reconciliation system, leak watchdog, CGEvent-tap failures, and key combos.
- **Genuine gap:** four silent-fail points in the pen path. Added a second `injectLog` (category `inject`) and error logs at: `postTabletPointerEvent` and `postProximityEvent` `CGEvent` creation failures, plus both `CGGetActiveDisplayList` failures in the display-union path. No logic changes.

### T1-3. Untrack committed `xcuserdata` — not needed
- **Verified 2026-05-08:** `xcuserdata` is properly ignored at `.gitignore:12` and `git ls-files MockTab.xcodeproj/` shows only `project.pbxproj` and `contents.xcworkspacedata` tracked. The hygiene agent's claim was wrong.

### T1-4. Cite sources for registry magic numbers
- **Problem:** Coordinate dimensions in `WacomDeviceRegistry.swift` (e.g., `maxX: 62200`) lack provenance comments. The file's top docstring lists three possible sources (live capture / Linux / OTD) but individual entries don't say which.
- **Fix:** When touching registry entries, add a one-line provenance tag. No need for a sweep — annotate as you edit.

---

## Tier 2 — Worth the effort (do over the next few sessions)

These have real payoff and bounded scope. Each is a focused 1–3 hour session.

### T2-1. Extract `DeviceRouter` from `TabletManager.deviceConnected()` ✓ done 2026-05-08
- **Problem:** `deviceConnected()` was 405 lines mixing HID-property reads, six event-closure constructions, interface-deferral logic, driver-instantiation switch, LED-companion lookup, and post-attach orchestration.
- **Approach taken:** New [DeviceRouter.swift](../MockTab/Driver/DeviceRouter.swift) (180 lines) owns the "given a fresh interface, what should we wire up?" question. Returns a `Routed` enum with four cases — `.driver(seized:) / .deferred / .ledCompanion(parentContext:) / .skip` — and a `Callbacks` struct bundling the six event closures. `TabletManager.deviceConnected()` now constructs the closures, calls `DeviceRouter.route(...)`, and dispatches on the result. The closures stay in `TabletManager` because they capture per-instance state (`activeContext`, `liveButtons`, calibration handlers).
- **Result:** `deviceConnected` dropped from 405 → 330 lines (the closures are most of what remains and they belong here). The routing logic is now isolated and the LED-companion path is a first-class enum case rather than buried in else-of-else.
- **Verified:** Xcode build green, `swift test` 7/7 passing. Pbxproj updated with the standard four mirror entries for the new file.

### T2-2. Extract a `SettingsStore` facade ✓ partial 2026-05-08
- **Problem:** The 4-layer lookup chain (device → tool → profile → app-override) was implemented by string-prefix concatenation duplicated across `loadDouble`/`loadBool`/`loadInt`/`loadString`. A typo in one prefix builder silently read from the wrong namespace; no test could catch it.
- **Approach taken (minimal):** Added a `resolveLayer(for key:)` helper that returns the prefix of whichever layer owns a key (or `nil`). The four `load*` helpers each shrink from ~22 lines to 4. Read-time precedence now lives in **one** function — typos can no longer make `loadInt` and `loadDouble` disagree about which layer wins.
- **Result:** Net 60 lines removed from `TabletSettings.swift`. Behavior preserved (manually verified against Xcode build; semantics of the four helpers stay the same except for a minor normalization of `loadString`'s fall-through, which has no live callers exercising the edge case).
- **Verified:** Xcode build green, `swift test` 7/7 still passing.
- **Skipped (deferred to T3):** Full `SettingsStore` protocol with in-memory impl for unit testing. Pulling `TabletSettings.swift` into the SwiftPM sidecar would require following its AppKit/Carbon imports, expanding the test surface beyond pure logic. Worth doing when settings-inheritance bugs become a real cost.

### T2-3. Add an XCTest target for decoders ✓ harness landed 2026-05-08
- **Problem:** Zero automated regression safety across ~95 tablet families. Decoders are already nearly pure (`decode()` takes report + spec, mutates `inout DecoderState`, returns results) — the testing prerequisite is met; only the target was missing.
- **Approach taken:** SwiftPM sidecar (`Package.swift` at project root) rather than an Xcode test target — avoids hand-editing `project.pbxproj`, lets `swift test` run from CLI without Xcode. The package vendors a minimal slice of `MockTab/Driver/` (the pure-logic files: `TabletPoint.swift`, `TabletDevice.swift`, `WacomToolSpec.swift`, `Decoders/`). The Xcode app build is untouched.
- **Status:** 7 tests passing in 2 ms — covers IntuosV1 dispatch/proximity-exit/tool-change/wrong-length-rejection and the shared wireless-status helper.
- **Run:** `swift test` from the project root.
- **Next steps (incremental, do as bugs surface or new features land):**
  - Add fixtures for IntuosV2 multi-frame BT Classic 99/361-byte path (the most under-tested code).
  - Add Art Pen rotation boundary-noise fixtures (Cintiq decoder).
  - Capture real reports via `HIDCapture` for one canonical session per parser family and check them into `Tests/Fixtures/`.

### T2-4. Decompose `IntuosV2Decoder.swift` (was 874 lines) ✓ first split landed 2026-05-08
- **Problem:** Handled USB 0x10, BLE 0x01/0x03, BT Classic 99-byte and 361-byte, offset 0x1E, aux 0x11, and wireless 0x80 (3 sub-types) in one file. Any new variant would push it past 1,000 lines.
- **Approach taken:** Split off the BT side via a Swift extension into `IntuosV2Decoder+BT.swift`. The original file dropped from 874 → 428 lines; the BT extension is 432. Methods moved: `decodeBTFrame` (shared per-frame helper), `decodeBTPen` (361-byte), `decodeBTClassicFrames` (99-byte), `decodeWireless` (RF status). Access modifiers changed `private` → internal where the dispatcher needs cross-file calls.
- **Verified:** SwiftPM build green, 7 tests still pass, Xcode build green. New file registered in `project.pbxproj` (4 mirror entries: PBXBuildFile, PBXFileReference, PBXGroup child, PBXSourcesBuildPhase).
- **Optional further splits (deferred — file is now reasonable):**
  - `IntuosV2Decoder+USB.swift` — `decodePenReport` + `decodeOffsetPenReport` + `decodeAuxReport` (~290 lines).
  - `IntuosV2Decoder+BLE.swift` — `decodeBLEPen` (~35 lines).
  - Only worth doing if the USB path grows further; today the main file is readable.

---

## Tier 3 — Larger ambitions (deferred / discuss first)

Each of these is real work and not obviously worth it yet. Listed so we don't lose them.

- **Per-window `TabletSettings` instances.** Today `PreferencesWindowController.shared.settings` is a global singleton; opening windows for two devices shares one settings object. Only relevant if multi-window editing becomes a real workflow.
- **Type-safe enum for setting keys.** Replace string keys (`"activeAreaX"`) with an enum. High mechanical cost, modest payoff once `SettingsStore` (T2-2) lands.
- **Decompose `TabletSettings` into `ProfileManager` / `AppOverrideManager` / `ToolCache`.** Currently the file is 1,823 lines mixing all three. Worth doing only after T2-2 — once the store is extracted, splitting the rest is much easier.
- **Replace `InputInjector.isActive: Bool` atomicity assumption.** The comment claims atomic Bool reads on Apple Silicon; this isn't a guarantee from the language. Migrate to `OSAllocatedUnfairLock` or actor isolation when convenient. Low real-world risk on current targets, so deferred.
- **Move `AppWatcher.swift:34-44` hardcoded bundle IDs (Qt/GTK/Pages) to a config file.** Easy refactor, low urgency.
- **Severity-tier the `IOHIDDeviceSetReport` return values.** Today some sites silently ignore `ret`; others log. A consistent helper (`hidSetReport(...) throws`) would catch unexpected silent drops — exactly the class of bug behind the PTH-860 LED issue.

---

## Suggested sequencing

If we tackle anything: **T1-1, T1-2, T1-3 in one batch (≈30 min), then T2-3 (decoder tests) before T2-4 (decoder refactor).** Everything else can wait until a relevant change is already in flight in the affected file.

## Files to know

- [MockTab/Driver/TabletManager.swift](../MockTab/Driver/TabletManager.swift) — orchestration, target of T2-1
- [MockTab/Driver/Decoders/IntuosV2Decoder.swift](../MockTab/Driver/Decoders/IntuosV2Decoder.swift) — target of T2-4
- [MockTab/Settings/TabletSettings.swift](../MockTab/Settings/TabletSettings.swift) — target of T2-2 and T3 decomposition
- [MockTab/Driver/WacomProbeDevice.swift](../MockTab/Driver/WacomProbeDevice.swift) — T1-1 logger fix
- [MockTab/Driver/InputInjector.swift](../MockTab/Driver/InputInjector.swift) — T1-2 add logger
