# Architecture

How MockTab turns tablet reports into cursor movement, clicks, and gestures.

## Overview

Every few milliseconds, a tablet sends a small packet of bytes called a report. It says where the pen is, how hard it presses, which buttons are down, and sometimes where fingers touch. MockTab reads each report, works out what it means, and posts matching events to macOS.

The work splits into two parts:

- **TabletKit** (`TabletKit/`, MPL-2.0) understands the bytes. It holds a decoder for each report format and a registry of known tablets. It's a git submodule with its own repo.
- **The app** (`MockTab/`, GPL-3.0) does everything else: finds tablets, stores settings, posts events, and draws the settings window.

If a change is about what the bytes mean, it goes in TabletKit. If it's about what happens on screen, it goes in the app.

## Two Threads

Pen input never waits on the user interface. Each report goes through `HIDThread`, which runs at the highest priority macOS gives an app and handles the report from start to finish. The main thread runs the settings window and everything else.

Neither thread changes the other's data. The pen thread sends window updates to the main thread. When a setting changes, the main thread sends the pen thread a fresh copy of the settings, called a snapshot.

## Following a Pen Report

```
tablet ─► WacomKnownDevice ─► decoder ─► TabletManager ─► InputInjector ─► macOS
```

1. `WacomKnownDevice.handleReport` receives the bytes for one connected tablet and passes them to the decoder its registry entry names.
2. The decoder returns a list of results: pen positions, a tool coming into range, button presses, battery level. Bluetooth tablets often pack several positions into one report, and `BatchFramePacer` spreads them out so the cursor glides.
3. A closure that `TabletManager` set up at connect time hands each position to `InputInjector`, making this tablet the active one first if needed.
4. `InputInjector+PenInjection.swift` smooths pressure, handles range and the eraser, smooths position, handles panning, then handles the tip and buttons. `InputInjector+CGEvents.swift` posts the events. Each movement posts both a tablet event and a mouse event carrying pressure, because drawing apps read one or the other.

## Following a Settings Change

The settings window edits `TabletSettings` directly. `TabletSettings.persist` saves each change under that tablet's own prefix. `DeviceContext.observeInjectionSnapshot()` then builds a new `InjectionSnapshot`, a frozen copy of everything the pen code reads, for the next report.

A new setting usually touches four things: the property, how it's saved, the snapshot if the pen code needs it, and the pane that shows it.

## Following a Tablet Connecting

macOS presents one tablet as several devices, called interfaces, often one each for the pen, buttons, and touch. `TabletManager.deviceConnected(_:)` runs once for each:

1. It finds which physical tablet the interface belongs to and finds or creates its `DeviceContext`, which holds the tablet's settings, injector, and driver.
2. It sets up the closures that receive this tablet's pen, button, touch, and battery results.
3. `DeviceRouter.route` decides what the interface is: a new tablet, the touch or light half of a known one, a part that should wait for its sibling, or something to ignore.
4. A new tablet gets one of three drivers:
   - **`WacomKnownDevice`** for any tablet in the registry, which is almost all of them.
   - **`WacomFallbackDevice`** for Wacom tablets missing from it. It reads the tablet's own description of its reports and makes a best guess.
   - **`GenericHIDDigitizer`** for standard pen tablets from any maker. macOS decodes the fields.
5. `DeviceRegistry` lists the tablet in the Devices pane, and its settings load.

## Following a Touch

Finger contacts reach `InputInjector+Touch.swift`. MockTab ignores touch while the pen is in range, so a resting palm can't move the cursor mid-stroke. Otherwise `TouchStateTracker` works out what the user means: pointing, tapping, scrolling, pinching, or rotating. `MomentumTail` adds the coast after a flick. On pen displays, a finger places the cursor directly, like a touchscreen.

## Telling Tablets Apart

- **The model** is the product ID. A tablet can have different IDs over USB, Bluetooth, and a wireless dongle, so all of them fold into the USB one. Decoders and registry entries work by model.
- **The unit** is a `DeviceInstanceKey`: the model plus the serial number. Settings, windows, and menus work by unit, so two identical tablets keep separate settings.

The first unit of a model saves its settings under `device-0x{PID}.`, and later ones under `device-0x{PID}#{serial}.`, as `DeviceInstanceClaims.swift` decides. Each pen gets its own settings within its tablet's.

A Quick Keys remote pairs with a model, not a unit, because nothing in its reports says which unit it belongs to.

## Collecting Device Data

**Help › Collect Device Data…** records what a tablet sends while the user tries each control. Users report bugs with it, and MockTab learns new tablets from it.

`DiagnosticSession` runs two recorders: `CaptureEngine` summarizes which bytes changed and what they decoded to, and `HIDCapture` logs the raw reports. Smaller probes in `Driver/Diagnostics/` add touch behavior, settings, and hardware details. `DiagnosticPackage` zips it all to the Desktop. `CaptureModels.swift` defines the format and the automatic findings that flag likely problems.

## Where Things Live

```
TabletKit/Sources/TabletKit/
  Core/          The values decoders produce
  Decoders/      One file per report format
  Registry/      Known tablets, other makers, pens
  HID/           The pen thread and report-description parsing
  Smoothing/     Cursor, pan, and pressure smoothing
  Output/        Data sent to tablets: lights, small screens, display controls

MockTab/
  App/           Startup, menus, and windows
  Driver/
    Devices/     Connecting tablets and telling them apart
    Injection/   Turning input into events
    Mapping/     Which part of which screen the tablet covers
    Diagnostics/ Collect Device Data
  Settings/      TabletSettings and the values it stores
  UI/Panes/      One folder per settings tab
```

Swift extensions can't add stored properties, so a few large classes keep their data in the main file and split their behavior across extensions: `InputInjector` (pen, touch, tablet buttons and dials, event posting), `WacomKnownDevice` (data sent to tablets), and `TabletSettings` (saving, presets, per-app settings).

## Testing

- **TabletKit:** `cd TabletKit && swift test` replays captured reports through each decoder. It finishes in about a second.
- **App:** `tools/tests/run-all-tests.sh` runs standalone checks for logic that doesn't fit Xcode's test system.

CI runs both.

## Rules to Keep

- **TabletKit reads nothing from the outside world.** No files, clocks, or shared state. The app passes in everything a decoder needs.
- **Neither thread touches the other's data.** The pen thread hands work to the main thread, and the main thread sends a new snapshot.
- **Messages to a tablet go out on the pen thread,** through `DeviceContext.onHIDThread(_:)`. The macOS calls that talk to a tablet aren't safe from two threads at once.
- **Events post from the pen thread.** macOS allows it, and it saves a delay.

## Where to Start

| To do this | Open this |
|---|---|
| Add a Wacom model in a known format | `WacomDeviceRegistry.swift` and [`Extending-Support.md`](TabletKit/Extending-Support.md) |
| Add a pen | `WacomToolCatalog.swift` |
| Add another maker's tablet | `VendorDeviceRegistry.swift` |
| Add a new report format | A decoder in `Decoders/`, plus a `ReportParser` case and its line in `makeDecoder()` |
| Fix how a tablet is recognized | `DeviceRouter.swift` |
| Change how the pen behaves | `InputInjector+PenInjection.swift` |
| Change what a tablet button, ring, or dial does | `InputInjector+AuxInput.swift` |
| Change touch gestures | `TouchStateTracker.swift` |
| Change smoothing | TabletKit's `Smoothing/` |
| Change screen mapping | `DisplayMapper.swift` |
| Add a setting | `TabletSettings.swift`, `InjectionSnapshot.swift`, and the pane |
| Add a settings tab | `UI/Panes/` and `SettingsWindowController.Tab` |
| Record something new in diagnostics | `CaptureModels.swift` |

User documentation lives in `README.md`. Protocol notes live in `Notes/`.
