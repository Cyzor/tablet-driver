# Architecture

How MockTab turns tablet reports into cursor movement, clicks, and gestures.

## Overview

Every few milliseconds, a tablet sends a small packet of bytes called a report. It says where the pen is, how hard it presses, which buttons are down, and sometimes where fingers touch. MockTab reads each report, works out what it means, and posts the matching mouse, tablet, and scroll events to macOS.

The work splits into two parts:

- **TabletKit** understands the bytes. It holds a decoder for each report format and a registry of known tablets. It lives in `TabletKit/`, a git submodule with its own repo and license (MPL-2.0).
- **The app** does everything else. It finds tablets, stores settings, posts events, and draws the settings window. It lives in `MockTab/` (GPL-3.0).

If a change is about what the bytes mean, it goes in TabletKit. If it's about what happens on screen, it goes in the app.

User documentation lives in `README.md`. Protocol notes live in `Notes/`.

## Two Threads

Pen input has to feel instant, so it never waits on the user interface.

Every report goes through its own thread, `HIDThread`, which runs at the highest priority macOS gives an app. That thread decodes the report and posts its events, start to finish. The main thread runs the settings window and everything else.

The two threads never change each other's data directly. When the pen thread needs to update the window, it sends the work to the main thread. When a setting changes, the main thread sends the pen thread a fresh copy of the settings, called a snapshot, and the pen thread uses it from the next report on.

## Following a Pen Report

Every pen report takes the same route:

```
tablet ─► WacomKnownDevice ─► decoder ─► TabletManager ─► InputInjector ─► macOS
```

The report arrives at `WacomKnownDevice.handleReport` in `Driver/Devices/WacomKnownDevice.swift`. That object stands for one connected tablet. It passes the bytes to the decoder for the format named in the tablet's registry entry.

The decoder returns a list of results: a pen position, a tool coming into range, a button press, a battery level. One report can produce several results. Bluetooth tablets often pack several pen positions into one report. `BatchFramePacer` spreads them over the time they cover, so the cursor glides instead of jumping.

Pen positions go to a closure that `TabletManager` set up when the tablet connected. If this tablet is the active one, the closure hands the position straight to `InputInjector`. If a different tablet was active, it makes this one active first.

`InputInjector.inject(point:settings:)`, in `Injection/InputInjector+PenInjection.swift`, turns the position into events. It works in a fixed order: smooth the pressure, handle the pen entering or leaving range, check for the eraser, smooth the position, handle panning, and then handle the tip and buttons. `Injection/InputInjector+CGEvents.swift` builds and posts the events themselves. Each pen movement posts a tablet event and a mouse event that carries pressure, because drawing apps read one or the other.

An open Info or Buttons pane gets a copy of the pen state a few times a second.

## Following a Settings Change

Settings live in `TabletSettings`, which the settings window edits directly.

When a setting changes, `TabletSettings.persist` saves it under that tablet's own prefix (`Settings/TabletSettings+Persistence.swift`). Meanwhile, `DeviceContext.observeInjectionSnapshot()` builds a new `InjectionSnapshot`, a frozen copy of everything the pen code reads, and sends it to the pen thread for the next report.

Adding a setting usually touches four things: the property in `TabletSettings`, how it's saved, the snapshot if the pen code needs it, and the pane that shows it.

## Following a Tablet Connecting

macOS presents a tablet as several separate devices, called interfaces: often one each for the pen, buttons, and touch. `TabletManager.deviceConnected(_:)` runs once for each.

First it works out which physical tablet the interface belongs to. A tablet can have different product IDs over USB, Bluetooth, and a wireless dongle, so all of them fold into the USB ID. The serial number then tells two identical tablets apart. That finds or creates the tablet's `DeviceContext`, which holds its settings, event injector, and driver.

Next it sets up the closures that receive pen, button, touch, and battery results for this tablet.

Then `DeviceRouter.route`, in `Driver/Devices/DeviceRouter.swift`, decides what the interface is: a new tablet that needs a driver, the touch or light half of a tablet that has one, a part that should wait for its sibling, or something to ignore.

The driver depends on how much MockTab knows about the tablet:

- **`WacomKnownDevice`** handles any tablet with an entry in `WacomDeviceRegistry` or `VendorDeviceRegistry`. That's almost all of them.
- **`WacomFallbackDevice`** handles Wacom tablets missing from the registry. It reads the tablet's own description of its reports and makes a best guess.
- **`GenericHIDDigitizer`** handles any standard pen tablet from any maker. macOS decodes the fields, and MockTab reads the results.

Last, `DeviceRegistry` records the tablet for the Devices pane, and its settings load.

## Following a Touch

Touch-capable tablets report finger contacts alongside the pen. They reach `InputInjector.injectTouch` in `Injection/InputInjector+Touch.swift`.

MockTab ignores touch while the pen is in range, so a resting palm can't move the cursor mid-stroke. Otherwise `TouchStateTracker` follows the contacts and decides what the user means: moving the pointer, tapping, scrolling, or pinching and rotating. The injector posts the matching events, and `MomentumTail` adds the coast after a flick when that's on.

On pen displays, the finger places the cursor directly, like a touchscreen.

## Telling Tablets Apart

MockTab identifies a tablet in two ways.

The model is the product ID, with Bluetooth and dongle IDs folded into the USB one. Decoders and registry entries work by model.

The unit is a `DeviceInstanceKey`: the model plus the USB serial number. Settings, windows, and menus work by unit, so two identical tablets keep separate settings.

The first unit of a model stores its settings under `device-0x{PID}.`. Any later unit gets `device-0x{PID}#{serial}.`. `Driver/Devices/DeviceInstanceClaims.swift` applies that rule. Each pen gets its own settings within its tablet's.

One limit: a Quick Keys remote pairs with a model, not a unit. Nothing in its reports says which unit it belongs to.

## Collecting Device Data

**Help › Collect Device Data…** records what a tablet sends while the user tries each control. Users report bugs with it, and MockTab learns new tablets from it.

`DiagnosticSession` runs two recorders at once. `CaptureEngine` summarizes which bytes changed and what they decoded to. `HIDCapture` logs the raw reports. Smaller probes in `Driver/Diagnostics/` note touch behavior, settings, and hardware details. `DiagnosticPackage` zips the results to the Desktop. `CaptureModels.swift` defines their format and the automatic findings that flag likely problems.

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

A few classes span several files, since stored properties must stay in the main file. `InputInjector` splits into pen, touch, buttons and dials, and event posting. `WacomKnownDevice` keeps the data it sends to tablets, like light and screen updates, in two extensions. `TabletSettings` splits saving, presets, and per-app settings into their own files.

## Testing

TabletKit's tests replay captured reports through each decoder and check the results. Run them with `cd TabletKit && swift test`. There are about 680, and they finish in about a second.

App logic that doesn't fit Xcode's test system has standalone checks in `tools/tests/`. Run them all with `tools/tests/run-all-tests.sh`. CI runs both.

## Rules to Keep

- **TabletKit reads nothing from the outside world.** No files, clocks, or shared state. The app passes in everything a decoder needs.
- **Pen-thread code doesn't touch main-thread data.** It hands that work to the main thread, and only when needed. Most reports need nothing from it.
- **Main-thread code doesn't touch pen-thread data.** It sends a new snapshot.
- **Messages to the tablet go out on the pen thread.** Light, screen, and brightness updates run through `DeviceContext.onHIDThread(_:)`, because the macOS calls that talk to a tablet aren't safe to use from two threads at once.
- **Events post from the pen thread.** macOS allows it, and it saves a delay.

## Where to Start

| To do this | Open this |
|---|---|
| Add a Wacom model in a known format | `TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift` and [`TabletKit/Extending-Support.md`](TabletKit/Extending-Support.md) |
| Add a pen | `TabletKit/Sources/TabletKit/Registry/WacomToolCatalog.swift` |
| Add another maker's tablet | `TabletKit/Sources/TabletKit/Registry/VendorDeviceRegistry.swift` |
| Add a new report format | A decoder in `TabletKit/Sources/TabletKit/Decoders/`, a `ReportParser` case, and its hookup in `WacomKnownDevice.init` |
| Fix how a tablet is recognized | `MockTab/Driver/Devices/DeviceRouter.swift` |
| Change how the pen behaves | `MockTab/Driver/Injection/InputInjector+PenInjection.swift` |
| Change what a button does | `MockTab/Driver/Injection/InputInjector+CGEvents.swift` |
| Change touch gestures | `MockTab/Driver/Injection/TouchStateTracker.swift` |
| Change smoothing | `TabletKit/Sources/TabletKit/Smoothing/` |
| Change screen mapping | `MockTab/Driver/Mapping/DisplayMapper.swift` |
| Add a setting | `MockTab/Settings/TabletSettings.swift`, `InjectionSnapshot.swift`, and the pane |
| Add a settings tab | `MockTab/UI/Panes/` and `SettingsWindowController.Tab` |
| Record something new in diagnostics | `MockTab/Driver/Diagnostics/CaptureModels.swift` |
