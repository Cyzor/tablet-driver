2026-03-27

## MockTab KC-100 Mouse Button Debug — Actual Status

**The buttons are not fixed.** Root cause was correctly identified (4-byte ID=0x01 reports routed to `decodeBLEPenReport` which silently returned nil), but the fix is incomplete. Here's what the capture logs actually prove:

***

### USB: Logger Is Not Capturing Mouse Interface Reports

All three USB capture sessions (v1, v2, v3) show **zero ID=0x01 reports**. The raw report callback registered for driving purposes is on the seized `usagePage=0x01` device handle, but the capture logger only hooks the digitizer device handle (`usagePage=0x0D`). The 4-byte mouse reports are arriving at the callback (confirmed by the routing bug symptom) but are invisible to the logger and therefore unverified as correctly decoded.

**The decoder fix may be correct in structure, but it has never been confirmed against actual captured button data.**

### USB: What ID=0x01 Button Reports Should Look Like

From the `ioreg` HID descriptor (confirmed): Report ID 0x01 is a standard 4-byte HID mouse report:

```
[^0] = 0x01  (report ID — stripped by IOHIDDevice callback, so actual buffer is 3 bytes)
[^1] = button bits: bit0=left, bit1=right, bit2=middle; bits3–7=padding
[^2] = relative X (int8)
[^3] = relative Y (int8)
```

Left click down = `01 00 00`, left click up = `00 00 00`. Right = `02 00 00`. Middle = `04 00 00`. **Note:** `IOHIDDeviceRegisterInputReportCallback` strips the report ID byte — your decoder receives a 3-byte buffer starting with the button byte, not a 4-byte buffer starting with `0x01`. If the decoder is indexing `report[^1]` for buttons expecting the report ID to still be present, that's the live bug.

### BT: No Button Data Found Anywhere in 0x80 Container

Exhaustive analysis of all 361 bytes across 1,337 BT reports found no byte position with press/release transition patterns. The 0x80 container's byte flags (`0xE0` = `11100000`) uses bits 5–7 for status only; bits 0–4 are always zero across the entire session. **BT mouse button support may be unimplemented in the tablet firmware** — the RF link from KC-100 to tablet may not forward button state through the BT transport at all.[^1]

### Scroll Wheel: Unknown

No scroll wheel data appeared in any capture. The `ioreg` descriptor for Report ID 0x01 declares only 3 buttons + relative X/Y — no wheel axis. Scroll may arrive on a separate report ID not yet captured, or may not be supported by the KC-100 over this transport.

***

### Actionable Steps

1. **Verify the byte offset bug:** In the `usagePage=0x01` report callback, confirm you're reading `report[^0]` for buttons (not `report[^1]`). `IOHIDDeviceRegisterInputReportCallback` delivers the buffer *without* the leading report ID byte.
2. **Attach the logger to the mouse interface handle:** Add a logging branch to the same callback that handles the `usagePage=0x01` device, tagged distinctly. Capture left/right/middle clicks and verify the button byte toggles as expected.
3. **BT buttons:** Treat as unimplemented until proven otherwise. No evidence in any BT capture that the 0x80 container carries KC-100 button state. The mouse may simply not transmit button events over BT.
4. **Scroll wheel:** After confirming button fix, do a dedicated capture rolling the wheel and scan for any new report ID appearing on either interface.

<div align="center">⁂</div>

[^1]: todo.md

