# MockTab — Open Tasks

_Last updated: 2026-03-29 (session 10 — Phase 1 CLI/JSON complete)_

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

### 🟡 DTK-2400 pen decoder — needs hardware verification
Per Linux kernel `wacom_intuos_general()` / `WACOM_24HD`, the 0x02 pen report was
overhauled (2026-03-28):
- **Barrel buttons**: now read from every frame via `d1 & 0x02` / `d1 & 0x04` per kernel.
  The old EA/E0 alternating-frame interpretation was incorrect.
- **Pressure**: kernel formula `(d6<<3)|((d7&0xC0)>>5)|(d1&1)` — 11-bit, unchanged.
- **Eraser detection**: now `toolCode & 0x0008 != 0` (kernel tool_id bit 3) instead of
  the old heuristic `& 0x000F == 0x000A`.
- **Hover distance**: now `report[9] >> 2` (top 6 bits); bottom 2 bits are X/Y LSBs.
- **Art Pen rotation**: kernel two-branch formula (`absZ` ±900 half-degree steps).
All changes require live hardware testing to confirm correct behavior.

### 🟡 IntuosV1/Intuos3/IntuosV2 decoder fixes — needs hardware verification
Applied from `Wacom-HID-Family-Reference.md` (2026-03-28):
- **Eraser detection** (IntuosV1 + Intuos3): changed `(toolCode & 0x000F) == 0x000A`
  to `(toolCode & 0x0008) != 0` — kernel uses bit 3 only; old test required bits 1+3.
- **Hover distance** (IntuosV1 + Intuos3): changed `Int(report[9])` to
  `(Int(report[9]) >> 2)` — bottom 2 bits of report[9] are X/Y LSBs, not distance.
- **Pressure right-shift** (IntuosV1 + Intuos3): added `>> 1` when `spec.maxPressure <= 1023`
  — 10-bit devices encode pressure in the same 11-bit field; no effect on PTH-851 (2047)
  or PTZ-631W (2046).
- **Eraser status bit** (IntuosV2): changed `(status & 0x10) != 0` to `(status & 0x08) != 0`
  — eraser hover=0x28 and eraser touching=0x68 both have bit 3 set, not bit 4.
PTH-851 (IntuosV1), PTZ-631W (Intuos3), PTH-660/860 (IntuosV2) need hardware
re-verification for eraser, hover distance, and pressure feel after these changes.

---

## Active Feature: CLI + JSON Profile Export (Option 2)

_Status: Planning phase — Light implementation scheduled before feature-complete GUI_

### Design decision (2026-03-28)
Implement **light setup now** (1–2 hours), full CLI later when GUI stabilizes.

**Why early?**
- Forces architectural clarity on what's exportable *before* locking in settings schema
- Codable conformance check catches serialization issues early
- JSON format becomes a "contract" that keeps settings stable across refactors
- When GUI is feature-complete, full CLI implementation is straightforward

**Why not wait?**
- Settings models are still volatile; locking JSON format early might constrain design
- Full CLI isn't needed until GUI is stable anyway

### Phase 1: Light Setup ✅ COMPLETE (2026-03-29)

#### ✅ 1.1 Create `Profile.swift` (new file)
**Location:** `MockTab/Settings/Profile.swift` — DONE

Portable `Codable` struct with all device + tool settings. Also `ToolSnapshot` for Phase 2.

#### ✅ 1.2 Add export/import methods to TabletSettings
**File:** `MockTab/Settings/TabletSettings.swift` — DONE

- `exportCurrentAsProfile(name:deviceName:) -> Profile`
- `importProfile(_:) -> Void`

Both use `activeTool` for pressure/smoothing/button bindings.

#### ✅ 1.3 Create example JSON profile
**Location:** `MockTab/example-profile.json` — DONE

Complete schema documentation with real-world defaults.

#### ⏳ 1.4 Unit test: round-trip JSON
**File:** `MockTabTests/ProfileCodingTests.swift` — DEFERRED

No test target exists in Xcode project; test creation requires target setup.
Optional for next session.

### Phase 2: Full CLI Implementation (4–8 hours, WHEN GUI STABLE)

Once `TabletSettings` design is locked (~1–2 months):

1. **Create CLI target** — new macOS command-line executable in Xcode
2. **Share settings code** — move `Profile.swift`, `TabletSettings`, `ToolSettings`, 
   `BezierCurve`, `ButtonBinding` to shared framework or copy to CLI target
3. **Implement commands:**
   ```
   mocktab-cli profile export <name> --out profile.json
   mocktab-cli profile import <path.json>
   mocktab-cli profile list
   mocktab-cli devices list
   mocktab-cli status
   ```

### Why this works

✅ **Architecture:** Settings are already UI-agnostic (use UserDefaults directly)
✅ **Models:** Preset, ButtonBinding, BezierCurve, ToolSettings already Codable
✅ **Format:** JSON is human-editable; profiles portable across machines
✅ **Stable contract:** Profile.swift is the schema; GUI respects it during refactors
✅ **Timeline:** Light now (1–2h), heavy later (~8h), zero pressure to ship CLI immediately

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
Tablet with built-in monitor needs additional 
Cintiq DTK-2400 has two independent touch rings that individual configuration.
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

# Touch support
Standard feature in most tablets that many users disable because implementation is far worse than a phone, iPad, or trackpad

---

## Done (recent sessions)

- [x] Photoshop pressure sensitivity (2026-03-28): populate tabletEventPointPressure +
      tabletEventDeviceID + tabletEventPointButtons in mouse events (Photoshop reads tablet
      union, not mouseEventPressure). Also fix capabilityMask 0x04C3→0x05C7. WacomShim
      Apple Events approach abandoned — CGEvent fix is sufficient.
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
