# MockTab — Open Tasks

_Last updated: 2026-03-27 (session 3)_

---

## Blockers / Active Bugs

### 🔴 DTK-2400 barrel button bits wrong
EA/E0 alternating report frames: bit 1 is a frame discriminator, not the barrel button.
Barrel button is at a different bit position — not yet determined from live capture.
**Needs:** DTK-2400 hardware connected + console logging to identify correct byte/bit.

### 🔴 DTK-2400 EA/E0 pressure merging not implemented
DTK-2400 sends pressure in EA frames and X/Y in E0 frames alternately.
Current code uses a single-frame decode; rotation+pressure are only available when
the EA frame arrives, but position from that same frame is stale.
**Needs:** Interleave EA/E0: cache EA pressure/rotation, apply on next E0 position frame.

### 🔴 KC-100 USB mouse buttons: routing fix incomplete / unverified
Structural fix in place (DecodeResult.mouseButton, IntuosV2Decoder, WacomUniversalDevice,
InputInjector, TabletManager) but tested and still not working.  Two unresolved questions:

**Q1 — Is the callback even firing?**
HIDCapture log shows zero ID=0x01 reports.  If `IOHIDDeviceOpen(seize)` fails on the
mouse interface, `WacomUniversalDevice.open()` returns early before registering the
input report callback.  Add explicit open-result logging for the mouse interface to
confirm seizure succeeds.

**Q2 — Byte offset: is the report ID stripped or included?**
`IOHIDDeviceRegisterInputReportCallback` behavior is disputed.  Existing 0x10 pen
reports show `report[0]=0x10` in the capture log (ID included), which would make
`report[1]` the button byte and our fix correct.  But if the mouse interface strips
the report ID (so `report[0]`=buttons), then:
  - `switch report[0]` only hits `case 0x01` when LEFT is the sole button pressed
  - Our `.mouseButton(report[1])` reads relX instead of buttons — wrong
  Fix for stripped-ID case: intercept at callback before `decode()`, using the
  separate `reportID` parameter.

**Needs:** Add mouse-interface-specific log entry to confirm (a) open succeeds,
(b) callback fires on click, (c) raw bytes on click to determine offset.

### 🟡 PTH-660 BT mouse: buttons almost certainly not in 0x80 container
Exhaustive analysis of all 361 bytes across 1,337 BT reports found zero byte
positions with press/release patterns.  Slot-4 flag byte (byte[43]) only ever shows
0x00 or 0xE0 — bits 0–4 always zero.  BT mouse buttons may not be forwarded by
tablet firmware over the BT transport at all.
**Treat as unimplemented until proven otherwise.**

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

### Touch ring: additional modes
Currently supports `.scroll` and `.off`. Future modes could include zoom, brush size,
layer opacity, or arbitrary key-per-direction bindings. The center button can now be
mapped to any key/action — it could also toggle between ring modes.

### Cintiq Pro (DTH-xxx)
Newer Cintiq Pro models use USB-C and a different HID report format.
DTH-271 is now in the registry (from OTD, IntuosV2 parser) but unverified.

### ~~Wireless: BT aux/pad reports~~ ✅ DONE
Express keys, touch ring, and center button confirmed working over BT (2026-03-27).
Pad sub-report is embedded at fixed offset 281 in the 0x80 container.
Decoded in `IntuosV2Decoder.decodeBTPen` alongside pen data.

---

## Done (recent sessions)

- [x] KC-100 USB mouse buttons + drag fully implemented (2026-03-27, session 2):
      Root cause: buttons come via standard HID mouse interface (usagePage=0x01,
      Report ID 0x01, 4 bytes) — separate from the 0x10 digitizer stream.
      That interface was already seized and receiving reports; they silently dropped
      in `decodeBLEPenReport` (guard length >= 11 failed for 4-byte reports).
      Fix: 5 files — `TabletDevice.swift` (new `DecodeResult.mouseButton`),
      `IntuosV2Decoder` (case 0x01 length <= 8 → `.mouseButton`),
      `WacomUniversalDevice` (`onMouseButton` closure),
      `InputInjector` (`injectMouseButtons`, `usbMouseLeftHeld` for drag events,
      proximity-exit flush), `TabletManager` (wire closure to seized interface).
      Result: L/R/Middle click + left-drag all work.  Double-click reuses resolveClick.
- [x] HID capture tool built-in: `HIDCapture.shared` singleton logs raw hex reports
      to `~/Desktop/mocktab_capture.txt`; toggle in InfoView.
- [x] USB / BT capture analysis: KC-100 0x10 byte map fully confirmed (see memory);
      BT 0x80 container slot structure mapped (20 × 14-byte slots); slot 4 = mouse.
- [x] Bluetooth wireless: PTH-660 fully working over BT — pen, pressure, tilt, barrel buttons,
      express keys, touch ring, center button all confirmed; report ID 0x80, 361-byte container;
      pad sub-report at fixed offset 281; three fixes: skip InputMode init for BT,
      skip ghost usagePage=0x01 interface, route 0x80 to BT pen decoder
- [x] Touch ring: fixed decoder bug (report[3] = center button, not ring flag; ring contact
      = report[4] != 0x7F); ring now scrolls without requiring center button held
- [x] Touch ring: center button independently mappable via `touchRingButtonBinding`
- [x] Touch ring: live indicator for center button in ButtonMappingView + Info tab ring row
- [x] ButtonMappingView live indicators: fixed by extending `infoViewVisible` gate to
      include Buttons tab (was Info-only, causing all indicators to stay dark)
- [x] InfoView: added Touch Ring row to Live Input panel
- [x] WacomDeviceRegistry: fixed 0x0360 (PTH-660 alt PID) hasTouchRing false→true
- [x] Touch ring wired: scroll by default, mode picker in Buttons tab, InfoView indicator
- [x] Window sizing: remove per-tab size persistence; tabs use default height until user
      manually resizes, then window stays at user's chosen size across all tab switches
- [x] OTD import script: full rewrite for current DigitizerIdentifiers schema;
      multi-stage FeatureInitReport; Attributes-as-dict; new parser class names;
      EXISTING_PIDS updated to ~95 entries
- [x] WacomDeviceRegistry: expanded ~50 → ~95 entries via OTD import
- [x] TabletAreaView: replaced hardcoded TabletModel picker with dynamic DeviceRegistry list
- [x] PTZ-631W retired: Intuos3Decoder + .intuos3 parser + featureInit2 support
- [x] Phase 5: tools/import_otd_configs.py — OTD JSON → Swift WacomDeviceSpec entries
- [x] PTH-851: Dual USB/BLE transport; tool-change packets; eraser detection
- [x] PTH-660/860: Express keys switched to report[1] (mechanical); BLE support
- [x] WacomGenericDevice: Full replacement for WacomProbeDevice
- [x] Phase 1–4: data-driven registry, decoders, WacomUniversalDevice, device migration
