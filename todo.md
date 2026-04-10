# MockTab — Open Tasks & Project Status

_Last updated: 2026-04-09 (Session 29 — Eraser Binding Fix + Menu Bar App COMPLETE)_

---

## ✅ DONE IN SESSION 29

- [x] Eraser binding bug: InputInjector activeToolIsEraser caching (2026-04-09)
- [x] Eraser binding bug: TabletManager onToolEnter propagation (2026-04-09)
- [x] Eraser binding bug: IntuosV2Decoder revert to status-bit reads (2026-04-09)
- [x] Menu bar app: setActivationPolicy from showInDock UserDefaults (2026-04-09)
- [x] Menu bar app: Launch at Login toggle with ServiceManagement (2026-04-09)
- [x] Menu bar app: Show in Dock toggle with runtime policy change (2026-04-09)
- [x] Menu bar app: NSApp.activate in window-show methods (2026-04-09)
- [x] Eraser now fires correctly on all devices and binding modes (2026-04-09)

---

## ✅ DONE IN SESSION 28

- [x] DeviceContext per-device observable state: 8 @Published properties added (2026-04-09)
- [x] TabletManager state propagation: objectWillChange subscription + per-device writes (2026-04-09)
- [x] DeviceStatusBar: replaced PresetStatusBar with device-specific footer (2026-04-09)
- [x] All views: added productID parameter + updated call sites (2026-04-09)
- [x] InfoView status table: per-device context reads instead of global active state (2026-04-09)
- [x] Multi-tablet window state isolation: strict per-device reporting (2026-04-09)
- [x] Window title uniformity: deferred to Session 29 (2026-04-09)
- [x] ButtonMappingView background color: deferred to Session 29 (2026-04-09)

---

## ✅ DONE IN SESSION 24

- [x] One-window-per-tablet policy: enforced strict window-tablet binding (2026-04-06)
- [x] Per-app overrides (Smooze model): app-specific settings with override bar in all 6 tabs (2026-04-06)
- [x] App picker redesign: running-apps menu + drag-drop app icon support (2026-04-06)
- [x] App chip drag-to-reorder/remove: fully functional (2026-04-06)
- [x] Pen diagram in ButtonMappingView: visual stylus with live button feedback (2026-04-06)
- [x] Tilt tracking: added to DecoderState for future per-pen features (2026-04-06)
- [x] Art Pen fixes: rotation reset-to-0° + barrel debounce + touch ring seam detection (2026-04-06)
- [x] Battery level reporting: BT devices report battery state to UI (2026-04-06)
- [x] Semantic font naming: consistent typography across UI (2026-04-06)
- [x] Branch merge: feature/per-app-overrides → main (8+ commits) (2026-04-06)

---

## ✅ DONE IN SESSION 23

- [x] Factory Reset dialog: Return + Command-R both activate button (2026-04-03)
- [x] Factory Reset state clearing: skipNextWindowSave() + NSWindow frame cache cleanup (2026-04-03)
- [x] Sticky modifier key prevention: hidSystemState + activeSyntheticFlags (2026-04-03)
- [x] Branch merge: test/kernel-spec-alignment → main (20+ commits) (2026-04-03)

---

## Hardware Verification Pending

These fixes have been implemented and compiled, awaiting live hardware testing to confirm correct behavior:

### 🟡 PTH-860 Bluetooth Classic — decoder implemented (2026-03-29)
The PTH-860 advertises two separate BT personalities:
- `LE IntuosPro L` (BLE/HOGP) — Paper Mode only, not the digitizer path
- `BT IntuosPro L` (Bluetooth Classic) — **full digitizer, correct interface**

**Decoder implemented:** `decodeBTClassicFrames` in `IntuosV2Decoder` handles `INTUOSP2_BT` format — 99-byte reports, 7 × 14-byte frames, dispatched by packet length.

**Still unknown — needs hardware testing:**
- PTH-860 BT Classic PID (PTH-660: 0x0357→0x0360; PTH-860: 0x0358→?)
- Pad reports over BT Classic
- Pressure validation

### 🟡 DTK-2400 pen decoder — revised per kernel spec (2026-03-28)
Barrel buttons, eraser detection, hover distance, and Art Pen rotation now match Linux kernel `wacom_intuos_general()` / `WACOM_24HD`. Needs hardware verification for correct behavior.

### 🟡 IntuosV1/Intuos3/IntuosV2 decoder fixes — revised per kernel spec (2026-03-28)
Eraser detection, hover distance, and pressure normalization now match kernel. PTH-851, PTZ-631W, and PTH-660/860 need re-verification for eraser, hover, and pressure feel.

---

## Undo/Redo (Cmd+Z / Cmd+Shift+Z) — ✅ COMPLETE (2026-03-29)

Implemented NSUndoManager-based undo/redo for all settings views:

- ✅ TabletAreaView: drag coalescing, reset button, proportional toggle
- ✅ PressureCurveView: drag coalescing, preset buttons, sliders
- ✅ ButtonMappingView: recording bindings for all ~20 button/mode controls
- ✅ DisplayMappingView: display picker + toggle display set
- ✅ PresetsView: activate/deactivate/save/delete/rename + app bindings
- ✅ DevicesView: tablet/tool rename undo

**Infrastructure:**
- `docUndoManager` in SettingsWindowController (NSWindow.undoManager is read-only)
- `settings.undoManager` and `settings.activeTool.undoManager` wired
- Edit menu with `CommandGroup(replacing: .undoRedo)` for Cmd+Z/Shift+Z

**Known issues requiring attention:**
- ⚠️ Undo stack clearing on device switch — implementation exists but needs verification
- ⚠️ No unit tests for undo/redo functionality

**Files:** TabletSettings.swift, ToolSettings.swift, SettingsWindowController.swift, PreferencesWindowController.swift, MockTabApp.swift, ButtonMappingView.swift, DisplayMappingView.swift, PresetsView.swift, DevicesView.swift

---

## CLI + JSON Profile Export — ✅ COMPLETE (Phase 1, 2026-03-29)

Phase 1 light implementation is done:
- ✅ `Profile.swift` — Codable struct with all device + tool settings
- ✅ `TabletSettings.exportCurrentAsProfile()` / `.importProfile()`
- ✅ `example-profile.json` — schema documentation
- ⏳ Unit tests — deferred (no test target exists)

**Phase 2 (full CLI)** deferred until `TabletSettings` design stabilizes (~1–2 months).

---

## Near-term

### WacomDeviceRegistry: verify OTD-sourced entries
~45 entries added from OTD import are tagged `// ⚠ from OTD`.
Verify MaxX/MaxY/MaxPressure against Linux input-wacom or live capture before shipping.
Priority: CTL/CTH-4100/6100 (IntuosV2 parser — these will actually route to WacomUniversalDevice).

### Graphire decoder
`.graphire` parser family has registry entries but no decoder.
8-byte Report ID 0x01 format; ~511 pressure levels; no tool-change packets.
Lowest priority — hardware is very old.

### Bamboo decoder
`.bamboo` parser family has registry entries but no decoder.
20-byte Report ID 0x10, BE16 coordinates. No existing MockTab code to lift from.

---

## Deferred / Future

### KC-100 cordless mouse — DEPRIORITIZED
KC-100-00 was designed for the Intuos 4 (PTK-xxx) line; never officially supported on PTH-660/860/850.
Structural routing fix exists in code (DecodeResult.mouseButton, IntuosV2Decoder case 0x01,
InputInjector.injectMouseButtons) but has a known byte-offset bug: `IOHIDDeviceRegisterInputReportCallback`
strips the report ID, so the callback buffer starts with the button mask at `report[0]`, not `report[1]`.
Cursor and scroll work; buttons don't.  BT buttons unimplemented in firmware.
Leave as-is unless Intuos 4 hardware is added.

### ButtonMappingView enhancements (post-v1)
Current UI is functional with pen diagram. Remaining improvements (post-v1):
- ✅ **Pen diagram with live button feedback** (2026-04-06)
- **Tip/eraser bindings** in ToolSettings + InputInjector (let user choose which mouse button)
- **ToolNameLabel** — show active pen name instead of device name in pen section
- **Generalized side buttons** — dynamic count instead of fixed "Side button 1/2"
Design notes in `project_button_mapping_redesign.md` (memory).

### Per-pen serial number support
`ToolIdentity` struct exists; `DeviceRegistry.recordTool` tracks serials.
Planned: per-pen settings split (`ToolSettings`), full `DeviceRegistry` evolution.
Six-phase plan in `project_pen_serial_strategy.md`. Phase 1 (hardware instrumentation)
not yet started.

### Cintiq
Tablet with built-in monitor needs additional consideration.
Cintiq DTK-2400 has two independent touch rings that need individual configuration.
Change keys 1-3 on left and right side of display to be state toggles instead of single-fire buttons

### Touch ring: additional modes
Currently supports `.scroll` and `.off`. Future modes could include zoom, brush size,
layer opacity, or arbitrary key-per-direction bindings.

### Cintiq Pro (DTH-xxx)
Newer Cintiq Pro models use USB-C and a different HID report format.
DTH-271 is now in the registry (from OTD, IntuosV2 parser) but unverified.

---

## Deferred decisions

### CLI/JSON target OS versions
The CLI *could* target macOS 10.14+ by avoiding SwiftUI + MenuBarExtra.
Driver code is 100% compatible (IOKit is ancient).
Deferred: implement GUI-only first, measure user demand, then backport CLI if needed.

### Touch support
Standard feature in most tablets that many users disable because implementation is far worse than a phone, iPad, or trackpad

---

## Done (recent sessions)

- [x] Per-app overrides (2026-04-06): Smooze-model app-specific settings with override bar in all 6 tabs.
      Running apps dropdown + drag-drop app chip reordering/removal. Settings merged at activation.
- [x] One-window-per-tablet (2026-04-06): Strict enforcement; each detected tablet gets exactly one window.
      Window locked to assigned tablet (device picker disabled). No mix-and-match reassignment possible.
- [x] Pen diagram & live button feedback (2026-04-06): Added visual stylus to ButtonMappingView with
      real-time button state display during user interaction.
- [x] Tilt tracking (2026-04-06): Added tilt to DecoderState for future multi-pen serial number features.
- [x] Art Pen fixes (2026-04-06): Fixed rotation reset-to-0° on tip-down; improved barrel button debounce
      and touch ring seam detection on DTK-2400.
- [x] Battery level reporting (2026-04-06): BT devices now surface battery state in UI (InfoView).
- [x] Semantic typography (2026-04-06): Consistent font naming across UI for better maintainability.
- [x] App picker redesign (2026-04-06): Replaced shortcut-based selection with running-apps menu + drop well.
- [x] App chip drag-to-reorder (2026-04-06): Implemented reordering and removal via drag gestures.
- [x] Factory Reset fully functional (2026-04-03): skipNextWindowSave() + NSWindow frame caches +
      Return/Command-R dialog activation. App now truly resets to factory defaults on relaunch.
- [x] Sticky modifier keys fixed (2026-04-03): hidSystemState + activeSyntheticFlags prevents
      feedback loops. All event types now have correct modifier flags.
- [x] test/kernel-spec-alignment branch merged (2026-04-03): 20+ commits integrated, main stable.
- [x] PTH-660 BT Pro Pen 3 eraser fixed (2026-04-03): tool code byte offset [103:104] correct.
- [x] Marker Pen support added (2026-04-03): 0x0804 now works on intuosProGen2.
- [x] Express keys defaults updated (2026-04-03): ⌘⌥⌃⇧ modifiers instead of keyboard shortcuts.
- [x] Tool code override feature restored (2026-04-03): user can force tool as different model.
- [x] ACK-40401 wireless init race (2026-03-29): `WacomGenericDevice` now re-sends
      `[0x02, 0x02]` feature init when 0x02 wireless status arrives, fixing the case where
      the dongle was already paired when MockTab started.
- [x] Photoshop pressure sensitivity (2026-03-28): populate tabletEventPointPressure +
      tabletEventDeviceID + tabletEventPointButtons in mouse events. Also fix capabilityMask
      0x04C3→0x05C7. CGEvent fix is sufficient.
- [x] CPU optimization: three-level gating for live state updates (app frontmost + window focus
      + tab visibility). Completely halts @Published mutations when backgrounded.
- [x] PTH-860 BT Classic decoder (2026-03-29): implemented `decodeBTClassicFrames` for
      99-byte/7-frame INTUOSP2_BT format; dispatched by length in 0x80 handler.
- [x] KC-100 USB mouse cursor + scroll work (2026-03-27): buttons remain broken due to
      byte-offset bug (see Deferred).
- [x] HID capture tool built-in: `HIDCapture.shared` singleton logs raw hex reports
      to `~/Desktop/mocktab_capture.txt`; toggle in InfoView.
- [x] Bluetooth wireless: PTH-660 fully working over BT — pen, pressure, tilt, barrel buttons,
      express keys, touch ring, center button all confirmed.
- [x] Touch ring: fixed decoder bug and fully implemented with scroll mode + center button mapping.
- [x] ButtonMappingView live indicators: fixed by extending `infoViewVisible` gate to include Buttons tab.
- [x] Undo/Redo (Cmd+Z / Cmd+Shift+Z): all views complete (2026-03-29)
- [x] Window sizing: remove per-tab size persistence; tabs use default height until user
      manually resizes, then window stays at user's chosen size across all tab switches.
- [x] WacomDeviceRegistry: expanded ~50 → ~95 entries via OTD import.
- [x] TabletAreaView: replaced hardcoded TabletModel picker with dynamic DeviceRegistry list.
- [x] Phase 1–5: multi-device architecture, decoders, WacomGenericDevice, WacomDeviceRegistry.
