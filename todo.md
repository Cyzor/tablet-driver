# MockTab — Open Tasks

_Last updated: 2026-03-29 (session 11 — Photoshop/BT/wireless fixes shipped, Phase 1 CLI/JSON complete)_

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

### ButtonMappingView redesign
Current UI is functional but minimal. Planned improvements:
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
- [x] Window sizing: remove per-tab size persistence; tabs use default height until user
      manually resizes, then window stays at user's chosen size across all tab switches.
- [x] WacomDeviceRegistry: expanded ~50 → ~95 entries via OTD import.
- [x] TabletAreaView: replaced hardcoded TabletModel picker with dynamic DeviceRegistry list.
- [x] Phase 1–5: multi-device architecture, decoders, WacomGenericDevice, WacomDeviceRegistry.
