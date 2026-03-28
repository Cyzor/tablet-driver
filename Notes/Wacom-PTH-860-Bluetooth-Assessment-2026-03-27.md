2026-03-27

# Here's a data capture session for a Wacom Intuos PTH-860 tablet connected over Bluetooth.  The computer sees it, but can't do anything with it.  Seems to think it's an Apple Magic Trackpad, too.  The same device works without issue over USB.

The data reveals a clear two-layer problem: a macOS driver conflict that you need to tackle at the system level, and three decoder differences between the PTH-860 and PTH-660 that will bite you once the system-level issue is resolved.

## The Magic Trackpad Problem Is Architectural, Not a Bug

When the PTH-860 connects over BLE, macOS's `AppleBluetoothMultitouch` kext claims it because the tablet's GATT HID descriptor includes pointer/touch usages that Apple's heuristic matches to a trackpad profile. This is well-documented for Wacom BLE on macOS — it's not specific to MockTab. The driver translates hover motion into trackpad cursor movement (explaining "the computer sees it") but owns the device exclusively enough to suppress any stylus-specific interpretation.[^1]

MockTab is receiving 686 reports — it has the device open. But if it hasn't called `kIOHIDOptionsTypeSeizeDevice` on the BLE HID device handle, the multitouch driver is running in parallel and intercepting the cursor pipeline. **Seize the device.** If MockTab is already seizing it and the Magic Trackpad behavior persists, the seize is targeting the wrong interface — BLE tablets on macOS can present multiple logical HID interfaces and the multitouch driver may have latched onto a separate one before MockTab opened its handle.

## PTH-860 vs PTH-660 BT: Three Structural Differences

The container format is identical: Report ID `0x80`, 361 bytes, 14-byte sub-reports packed from byte onward. The sub-report flag encoding (`0xC0` = proximity enter, `0xE0` = hover/motion) is the same. But three fields differ from PTH-660 and will silently break the existing decoder:[^2][^1]

### 1. Device Signature Block (byte) Is Different

The metadata block at byte 99 (sub-report slot 7, at `1 + 7×14 = 99`) is the device identifier the decoder uses to recognize the tablet:


| State | PTH-860 | PTH-660 |
| :-- | :-- | :-- |
| Pen absent | `CE 00 80 03 04 08 11 00 04 08` | `6A 35 00 08 06 08 10 00 06 08` |
| Pen present | `B7 A5 80 14 42 08 10 00 42 08` | same as absent |

If the decoder matches on `6A 35` as a validity check for PTH-660, it will reject every PTH-860 report. Add `CE 00` and `B7 A5` as valid PTH-860 device signatures. Note also that the secondary signature at byte 284 is `64 7F 38 01` for PTH-860 vs `63 7F 38 01` for PTH-660 — a single-bit difference, likely a model ID.

### 2. Sub-report Bytes[9:10] = `F9 FF` (Constant, Not Zero)

Every PTH-860 `E0` motion sub-report has bytes[9:10] = `0xFF F9` = signed `-7` (little-endian int16). The PTH-660 has `00 00` here. This field is likely pen barrel rotation — the PTH-860 has rotational tilt sensing that the PTH-660 doesn't. The value `-7` is a static near-upright reading for a pen held normally.[^1]

**The decoder risk:** if any guard condition checks `bytes[9:10] == 0` to validate the sub-report as a "simple pen" (no rotation data), it will drop all PTH-860 motion reports. Treat `bytes[9:10]` as barrel rotation, signed int16 LE, and accept it regardless of value.

### 3. Sub-report Byte = Altitude/Proximity Countdown (Not Zero)[^3]

PTH-860 `byte[^13]` encodes pen altitude: `0x3F` (63) when the pen first enters detection range, counting down to `0x1D` (29) when hovering close, then back up as the pen lifts. PTH-660 always has `00` here.

Altitude values seen across this session: 63 → 29 → 63.[^1]

**The decoder risk:** any validation or end-of-record check expecting `byte[^13] == 0x00` will reject all PTH-860 motion sub-reports. Treat `byte[^13]` as an altitude/proximity field. Values above 0 are valid motion data, not error states.

## Coordinate Max Must Change

The PTH-860 is an L-size tablet vs the PTH-660's M-size. Observed coordinate ranges in this session: X ≈ 37,905–41,497, Y ≈ 21,996–24,195 — consistent with a central pen position on a larger surface. The PTH-860's documented maximum coordinates (per Linux `wacom_wac.c` for product ID `0x0357`) are approximately **X-max = 65,024, Y-max = 40,640**. Using the PTH-660's max values would cause the pen to map only to the top-left portion of the screen.[^1]

## What This Capture Cannot Confirm

This session is **pure hover** — no `0xE2` tip-pressed sub-reports appear anywhere in 686 reports. Pressure was never applied, so the pressure decoder path is entirely untested for the PTH-860 over BT. Pending the Magic Trackpad seize fix and decoder updates above, capture a new session with deliberate tip presses to verify that `bytes[5:7]` (pressure, 16-bit LE) behaves correctly and that the PTH-860's 8192-level pressure range (vs PTH-660's 2048) is normalized correctly in the output pipeline.

<div align="center">⁂</div>

[^1]: Wacom-PTH-860-Bluetooth-2026-03-27.txt

[^2]: todo.md

[^3]: https://www.weareyuma.com/en/insights/news/bluetooth-low-energy-logging-placing-macinthemiddle

