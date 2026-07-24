# Architecture

MockTab is a Mac driver for older Wacom drawing tablets. The notes below explain pen input, application operation, and project organization.

User documentation is available in `README.md`. Technical notes and protocol references reside in `Notes/`.

## Pipeline

Each pen sample travels a fixed path from the USB or Bluetooth bus to the WindowServer:

```
IOHIDManager
    │
    ▼  (HIDThread — dedicated background CFRunLoop)
WacomKnownDevice.handleReport  ──►  HIDCapture (diagnostic, opt-in)
    │                          ──►  CaptureEngine (delta capture, opt-in)
    ▼
TabletReportDecoder.decode(report, length, spec, state, family)
    │   returns [DecodeResult]: .pen / .aux / .toolEnter / .wireless / .battery …
    ▼
TabletDevice callbacks (onTablet / onAux / onToolEnter / …)
    │
    ▼  (TabletManager routes to the active context)
DeviceContext + InputInjector
    │
    ▼  smoothing, click resolution, modifier synthesis, delta gating
CGEvent  ──►  CGEventPost(.cghidEventTap)  ──►  WindowServer
```

Two threads carry live work. HIDThread owns the IOHIDManager run loop and every `handleReport` callback, running at the highest priority class macOS offers for app work so a busy main thread can never delay a pen sample (`HIDThread.swift` declares the singleton). Everything else — AppKit, SwiftUI, settings storage, most CGEvent posts — stays on the main thread. When HIDThread needs to hand work over, it has two options: `CFRunLoopPerformBlock(HIDThread.shared.runLoop, …)` for state writes the hot path will read back, or `Task { @MainActor in … }` for UI work.

What keeps these two sides from stepping on each other is the snapshot pattern. `TabletSettings` lives on the main thread and uses SwiftUI's `@Published` storage so views update automatically; when a setting changes, `makeInjectionSnapshot()` builds an immutable `InjectionSnapshot` and `DeviceContext` pushes it onto HIDThread. From there, `InputInjector` just reads its working copy — no cross-thread synchronization needed on the 133 Hz hot path.

## Layout

```
MockTab/
  App/         AppKit entry point, menu bar, top-level windows
  Driver/      App glue around the TabletKit decoder layer
               (HID transport, device routing, event injection)
  Settings/    Live settings, presets, calibration, profile load/save
  UI/
    Panes/     The tabs of the settings window
    Components/ Reusable views
  Help/        In-app help content
```

The decoder layer — `TabletReportDecoder`, the decoder structs, the device registries, and their pure-logic helpers — doesn't live in this tree at all; see the next section.

## TabletKit (SwiftPM package, git submodule)

The pure-logic decoder layer lives in the [TabletKit repo](https://github.com/Cyzor/TabletKit), an MPL-2.0 SwiftPM package checked out here as a git submodule at `TabletKit/`. It holds `TabletReportDecoder` (the protocol every decoder implements), the value types it speaks (`DecodeResult`, `TabletPoint`, `ToolIdentity`, `AuxButtons`, `TouchContact`, `WirelessStatus`, `DigitizerSpec`, `DecoderState`), `WacomDeviceRegistry`, `WacomToolCatalog`, `VendorDeviceRegistry`, the Wacom decoder structs (one per protocol family), and pure-logic helpers (`CursorSmoother`, `ModifierMath`). Nothing in TabletKit touches AppKit, SwiftUI, or app-wide state; the gear that does lives in this repo's `MockTab/Driver/` (`HIDThread`, `HIDCapture`, `CaptureEngine`, `InputInjector`, `TabletManager`, `DeviceContext`, the three `Wacom*Device` classes) plus everything under `Settings/` and `UI/`.

`MockTab.xcodeproj` consumes TabletKit through an `XCLocalSwiftPackageReference` that points at `TabletKit` (the submodule). Each app commit pins the exact TabletKit commit it builds against; clone with `--recurse-submodules` (or run `git submodule update --init`). Decoder work happens inside the submodule and is pushed to the TabletKit repo — push the kit before pushing an app commit that bumps the pin. Files in this repo that touch TabletKit types carry an explicit `import TabletKit`.

`swift test` runs the decoder suite from `TabletKit/`, not from this repo's root. The historical sidecar arrangement is gone.

## Driver

### Devices

Three device wrappers sit between IOHIDManager and the decoders. Each schedules its own HID device on `HIDThread.shared.runLoop`.

- `WacomKnownDevice` — a tablet whose VID/PID matches an entry in `WacomDeviceRegistry`. Carries the device's `DigitizerSpec` and a decoder instance. The common case.
- `WacomFallbackDevice` — a Wacom-vendor tablet with no registry entry. Reads the HID descriptor and synthesizes a best-effort spec.
- `WacomProbeDevice` — a one-shot probe that captures the descriptor for unknown-device discovery, then unschedules itself.

`VendorDeviceRegistry` covers non-Wacom vendors with a similar shape.

### Decoders

Each decoder conforms to `TabletReportDecoder`:

```swift
mutating func decode(
    report: UnsafePointer<UInt8>,
    length: CFIndex,
    spec: DigitizerSpec,
    state: inout DecoderState,
    deviceFamily: String
) -> [DecodeResult]
```

Decoders parse a single report and emit zero or more `DecodeResult` values. The host (`WacomKnownDevice.handleReport`) owns the `DecoderState` and routes results to the `TabletManager` callbacks.

Adding support for a new Wacom variant of an existing family means (all edits happen in the `TabletKit/` submodule):

1. Add a row to `WacomDeviceRegistry` (and/or `WacomToolSpec` for new pen tools) with the VID/PID and physical dimensions.
2. Add a fixture to the matching `*DecoderTests.swift` file under `Tests/TabletKitTests/`.

Adding a new family means writing a new decoder under `Sources/TabletKit/Decoders/`, adding a `ReportParser` case for it, wiring that case to the decoder in `MockTab/Driver/WacomKnownDevice.swift`, and adding a test file. MockTab picks up the change automatically through the local package dep.

### Injection

`InputInjector` converts a `TabletPoint` into the CGEvent sequence apps expect: a proximity event, then a `.tabletPointer` event (which Krita, GIMP, and other Qt/GTK apps consume directly), then a mouse event carrying pressure via `.mouseEventPressure` and `.mouseEventSubtype = .tabletPoint`. Two self-contained transforms live outside the class entirely — position smoothing (`CursorSmoother`, in TabletKit) and display selection/orientation/calibration (`DisplayMapper.swift`, in this repo). The class itself spans five files. `InputInjector.swift` holds every stored property (Swift extensions can't) plus the concerns that read broadly across that state:

- click-count resolution for double- and triple-clicks
- a brief mouse-up delay so fast pen lifts don't cut strokes short
- a watchdog that releases buttons left stuck by a dropped report
- a system-level tap that tracks physical modifier-key state
- the Adobe shim replay and USB mouse-button injection

Four sibling extensions divide the rest of the class by concern: `InputInjector+PenInjection.swift` (the per-report pen hot path), `InputInjector+Touch.swift` (capacitive finger touch), `InputInjector+AuxInput.swift` (express keys, rings, wheels), and `InputInjector+CGEvents.swift` (modifier synthesis and reconciliation, the event constructors, button-binding execution, and scroll dispatch). The class header in `InputInjector.swift` documents the threading rules; the main file's MARK sections cross-reference the extension that owns each state block's logic.

### Aux inputs

Everything that isn't the pen — express keys, touch rings, dials, and a device's own onboard bezel buttons — decodes into `AuxButtons` and flows through `TabletManager.onAux` into `InputInjector.injectAux`. Slot layout is a shared convention: indices 0–15 are express keys, 16–18 are bezel buttons (e.g. the Cintiq DTK-2400's capacitive OSD keys or the Xencelabs Pen Display's bezel buttons), and each range has its own binding array in `TabletSettings` (`expressKeyBindings`, `bezelButtonBindings`).

Standalone aux-only peripherals (currently the Xencelabs Quick Keys puck) are *companion devices*: `VendorDeviceRegistry.connectedCompanion` pairs them with the pen-bearing device they belong to, and their controls fold into that device's settings window instead of getting their own. Battery status from wireless devices arrives as a `.battery` decode result and surfaces in the UI the same way.

### Routing

`TabletManager` runs on the main thread, owns the set of live devices, decides which one is the active context, and forwards decoded events into that context's `InputInjector`. `DeviceContext` holds the per-device state that the injector needs and is the object that pushes snapshots onto HIDThread.

### Device identity

Identity has two axes. The **model** axis is the USB product ID: decoders, `DigitizerSpec` lookups, capability tables, and companion relationships all key on it, matching how Wacom's own tables and libwacom work. The **instance** axis is `DeviceInstanceKey` (`MockTab/Driver/DeviceInstanceKey.swift`): the canonical PID plus an instance token (USB serial, with a locationID fallback held in reserve), so two physical units of the same model stay distinct. Contexts (`TabletManager.deviceContexts`), registry rows, settings windows, menu entries, and the panes all key on the instance; `TabletManager.contexts` remains as a PID-keyed compatibility view for model-level callers.

Settings storage follows the *claim-the-legacy-prefix* rule (`DeviceRegistry.settingsPrefix(for:)`): the first unit ever seen for a model permanently claims the historical `device-0x{PID}.` UserDefaults prefix — existing installs keep every setting without migration — and any additional unit of the same model gets a fresh `device-0x{PID}#{instance}.` namespace. A key with no instance token resolves to the legacy prefix, which is exactly the old PID-only behavior.

One known limitation: a companion peripheral (Quick Keys puck) is paired to its owner at the model level, because nothing in the wire protocol identifies *which* unit it belongs to. With two identical pen tablets and one puck, the app picks the first pen-bearing unit — inherently ambiguous, documented rather than papered over with pairing UI.

## Settings

`TabletSettings` lives on the main thread and acts as the single source of truth that SwiftUI views observe: pen-feel curves, button bindings, calibration, display mapping, per-app overrides, profiles. The class spans four files: `TabletSettings.swift` holds the stored properties, init, per-device loading, and undo/redo, while `TabletSettings+Presets.swift`, `TabletSettings+AppOverrides.swift`, and `TabletSettings+Persistence.swift` hold preset handling, per-app behavior, and the UserDefaults layer. The value types it stores (`ButtonBinding`, `ControlSlot`, `TabletOrientation`) each have their own file. `Settings/Profile.swift` and `Settings/PresetExporter/Importer` handle the JSON shape that ships in releases (`example-profile.json`).

The settings layer calls `DeviceContext.observeInjectionSnapshot(…)` whenever a relevant value changes; `DeviceContext` packages the snapshot and hands it across.

## UI

The settings window hosts a tab bar; each tab maps to one file in `UI/Panes/`. Each pane corresponds to a settings concern: Devices, Tablet Area, Display Mapping, Pen Feel, Button Mapping, Touch, Scratchpad, Profiles, Info. `UI/Components/` holds widgets that more than one pane uses (the disclosure row, the orientation picker, the tablet color theme, the SVG-driven pen and ring diagrams).

## Tests

The decoder test suite lives in `TabletKit/Tests/TabletKitTests/` and runs via `swift test` from the submodule (`cd TabletKit && swift test`). Each decoder has its own fixture suite; the `CaptureLogParser` replays the logs the in-app `HIDCapture` writes, so regressions surface as diff-able test failures. The suite (300+ tests — see CI for the current count) runs in well under a second.

## Threading rules (the short version)

- **Anything in TabletKit** (every conformer of `TabletReportDecoder`, the registries, the value types) lacks I/O, clocks, and globals. The host owns `DecoderState`.
- **Anything reachable from `handleReport`** runs on HIDThread. It must not touch main-thread state directly — hand the work over with `Task { @MainActor in … }` or `CFRunLoopPerformBlock` first.
- **Anything marked `@MainActor`** runs on the main thread. It updates HIDThread state by packaging a snapshot and posting it onto `HIDThread.shared.runLoop`.
- **`IOHIDDeviceSetReport` / `GetReport`** are not thread-safe; they run on the main thread. Devices defer LED writes and feature reports to the main thread via `DispatchQueue.main.async`.
- **`CGEventPost`** is safe to call from HIDThread, and `InputInjector` does, to avoid a hop to the main thread on the hot path.

## Where to start

| Goal | File to open first |
|------|--------------------|
| Add a Wacom model in an existing family | `TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift` |
| Add a new pen tool | `TabletKit/Sources/TabletKit/Registry/WacomToolSpec.swift` |
| Add a non-Wacom vendor | `TabletKit/Sources/TabletKit/Registry/VendorDeviceRegistry.swift` |
| Add a new protocol family | `TabletKit/Sources/TabletKit/Decoders/` + `ReportParser` case wired in `MockTab/Driver/WacomKnownDevice.swift` |
| Tweak click resolution | `MockTab/Driver/InputInjector.swift` (read the header) |
| Tweak button dispatch or modifier synthesis | `MockTab/Driver/InputInjector+CGEvents.swift` |
| Tweak position smoothing | `TabletKit/Sources/TabletKit/Smoothing/CursorSmoother.swift` |
| Tweak display mapping or calibration | `MockTab/Driver/DisplayMapper.swift` |
| Add a settings knob | `Settings/TabletSettings.swift` + relevant pane |
| Add a new settings pane | `UI/Panes/` + `App/SettingsWindowController.swift` |
| Diagnose a misbehaving tablet | Settings → Info → Start Capture (writes to Desktop) |