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

Two threads carry live work:

- **HIDThread** owns the IOHIDManager run loop and every `handleReport` callback. The thread runs at the highest priority class macOS offers for app work, so a busy main thread cannot delay a pen sample. `HIDThread.swift` declares the singleton.
- **Main thread** owns AppKit, SwiftUI, settings storage, and most CGEvent posts. The HID thread hands work to the main thread two ways: `CFRunLoopPerformBlock(HIDThread.shared.runLoop, …)` for state writes the hot path will read back, or `Task { @MainActor in … }` for UI work.

The **snapshot pattern** keeps the two sides loosely coupled. `TabletSettings` lives on the main thread and uses SwiftUI's `@Published` storage so views update automatically. When a setting changes, `makeInjectionSnapshot()` builds an immutable `InjectionSnapshot` and `DeviceContext` pushes it onto HIDThread. `InputInjector` then reads its working copy with no cross-thread synchronization on the 133 Hz hot path.

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

The decoder layer (`TabletReportDecoder`, the decoder structs, `WacomDeviceRegistry`, `WacomToolCatalog`, `VendorDeviceRegistry`, pure-logic helpers) lives in the **TabletKit** SwiftPM package, included as a git submodule at `TabletKit/` and consumed as a local package dependency. Tests for the decoder layer (`swift test`) run from the submodule, not from this repo's root.

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

Adding a new family means writing a new decoder under `Sources/TabletKit/Decoders/`, wiring it in `WacomDeviceRegistry.decoder(for:)`, and adding a test file. MockTab picks up the change automatically through the local package dep.

### Injection

`InputInjector` converts a `TabletPoint` into the CGEvent sequence apps expect: a proximity event, then a `.tabletPointer` event (which Krita, GIMP, and other Qt/GTK apps consume directly), then a mouse event carrying pressure via `.mouseEventPressure` and `.mouseEventSubtype = .tabletPoint`. The class also owns:

- the exponential-moving-average position smoother (`CursorSmoother`)
- click-count resolution for double- and triple-clicks
- synthesizing keyboard modifiers when a tablet button is bound to one
- a brief mouse-up delay so fast pen lifts don't cut strokes short
- a watchdog that releases buttons left stuck by a dropped report
- a system-level tap that tracks physical modifier-key state

The class header in `InputInjector.swift` documents the threading rules; the MARK sections divide the file by concern.

### Routing

`TabletManager` runs on the main thread, owns the set of live devices, decides which one is the active context, and forwards decoded events into that context's `InputInjector`. `DeviceContext` holds the per-device state that the injector needs and is the object that pushes snapshots onto HIDThread.

## Settings

`TabletSettings` lives on the main thread and acts as the single source of truth that SwiftUI views observe: pen-feel curves, button bindings, calibration, display mapping, per-app overrides, profiles. `Settings/Profile.swift` and `Settings/PresetExporter/Importer` handle the JSON shape that ships in releases (`example-profile.json`).

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
| Add a Wacom model in an existing family | `TabletKit/Sources/TabletKit/WacomDeviceRegistry.swift` |
| Add a new pen tool | `TabletKit/Sources/TabletKit/WacomToolSpec.swift` |
| Add a non-Wacom vendor | `TabletKit/Sources/TabletKit/VendorDeviceRegistry.swift` |
| Add a new protocol family | `TabletKit/Sources/TabletKit/Decoders/` + `WacomDeviceRegistry.decoder(for:)` |
| Tweak smoothing / click resolution | `MockTab/Driver/InputInjector.swift` (read the header) |
| Add a settings knob | `Settings/TabletSettings.swift` + relevant pane |
| Add a new settings pane | `UI/Panes/` + `App/SettingsWindowController.swift` |
| Diagnose a misbehaving tablet | Settings → Info → Start Capture (writes to Desktop) |