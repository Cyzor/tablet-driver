2026-03-27

**Implementation Plan for Seamless DTK-2400 (Cintiq 24HD) Support in Your Swift/SwiftUI Driver**

Your provided MockTab HID captures are gold: they give raw 10-byte Report ID `0x02` data across hover, tip press, barrel buttons (1 & 2), and eraser attempts, with clear "works" vs. "broken" labels that directly expose the decoding bugs. The device is **not** hardware-broken (it works perfectly under Wacom’s driver), so the issues (non-responsive tap unless using a bizarre pressure profile + lower barrel combo, heavy/leaky pressure) are purely parser defects. This old 10-byte format is a transitional outlier between earlier (Intuos/Cintiq V) and later Wacom practices — that’s why it’s been stubbornly difficult.

The plan below is practical, iterative, and uses **your exact logs** for verification. It will get you to Wacom-native behavior (clean tip-switch tapping, zero-pressure hover, natural pressure response, proper buttons/eraser/tilt) without relying on OpenTabletDriver (which still lacks full DTK-2400 support as of the latest public data).

### 1. Device Detection & HID Setup (Immediate, 1-2 hours)
- **VID/PID**: `0x056A : 0x00F4` (confirmed for DTK-2400 / Cintiq 24HD tablet sensor interface).  
  This is the exact USB ID used by macOS and Linux kernel drivers.
- In your existing device database/enumeration:
  - Match on `vendorID == 0x056A && productID == 0x00F4`.
  - Target the **pen/tablet HID interface** (ignore monitor-control or hub interfaces).
- Open the device with `IOHIDManager` (or your current HID stack) and request reports for ID `0x02` (10 bytes).
- Add a fallback "out-of-proximity" state on first `0xC2 0x80 ...` reports (common init/out-of-range marker in all your logs).

### 2. Get the Official Report Descriptor (Strongly Recommended, 30-60 min)
The HID report descriptor defines the **exact** bit/byte layout. Do **not** skip this — it eliminates guesswork.
- On your Mac (with the tablet plugged in): Use **USB Prober** (Xcode → Additional Tools → Hardware) or a simple IOKit script to dump the descriptor for the pen interface.
- Alternative: Run `ioreg -l | grep -A 20 "DTK-2400"` or `system_profiler SPUSBDataType` and extract the descriptor bytes.
- Once you have it, the fields for Report ID `0x02` will explicitly show:
  - Which bits in byte 1 = proximity + tip + barrel1 + barrel2 + eraser.
  - X/Y (almost certainly 24-bit or split high/low).
  - Pressure (11- or 12-bit for 2048 levels).
  - Tilt (if present — your pen supports ±60 levels).

This is the single most reliable source. Your logs will then serve only as verification.

### 3. Reverse-Engineer & Implement the 10-Byte Parser (Core Work, 2-4 hours)
Use your logs to map fields **empirically** while the descriptor confirms it. The structure is consistent across all captures:

**Typical layout inferred from your logs + known similar-era Wacom (DTK-2100 / Intuos3/Cintiq series)** (adjust once you have the descriptor):
- **Byte 0**: Always `0x02` (Report ID).
- **Byte 1**: Status / proximity / tool flags (key to all your issues).
  - `0xC2 0x80 ...` → out of proximity / init.
  - `0xE0 ...` or `0xE1 ...` → in proximity (stylus).
  - `0xE1` often appears in eraser or certain button states.
  - Bits inside: tip switch (usually bit 0), barrel 1 (bit 1), barrel 2 (bit 2), eraser (bit 3).
- **Bytes 2-4**: X coordinate (24-bit or high + mid + low).
- **Bytes 5-7**: Y coordinate (same).
- **Bytes 8-9**: Pressure (16-bit, masked to 0-2047) **and/or** tilt (XTilt/YTilt).
  - Pressure starts at `0x0000` in pure hover logs and rises cleanly in tip-press logs.
  - Your current "heavy/leaky" feel is almost certainly wrong scaling, sign extension, or using pressure instead of the tip-switch bit.

**Swift Parser Skeleton** (add to your report handler):
```swift
struct DTK2400PenReport {
    let bytes: [UInt8] // exactly 10 bytes
    
    var inProximity: Bool { bytes[1] & 0x80 != 0 || bytes[1] >= 0xE0 }
    var tip: Bool { bytes[1] & 0x01 != 0 }                    // ← This fixes your tap issue
    var barrel1: Bool { bytes[1] & 0x02 != 0 }                // lower button
    var barrel2: Bool { bytes[1] & 0x04 != 0 }                // upper button
    var eraser: Bool { bytes[1] & 0x08 != 0 || bytes[1] == 0xE1 /* confirm with logs */ }
    
    var x: UInt32 { /* combine bytes[2...4] as 24-bit */ }
    var y: UInt32 { /* combine bytes[5...7] as 24-bit */ }
    
    var pressure: UInt16 { UInt16(bytes[8]) << 8 | UInt16(bytes[9]) & 0x07FF } // 2048 levels
    // Tilt (if present in descriptor): bytes[8/9] split or separate
    
    // Logical max from specs: ~518.4 mm × 5080 lpi → X max ≈ 2630-ish logical units (exact from descriptor)
}
```

**Key fixes this gives you**:
- **Tap-to-left-click**: Use the **tip switch bit** (byte 1), **not** pressure > threshold. This eliminates the "bizarre pressure profile" and barrel-combo hack.
- **Pressure**: Scale exactly to 0-2047. In hover logs pressure is `0x0000` (or very low); in tip logs it ramps cleanly. Any "leakiness" is from your current parser treating pressure as signed or masking wrong bits.
- **Buttons & Eraser**: Direct bits from byte 1 (matches your "Barrel-1-Plus-Tip-Works", "Barrel-2-Works", and eraser logs).
- **Hover**: `inProximity == true` but `tip == false && pressure == 0`.

### 4. Pressure Feel & Curve Matching (1-2 hours of tuning)
Wacom’s driver uses a non-linear curve for the KP-501E Grip Pen (2048 levels). Your current "heavy" feel is likely linear or offset.
- Start with raw 0-2047.
- Apply Wacom-style transfer (common for this era): `normalized = pow(pressure / 2047.0, 0.5..0.8)` or a lookup table tuned against real Wacom driver output.
- Test with your logs: replay tip-press sequences and verify pressure hits 0 immediately on lift (no leak).

### 5. Testing Workflow (Use Your Logs First!)
1. **Replay harness** (Swift or quick Python script): Parse every line of the six `.txt` files → emit parsed events → assert:
   - Hover logs → pressure 0, tip off.
   - Tip-broken logs → tip on + pressure rise (should now trigger click).
   - Barrel logs → correct button bits.
   - Eraser logs → eraser flag.
2. Hardware test: 
   - Tap (should click cleanly).
   - Hover (no ghost pressure).
   - Full pressure range (smooth, not heavy).
   - Buttons + eraser.
3. Apps: Test in Krita, Photoshop, Preview (pressure + tilt if present).

### 6. Edge Cases & Polish
- Report rate: Up to 133 Hz — your driver already handles high-rate input well.
- Tilt: If descriptor shows tilt in bytes 8-9, expose as `tiltX`/`tiltY` (±60 levels) for apps that support it.
- Out-of-range / lift: Ensure pressure → 0 and tip → false instantly.
- Compatibility: This parser will be isolated to DTK-2400 (no impact on your other tablets).

### Expected Outcome
Once the parser matches the descriptor + your logs, tapping will work exactly like Wacom’s driver (clean tip-switch), pressure will feel natural (no heavy/leak), and all buttons/eraser will function. This is the same approach that made every other tablet in your driver work after "individual tuning."

Start with the report descriptor dump (step 2) — it will confirm the byte/bit layout in minutes. If you share the descriptor (or a few parsed byte examples from a specific action), I can give you the exact Swift parsing code line-by-line.

This gets you production-ready support for the Cintiq 24HD with zero reliance on third-party drivers. Let me know which step you want to tackle first or if you need a replay script!