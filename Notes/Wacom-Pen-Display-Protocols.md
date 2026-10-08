# Wacom Pen Display Protocols

This page covers what's particular to Wacom's pen displays (Cintiq and PL) and the ExpressKey Remote. Most pen displays reuse a tablet's pen report, so start with the page for that format:

- **Cintiq 12WX through 27QHD, and the 13HD:** the [Intuos 10-byte report](Wacom-Intuos-10-Byte-Protocol.md).
- **Cintiq 16, 22, and 24, Cintiq Pro, Wacom One, and MobileStudio Pro:** the [Intuos Pro gen 2 report](Wacom-Intuos-Pro-Gen2-Protocol.md), some in its `0x1E` form.
- **Movink 13:** the [gen 3 `0x1E` report](Wacom-Intuos-Pro-Gen3-Protocol.md).

Each fact carries a label, as on the other pages: **observed** on hardware, from the Linux **kernel** source, or **unverified**.

## Older Cintiq Models

Pen data arrives in the 10-byte format on report `0x02` or `0x10`. (observed on a Cintiq 24HD and 27QHD Touch)

### Read the Tip Switch Separately

A mouse-style collection reports the tip switch on report `0x01`, apart from the pen report. macOS treats it as a left click unless the driver has exclusive access to the device. With some Grip Pens, pressure reads zero at the moment the tip goes down, so this tip switch is the only sign of contact. (observed)

### Hold Barrel Buttons Through Gaps

While a barrel button is held, its bit is set in only about one report in five. Treat a short gap, around 50 ms, as still held rather than releasing on the first clear report. (observed)

### Skip Buttons in Rotation Packets

The Art Pen's rotation packet has status `0xEA`. Bit 1 is part of its type field there, not a button, so read barrel buttons from pen packets (types `0x00`–`0x03`) only, or button 1 sticks on. Rotation packets carry no pressure either. Keep the last pressure through them, or strokes turn into dotted lines. (kernel, consistent with the type field)

The Pro Pen (KP-503E) reports tool code `0x1E02` on the 27QHD. See the [pen tool codes](Wacom-Pen-Tool-Codes.md). (observed, two units)

### ExpressKeys and Touch Strips

Report `0x0C`. The layout varies by model. On the 21UX2 and 22HD, bytes 3–4 are touch-strip positions, and bit 0 of bytes 5 and 7 are the two center toggles. (kernel)

### 24HD Panel Buttons

The three buttons printed on the 24HD's bezel are one touch slider under three icons. A tap sets one fixed bit:

| Icon | Bit |
| --- | --- |
| Info (left) | byte 3, bit 4 |
| Keyboard (middle) | byte 4, bit 6 |
| Wrench (right) | byte 4, bit 0 |

A swipe walks a single bit through byte 3 bits 4–0 and byte 4 bits 7–0. Decode only the three fixed bits. Treating a whole region as one button fires it during swipes, which the kernel does. (observed)

### 27QHD Panel Buttons

Report `0x11`. Byte 2 bits 0–2 are the three buttons on the display's panel. Bytes 5, 7, and 9 drift slowly whether or not a button is pressed, possibly from an ambient light sensor. (observed)

## Cintiq 13HD

The 13HD (`0x0304`) and 13HD Touch (`0x0333`) send the 10-byte pen report on a single interface that also holds a mouse collection. Don't wait for a separate pen interface; there isn't one. (observed on the 13HD Touch)

ExpressKeys arrive on report `0x11`: nine buttons, read as `(byte 4 << 1) | (byte 3 & 1)`. Byte 1 is always `0x80`. (kernel, matches the 13HD Touch)

## Cintiq Pro 16 (DTH-167)

Pen data is the gen 2 report `0x10`, with tilt at ±64°. The display has a single interface. Its first collection is a generic desktop one, and the pen collection follows. Don't wait for a separate vendor interface, as on the Intuos Pro. Pen reports start after writes to feature reports `0x0D` and `0x02`. (observed)

The older DTH-1620 shares the name and panel size. Tell them apart by touch range: 13768 × 7744 on the DTH-167, 13824 × 7776 on the DTH-1620. (observed on the DTH-167, unverified on the DTH-1620)

## Cintiq Touch

Every Cintiq with touch has its touch sensor as a separate USB device with its own product ID.

- **27QHD Touch** (pen `0x032B`, touch `0x032C`) and **Cintiq Pro 16** (pen `0x03B2`, touch `0x03B3`) send a standard touch-screen collection that their descriptors fully describe. Parse it from the descriptor. The 27QHD Touch doesn't send the kernel's `WACOM_27QHDT` layout. (observed)
- **Cintiq Pro 24** (DTH-2420) also sends a standard collection on report `0x88`, but declares no contact ID. Use the slot position as the ID. (observed, descriptor)
- **13HD, 22HD, and 24HD Touch** follow the kernel's `wacom_24hdt_irq()`: report `0x01`, four 14-byte contact records, and a frame-wide contact count in byte 61, so one frame can span several reports. (kernel; observed on the 13HD Touch)

## ExpressKey Remote (EKR-100)

A wireless keypad with 17 keys and a touch ring, connected through its own USB receiver (`0x0331`). Its 32-byte reports use a vendor collection, so the descriptor gives no layout.

Report `0x11` carries key and ring events:

| Byte | Field | Label |
| --- | --- | --- |
| 3–5 | Remote serial, 24-bit little-endian | kernel |
| 7 | Battery: bits 0–6 percent, bit 7 charging | kernel |
| 9 | Bit 0 ring center button; bits 1–7 keys 1–7 | kernel |
| 10 | Keys 8–15 | kernel |
| 11 | Bits 0–1 keys 16–17; bits 6–7 ring mode, 0–2 | observed (mode) |
| 12 | Ring: bit 7 touched; bits 0–6 position plus 1 | kernel |

The center button cycles the ring mode, and the remote lights the matching LED itself. A driver can read the mode but can't set it. (observed)

Report `0x10` is the receiver's pairing table, sent about every 600 ms. It holds five 6-byte slots, with slot `i`'s serial at bytes `i*6 + 4` through `i*6 + 6`. A slot is in use when its serial isn't zero. (observed)

## Formats Known Only From the Kernel

No captures of these exist, so read the named function in the kernel's `drivers/hid/wacom_wac.c`.

| Devices | Function | Notes |
| --- | --- | --- |
| PL-400 to PL-800 (Cintiq 15X, 18SX) | `wacom_pl_irq()` | Report `0x02`, 8 bytes. The tablet decides eraser vs. second button on entering range. A PL-800 confirms feature report `[0x02, 0x02]`. |
| ExpressKey Remote | `wacom_remote_irq()`, `wacom_remote_status_irq()` | Covered above |

## Unverified

- Touch on the 24HD (DTH-2400) and 22HD (DTH-2200): separate interface, format unknown.
- Which ExpressKey Remote bit belongs to which physical key.

## Out of Scope: Business and Signature Displays

MockTab doesn't target Wacom's signature pads and business displays. They stay recognized and decode where the format is known, and no further work is planned.

| Models | Format |
| --- | --- |
| DTU-1031, DTU-1031X, DTU-1141, DTK-1651 | `wacom_dtus_irq()`: pen on `0x11`, big-endian; four keys on `0x15` |
| DTU-1631, DTU-2231, DTI-520 | `wacom_dtu_irq()`: 8 bytes, little-endian, 9-bit pressure |
| DTU-710, DTU-1931 | `wacom_pl_irq()` |
| DTU-1141B, DTH-1152, DTH-2452, DTK-2451 | Generic HID, from the descriptor |

Public recordings of a DTU-1031 and a DTU-2231 decode correctly. (observed) The DTH-2452 and DTK-2451 descriptors claim tilt, hover distance, and pen serials the hardware doesn't have. Ignore those fields, because waiting for a serial that never comes breaks proximity. (kernel)

## Tests

These TabletKit tests check the layouts above, many with frames from real captures:

- [`CintiqV1DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/CintiqV1DecoderTests.swift) and [`CintiqV1Decoder+PressureDepthTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/CintiqV1Decoder+PressureDepthTests.swift)
- [`IntuosV1Decoder+ExtendedTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV1Decoder+ExtendedTests.swift) (13HD ExpressKeys)
- [`Wacom24HDTDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/Wacom24HDTDecoderTests.swift) and [`Wacom27QHDTDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/Wacom27QHDTDecoderTests.swift)
- [`ExpressKeyRemoteDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/ExpressKeyRemoteDecoderTests.swift)
- [`WacomPLDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/WacomPLDecoderTests.swift)
- [`DTUDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/DTUDecoderTests.swift) and [`DTUSDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/DTUSDecoderTests.swift)
