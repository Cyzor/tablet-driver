2026-03-27

**Implementation Plan for PTH-850 (Intuos5 L) & PTH-860 (Intuos Pro L) Support in Your Swift/SwiftUI Driver**

These two tablets (and their wireless/mouse/Bluetooth variants) are the **last major legacy outliers** before Wacom standardized on newer protocols. Your captures perfectly illustrate the deficiencies:

- **Pen mode** (USB/wireless) mostly works but can be jittery on wireless.
- **Mouse accessory (KC-100-00)** is the biggest pain point: left-click triggers a spurious stylus tip switch (breaking drags), cursor strobes in text fields, and it feels like “two mice fighting.”
- **Bluetooth** (PTH-860) is effectively broken (mostly empty ID=0x80 init reports).
- **Wireless receiver** (ID=0x80) shows sleep/wake and reconnection quirks.

The good news: Wacom’s own driver handles all of this seamlessly by **dispatching different report IDs** and **separating mouse vs. pen input**. Your driver can do the same with a clean, extensible legacy parser. This will give you **Wacom-native behavior** (clean taps/drags, no conflicts, reliable wireless) while keeping the driver modern (Swift-native, performant, minimal dependencies).

### 1. Device Detection & Multi-Interface Handling (30–60 min)
- **VID/PID pairs** (from your captures + standard Wacom IDs):
  - PTH-850 (Intuos5 L): `0x056A / 0x0026` (USB), wireless variants same base.
  - PTH-860 (Intuos Pro L): `0x056A / 0x0331` (USB), Bluetooth/wireless variants.
- Open **all** HID interfaces (pen + mouse/ExpressKeys + receiver).
- Prioritize:
  - Pen interface → absolute stylus input.
  - Mouse accessory (KC-100-00) → relative mouse input (with explicit suppression of stylus tip).
- On first report containing `0x80` (wireless receiver init) or `0xC0`, mark as “wireless mode” and enable keep-alive logic.

Add these to your device database as a new family: `WacomIntuosLegacy`.

### 2. Report Dispatcher (Core, 2–3 hours)
Create a `WacomIntuosLegacyParser` that switches on Report ID (and device model). All your captures map cleanly to known formats:

| Report ID | Length | Device / Mode          | What it contains                  | Action in driver                  |
|-----------|--------|------------------------|-----------------------------------|-----------------------------------|
| 0x02      | 64     | Status / mouse / init  | Device state, mouse coords/buttons| Parse mouse if accessory active   |
| 0x02      | 10     | Pen (PTH-850)          | Proximity, tip, buttons, X/Y, pressure | Standard pen parsing             |
| 0x10      | 27     | Pen (PTH-860)          | Full pen + tilt + buttons         | Intuos Pro pen parsing            |
| 0x80      | 32/361 | Wireless receiver      | Pairing, battery, sleep           | Handle reconnect / keep-alive     |
| 0xC0      | 10     | Init / mode change     | Tool change                       | Reset state                       |
| 0x13      | 9      | Mouse accessory        | Pure mouse (rare)                 | Relative mouse only               |

**Swift skeleton** (add to your existing report handler):
```swift
func parseLegacyReport(bytes: [UInt8], device: WacomDevice) -> InputEvent? {
    guard !bytes.isEmpty else { return nil }
    switch bytes[0] {
    case 0x02 where bytes.count == 10:
        return parsePTH850Pen(bytes)          // PTH-850 USB/wireless pen
    case 0x10 where bytes.count == 27:
        return parsePTH860Pen(bytes)          // PTH-860 USB pen
    case 0x02 where bytes.count == 64:
        return parseMouseOrStatus(bytes, device) // mouse accessory or status
    case 0x80:
        return handleWirelessReceiver(bytes)  // sleep/wake, battery
    default:
        return nil
    }
}
```

### 3. Fix the Mouse Accessory Conflict (Biggest Win, 1–2 hours)
This is the exact cause of “left click triggers stylus tip” and cursor strobing:

- The KC-100-00 sends **combined reports** (ID=0x02 len=64 contains mouse data **and** sets the stylus tip bit in the pen section).
- Your current parser treats every report as potential pen input → conflict.

**Solution**:
- Detect mouse mode via byte patterns in ID=0x02/64 reports (e.g., non-zero values in mouse coordinate fields + specific status bits like `0x81` or accessory flag).
- When mouse mode is active:
  - Route **relative mouse** (delta X/Y from the report) to macOS `CGEvent` or your mouse input path.
  - **Explicitly suppress** stylus tip/pressure for that report.
  - Map left/right buttons and scroll directly (your notes say right-click + scroll already work — just isolate them).
- Fall back to stylus parsing only when a true pen report (ID=0x02/10 or 0x10) arrives with proximity.

This eliminates the “two mice fighting” feeling and makes dragging reliable.

### 4. Pen Parsing Details (Match Wacom Exactly)
- **PTH-850 (ID=0x02 len=10)**: `02 [status] [X high/mid/low] [Y] [pressure] [tilt/buttons]`
  - Status byte bits: proximity (0x80), tip (0x01), barrel1/2, eraser.
  - Pressure: 0–2047 (scale with Wacom curve for natural feel).
- **PTH-860 (ID=0x10 len=27)**: Standard Intuos Pro format (widely documented in linuxwacom).
  - Byte 1: tool/proximity.
  - Bytes 2–4/5–7: 24-bit X/Y.
  - Pressure + tilt in later bytes.
  - Your “works” capture already shows clean values — just map them.

Use the exact logical max from the HID descriptor (or your captures) to avoid scaling bugs.

### 5. Wireless & Bluetooth Handling
- **Wireless (ID=0x80)**: Parse battery, connection state, and send keep-alive if idle > 5 s (prevents sleep).
- **Bluetooth (PTH-860)**: Your “broken” capture is pure init spam. Implement pairing mode detection (touch-ring button press → discoverable) and fallback to LE mode if BT Classic fails. macOS `IOBluetooth` or HID manager handles most; just route reports once paired.
- Reconnection: On `0x80` “disconnected” pattern, notify user or auto-retry (your note already mentions unplug/replug works).

### 6. Testing & Validation Workflow
1. **Replay harness** (Swift or Python): Feed every line from your six new `.txt` files → assert:
   - Pen logs → clean tip, no ghost pressure.
   - Mouse logs → mouse moves without stylus tip.
   - Wireless logs → no spurious disconnects.
2. **Hardware matrix**:
   - PTH-850/860 USB pen.
   - Wireless pen + mouse accessory.
   - Bluetooth (PTH-860).
3. **Apps**: Krita/Photoshop (pressure/tilt), Preview (text editing — no more I-beam strobe), macOS gestures.
4. **Edge cases**: Sleep/wake, ExpressKeys (if present in reports), multi-monitor.

### 7. Modern/Compatible Architecture
- Isolate in `WacomIntuosLegacyDriver` class (no breakage to your newer tablets).
- Use Swift concurrency for high-rate reports (133 Hz+).
- Add user toggle: “Legacy Mouse Mode” (for users who prefer pure mouse behavior).
- Future-proof: Same dispatcher pattern you’ll use for newer devices.

**Expected outcome**: After this, both tablets will feel **indistinguishable from Wacom’s driver** — clean pen, conflict-free mouse, reliable wireless/Bluetooth. The mouse accessory will finally stop fighting the stylus.

This is the last “stubborn” pair you’ll need to tune. Once done, your driver will cover the entire Intuos 5 / Intuos Pro generation with best-in-class macOS integration.

Start with the dispatcher + mouse conflict fix (steps 2–3). If you paste the parsed byte examples from a specific “broken” mouse action (e.g., left-click while dragging), I can give you the exact bit masks for the Swift code. Ready when you are!