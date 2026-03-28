# MockTab — Open Tasks

_Last updated: 2026-03-27 (session 4 research)_

---

## Blockers / Active Bugs

### 🔴 PTH-860 Bluetooth broken
macOS `AppleBluetoothMultitouch` kext claims the PTH-860 BLE device before MockTab can
seize it, treating it as a Magic Trackpad.  MockTab receives 686 reports but cannot
inject input.
**Fix:** Call `kIOHIDOptionsTypeSeizeDevice` on the BLE HID handle.  If seize already
happens but targets a different interface (BLE can present multiple logical HID
interfaces), identify and seize the correct one.

Three additional decoder changes needed once seize works:
1. **Device signature** — byte 99 in 0x80 container: accept `CE 00` (pen absent) and
   `B7 A5` (pen present) as valid PTH-860 identifiers (PTH-660 uses `6A 35`).
   Secondary signature at byte 284: `64 7F 38 01` (PTH-860) vs `63 7F 38 01` (PTH-660).
2. **Bytes[9:10]** — PTH-860 shows `0xFF F9` (barrel rotation, signed int16 LE = -7);
   PTH-660 shows `0x00 0x00`.  Accept any value — do not validate zero.
3. **Byte[13]** — PTH-860 shows altitude countdown (0x3F → 0x1D range); PTH-660 = 0x00.
   Accept any value — do not validate zero.

**Needs hardware + new BT capture with tip presses** to verify pressure decoder path
after decoder fixes (current capture is hover-only).

### 🔴 DTK-2400 barrel button bits wrong
EA/E0 alternating report frames: bit 1 is a frame discriminator, not the barrel button.
Barrel button is at a different bit position — not yet determined from live capture.
**Needs:** DTK-2400 hardware connected + console logging to identify correct byte/bit.

### 🔴 DTK-2400 EA/E0 pressure merging not implemented
DTK-2400 sends pressure in EA frames and X/Y in E0 frames alternately.
Current code uses a single-frame decode; rotation+pressure are only available when
the EA frame arrives, but position from that same frame is stale.
**Needs:** Interleave EA/E0: cache EA pressure/rotation, apply on next E0 position frame.

### 🟡 DTK-2400 eraser detection not implemented
Tool type (pen vs eraser) is encoded in byte[1] of the 0xC2 tool-announcement report:
`0x22` = pen, `0xA2` = eraser.  Motion reports (0xE0/0xE1) are identical for both.
Fix: on `status == 0xC2`, cache `byte[1] & 0x80` as current tool type; apply to all
subsequent motion reports until the next 0xC2.
Currently `eraser: false` hardcoded.  Serial number also available in bytes[4:8] of 0xC2.

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

### Touch ring: additional modes
Currently supports `.scroll` and `.off`. Future modes could include zoom, brush size,
layer opacity, or arbitrary key-per-direction bindings.

### Cintiq Pro (DTH-xxx)
Newer Cintiq Pro models use USB-C and a different HID report format.
DTH-271 is now in the registry (from OTD, IntuosV2 parser) but unverified.

---

## Done (recent sessions)

- [x] KC-100 USB mouse cursor + scroll work (2026-03-27): buttons remain broken due to
      byte-offset bug (see Deferred) and KC-100 being deprioritized.
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
