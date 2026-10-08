# Wacom Intuos Pro Gen 2 Protocol (PTH-x60, CTL-x100)

The 192-byte pen report introduced with the Intuos Pro gen 2, also used by the
2018 Intuos (CTL-4100/6100) and by many pen displays (Cintiq 16/22/24, Cintiq
Pro, Wacom One, MobileStudio Pro). TabletKit decodes it in `IntuosV2Decoder`;
device coverage lives in `TabletKit/registry.json` (`"parser": "intuosV2"`).

Confidence labels: **observed** — seen on hardware or in the device's own HID
descriptor · **kernel** — from the Linux driver (`wacom_wac.c`) only ·
**unverified** — neither.

All multi-byte values are little-endian. Byte offsets include the report ID
at `[0]`.

## Reports by Transport

| Report | Transport | Size | Carries |
| --- | --- | --- | --- |
| `0x10` | USB | 192 | Pen |
| `0x1E` | USB | 192 (34 used) | Pen, alternate layout (pen displays) |
| `0x11` | USB | 9 | ExpressKeys and touch ring |
| `0x21` | USB | 44 | Finger touch |
| `0x80` | Bluetooth Classic | 99 or 361 | Packed pen frames; the 361-byte form adds touch, pad, battery |
| `0x81` | Bluetooth | ≥ 46 | Packed pen frames, CTL-x100WL |
| `0x01` | USB | ≤ 8 | Mouse buttons from a separate mouse interface |

## USB Pen Report `0x10`

| Offset | Field | Notes | Confidence |
| --- | --- | --- | --- |
| 1 | Status | bits below | observed (descriptor) |
| 2–4 | X | 24-bit | observed |
| 5–7 | Y | 24-bit | observed |
| 8–9 | Pressure | 13 bits: `[8] \| ([9] & 0x1F) << 8`; 0–8191 (CTL-x100: 0–4095) | observed |
| 10 | Tilt X | signed byte, ±64 = ±64° | observed (descriptor) |
| 11 | Tilt Y | signed byte, ±64 = ±64° | observed (descriptor) |
| 12–13 | Rotation | signed 16-bit, 1800 counts per turn; Art Pen only, other pens send noise | observed |
| 16 | Hover distance | 0 = contact, rising to 63 at the edge of range | kernel |
| 17–20 | Tool serial | 32-bit | observed |
| 21–22 | Tool code | 16-bit; zero on weak frames | observed |

Status byte:

| Bit | Mask | Meaning |
| --- | --- | --- |
| 0 | `0x01` | Tip switch |
| 1 | `0x02` | Barrel button 1 |
| 2 | `0x04` | Barrel button 2 |
| 3 | `0x08` | Eraser (eraser end pressed) |
| 4 | `0x10` | Invert (eraser end in range) |
| 5 | `0x20` | In range — frame is trustworthy |
| 6 | `0x40` | Proximity |

**Eraser.** Treat the tool as an eraser when either `0x08` or `0x10` is set.
`0x08` alone makes the eraser exist only in contact, so apps see every eraser
stroke begin as the pen. (observed, PTH-860)

**Leaving range.** The status runs `0x60` → `0x40` → `0x00`. Only `0x00`
(proximity and range both clear) is a real exit. Frames at `0x40` are weak:
tool code, tilt and rotation read as zero, so hold the previous values,
including the eraser state. An Art Pen produces bursts of `0x40` while still
on the surface. (observed)

**Art Pen.** Tool codes `0x0804` and `0x1108`. `0x1108` has bit 3 set, so the
common "tool code `& 0x08` means eraser" rule misfires on it. (observed)

**Cordless mouse (KC-100).** Tool codes with low nibble `0x6` (`0x0806`) are
the mouse; test `(code & 0x000F) == 0x0006`, since `0x0806` also has bit
`0x0800` set. Its buttons never appear in report `0x10`: status stays `0x60`
whatever is pressed. Left, right, and middle arrive on the tablet's separate
mouse interface as report `0x01` (4 bytes, `[1]` bit 0 left, 1 right, 2
middle). The wheel is an 8-bit counter in `[16]`; take the signed difference
from the previous report. (observed)

## USB Pen Report `0x1E` (Pen Displays)

A second layout, seen on the Cintiq Pro 22 (DTH-227) and shared by the Cintiq
Pro 17 and 27, whose pen descriptors differ only in coordinate maxima. The
device sends 192 bytes; only the first 34 carry data. `[1]` is a constant
`0x01`.

| Offset | Field | Confidence |
| --- | --- | --- |
| 2 | Status: bit 0 tip, bits 1–3 barrel buttons, 4 eraser, 5 invert, 6 range, 7 proximity | observed + kernel |
| 3–5 | X, 24-bit | observed |
| 6–8 | Y, 24-bit | observed |
| 9–10 | Pressure, 16-bit | observed |
| 11–12 | Tilt X, signed 16-bit, ±90 | observed |
| 13–14 | Tilt Y, signed 16-bit, ±90 | observed |
| 15–16 | Rotation, signed 16-bit | kernel |
| 17–18 | Airbrush wheel | kernel |
| 19 | Hover distance | observed |
| 20–27 | Tool unique ID, 64-bit | kernel |
| 28 | Tool type | kernel |

OpenTabletDriver's `IntuosV2OffsetReport` reads tilt as single bytes at 11 and
12 and hover at 11. All three are wrong: byte 12 is the high byte of X tilt.

## USB ExpressKey Report `0x11` (PTH-x60)

| Offset | Field |
| --- | --- |
| 1 | Keys, one bit each, mechanical press |
| 2 | Keys, capacitive touch — fires on the lightest contact |
| 3 | Touch-ring center button, non-zero while pressed |
| 4 | Touch-ring position 0–71 (5° steps); `0x7F` = no finger |

Observed. `[4] != 0x7F` signals ring contact, not `[3]`.

## USB Finger Touch `0x21` (PTH-660, PTH-860)

`[1]` is the contact count, followed by five fixed 8-byte slots starting at
`[2]`:

| Slot offset | Field |
| --- | --- |
| 0 | Contact ID |
| 1 | Status: `0x01` down, `0x00` lift (sent once, then the slot goes silent) |
| 2–3 | X, 16-bit |
| 4–5 | Y, 16-bit |
| 6 | Contact width |
| 7 | Contact height |

Observed, and backed by the PTH-660's touch descriptor, which declares
logical maxima of 8960 × 5920 (contact size 41 × 31). Touch formats for the
pen displays in this family are unconfirmed.

## Bluetooth Classic `0x80` (PTH-660, PTH-860)

These tablets pair as `BT IntuosPro …` over Bluetooth Classic. The
`LE IntuosPro …` identity serves Wacom's paper-notes mode and does not act as
a tablet. (kernel)

Report `0x80` is also the ACK-40401 dongle's status report; see
[wireless](Wacom-Wireless-and-Battery.md#ack-40401-dongle-status-report-0x80).
For pen data, length decides the shape: 99 bytes is
pen only; 361 bytes adds touch, pad, and battery. Either tablet can send either
form.

**Pen frames**: up to seven 14-byte frames at `[1]`, `[15]`, … `[85]`, oldest
first.

| Frame offset | Field | Confidence |
| --- | --- | --- |
| 0 | Flags: `0x80` valid, `0x40` proximity, `0x20` range, `0x10` invert, `0x08` eraser contact, `0x04`/`0x02` barrel buttons, `0x01` tip | observed + kernel |
| 1–2 | X, 16-bit | observed |
| 3–4 | Y, 16-bit | observed |
| 5–6 | Pressure, 13 bits | observed |
| 7 | Tilt X, signed byte, ±64 | observed (three pen types) |
| 8 | Tilt Y, signed byte, ±64 | observed |
| 9–10 | Rotation, signed 16-bit, 3600 counts per turn — twice the USB resolution | observed (PTH-660, Art Pen) |
| 11–12 | Airbrush wheel | kernel |
| 13 | Hover distance | observed |

The kernel counts `0x08` as tip contact too (tip = `0x09`); `0x10` picks
the eraser when the tool first comes into range.

Skip frames without `0x80`. Leaving range runs `0xE0` → `0xC0` → `0x80`, and
only proximity and range both clear is an exit. Tilt is signed; older kernels
read it unsigned, so a slight left tilt arrived as a hard right one.

**361-byte extras** (observed):

| Offset | Field |
| --- | --- |
| 99–106 | Tool serial, 64-bit (kernel) |
| 107–108 | Tool ID (kernel) |
| 109–280 | Four 43-byte touch frames |
| 281 | Touch-ring center button (`0x40` pressed) |
| 282 | Keys, mechanical — set for one report per press |
| 283 | Keys, capacitive touch |
| 284 | Battery: bit 7 charging, bits 0–6 percent |
| 285 | Touch ring: bit 7 active, bits 0–6 position 0–71 |

For most pens the serial's top 12 bits equal 1, and the kernel ORs bits
32–51 of the serial into the tool ID. So bytes 103–104 alone carry the full
tool code (`0x0804` for the Art Pen); that read is the one confirmed on
hardware.

Each touch frame: `[0]` bit 7 valid with the contact count in bits 0–6, then
five 8-byte contacts in the same layout as USB `0x21`, then a 16-bit device
clock at `[41]`–`[42]`. The clock ticks every 0.1 ms, frames sit 100 ticks
(10 ms) apart, and it wraps every 6.55 s. Reports arrive about every 22.5 ms,
carrying two or three frames each. The kernel ignores the clock. (observed,
PTH-660; [evidence](Evidence/Intuos-Pro-Bluetooth-Touch-Clock.md))

## Bluetooth `0x81` (CTL-4100WL, CTL-6100WL)

Same family, different geometry: four 8-byte pen frames and no tilt.

| Offset | Field |
| --- | --- |
| 1, 9, 17, 25 | Pen frames |
| 33–40 | Tool serial, 64-bit |
| 41–42 | Tool ID |
| 44 | ExpressKeys, bits 0–3 |
| 45 | Battery: bit 7 charging, bits 0–6 percent |

Frame: `[0]` flags (`0x80` valid, `0x40` proximity, `0x20` range, `0x10`
eraser, `0x04`/`0x02` barrel buttons), `[1]` X, `[3]` Y, `[5]` pressure, `[7]`
hover distance. When range is clear, X and Y are stale; hold the last
position. Pad and battery arrive in every report, pen or not.

Observed: replaying a 627-report CTL-4100WL capture through this layout
matched OpenTabletDriver's decoded output on 613 of 616 pen reports. The three
misses were the opening reports, which have no earlier position to hold.

## Unverified

- **BLE pen report `0x01`** (23 bytes, tilt possibly scaled as a sine):
  no capture exists.
- **Pad data in the 99-byte container**: offset unknown.
- **Touch report range on the PTH-860**: observed values reach
  12439 × 8639; nobody has read the descriptor yet.

## Tests

These TabletKit tests check the layouts above, many with frames from real captures:

- [`IntuosV2USBDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV2USBDecoderTests.swift)
- [`IntuosV2BTDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV2BTDecoderTests.swift)
- [`IntuosV2TouchDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV2TouchDecoderTests.swift)
- [`IntuosV2BTTouchDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV2BTTouchDecoderTests.swift)
