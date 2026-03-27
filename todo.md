# MockTab — Open Tasks

_Last updated: 2026-03-26_

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

### 🟡 PTH-660/860 mouse buttons still broken
`sendWacomInputModeInit` is in place but cordless mouse (KC-100) button state is
not decoded correctly from report bytes. Three approaches tried; deferred by user.
**Needs:** Live capture on PTH-660 with KC-100 mouse to identify correct button byte.

---

## Near-term


### WacomDeviceRegistry: fill in Bamboo/Graphire specs
Many entries marked ⚠ estimated. Verify via OTD JSON configs and Linux input-wacom.
Bamboo decoder requires new implementation (no existing MockTab code to lift from).

### OTD config import script (Phase 5)
Python script: parse `Configurations/Wacom/*.json` → emit Swift `WacomDeviceSpec` entries.
Key OTD fields: `ProductID`, `Name`, `InputReportLength` (→ parser), `ReportParser`
(class name override), `MaxX`, `MaxY`, `MaxPressure`, `ButtonCount`,
`FeatureInitializationReport` (base64 → featureInit bytes), `Interface` (→ seizeUSB).
Expands table from ~50 → ~150 entries in one automated pass.

---

## Deferred / Future

### ButtonMappingView redesign
Current UI is minimal. Planned: tip/eraser separate bindings, ToolNameLabel, generalized
side buttons, scroll ring/strip. Design in `project_button_mapping_redesign.md`.

### Per-pen serial number support
`ToolIdentity` struct exists; `DeviceRegistry.recordTool` tracks serials.
Planned: per-pen settings split (`ToolSettings`), full `DeviceRegistry` evolution.
Six-phase plan in `project_pen_serial_strategy.md`. Phase 1 (hardware instrumentation)
not yet started.

### Graphire decoder
`.graphire` parser family has registry entries but no decoder.
8-byte Report ID 0x01 format; ~511 pressure levels; no tool-change packets.
Lowest priority — hardware is very old.

### Bamboo decoder
`.bamboo` parser family has registry entries but no decoder.
20-byte Report ID 0x10, BE16 coordinates. No existing MockTab code to lift from.

### Cintiq Pro (DTH-xxx)
Newer Cintiq Pro models use USB-C and a different HID report format.
Not in the current registry; would need separate research.

### Wireless: full dongle + BLE testing
BLE HOGP code is written for PTH-851/660/860 but untested (no BLE hardware connection
confirmed). ACK-40401 dongle (0x0084) routes to WacomGenericDevice — untested live.

---

## Done (recent sessions)

- [x] PTH-851: Dual USB/BLE transport; tool-change packets; eraser detection; lastX/Y proximity-out
- [x] PTH-660/860: Express keys switched to `report[1]` (mechanical); debug logging removed; BLE support added
- [x] PTZ-631W: Eraser detection fixed (nibble 0x0A); tool-change generalized; lastX/Y proximity-out
- [x] DTK-2400: `isArtPen` bool replaces penLabel string check; debug logging removed
- [x] WacomGenericDevice: Full replacement for WacomProbeDevice — cursor, click, pressure, BLE, wireless
- [x] WacomDeviceRegistry: Phase 1 data-driven device table (~50 entries, 4 parser families)
- [x] TabletManager.deviceName: Delegates to WacomDeviceRegistry
- [x] BLE shared helpers: `decodeBLEPenReport` / `decodeBLEPadReport` in TabletDevice.swift
- [x] Phase 2 decoders: WacomDecoder protocol + DecoderState + DecodeResult in TabletDevice.swift
- [x] IntuosV2Decoder.swift: reports 0x01/0x03/0x10/0x1E/0x11/0x80 — lifted from PTH660Device
- [x] IntuosV1Decoder.swift: reports 0x01/0x03/0x11/0x02/0x10/0x80 — lifted from PTH851Device
- [x] WacomUniversalDevice.swift: decoder-backed driver; open/close; report dispatch
- [x] TabletManager: default routing to WacomUniversalDevice for known PIDs with live decoders
- [x] Phase 4: PTH851/PTH660/PTH860 retired; PTZ-631W kept (Intuos3 proximity bit differs)
