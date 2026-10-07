# Wacom pen display protocols (Cintiq, DTU, PL) and the ExpressKey Remote

Pen displays reuse the tablet formats more than they invent their own:

- The Cintiq 12WX through 27QHD send the
  [Intuos 10-byte pen report](Wacom-Intuos-10-Byte-Protocol.md).
- The Cintiq 16/22/24, Cintiq Pro, Wacom One, and MobileStudio Pro send the
  [Intuos Pro gen 2 192-byte report](Wacom-Intuos-Pro-Gen2-Protocol.md),
  some in its `0x1E` form.
- The Movink 13 sends the [gen 3 `0x1E` report](Wacom-Intuos-Pro-Gen3-Protocol.md).

This page covers what is particular to the displays. Confidence labels:
**observed** · **kernel** · **unverified**, as on the other pages.

## Older Cintiq (12WX through 27QHD)

Pen data arrives as the 10-byte format on report `0x02` or `0x10`. Seen on
a Cintiq 24HD (DTK-2400) and the Cintiq 27QHD Touch (DTH-2700).

**Tip switch, report `0x01`.** A mouse-style collection reports the tip
switch separately from the pen report, and the OS treats it as a left click.
Seizing the device should stop that, but no capture has confirmed it. With some Grip Pens the pen report's pressure
reads zero at the moment the tip goes down, so the tip switch is the only
sign of contact. (observed)

**Barrel buttons pulse.** While held, a barrel button bit is set in only
about one report in five. Hold the button down through short gaps (around
50 ms) rather than releasing on the first clear report. (observed)

**Rotation packets set bit 1.** The Art Pen's rotation packet has status
`0xEA`, which includes bit 1 as part of its type field. Read barrel buttons
from pen packets (types `0x00`–`0x03`) only, or button 1 sticks on. These
packets carry no pressure, so keep the last pressure through them; emitting
zero turns strokes into dotted lines. (kernel, consistent with the type
field)

**Pro Pen (KP-503E).** On the 27QHD it reports tool code `0x1E02`; see the
[pen tool codes](Wacom-Pen-Tool-Codes.md). (observed, two units)

**ExpressKeys and touch strips, report `0x0C`.** Layout varies by model:
on the 21UX2 and 22HD, `[3]`–`[4]` are touch-strip positions and `[5]`/`[7]`
bit 0 are the two center toggles. (kernel)

**24HD panel buttons.** The three "buttons" printed on the 24HD's bezel
are one capacitive slider under three icons. A tap on an icon sets one
fixed bit: `[3]` bit 4 for info (left), `[4]` bit 6 for the keyboard
(middle), `[4]` bit 0 for the wrench (right). A swipe walks a single bit
through `[3]` bits 4–0 and `[4]` bits 7–0. Decode only the three fixed
bits; the kernel's approach of OR-ing whole regions misfires during swipes.
(observed, DTK-2400)

**27QHD panel buttons, report `0x11`.** `[2]` bits 0–2 are the three buttons
on the display's own panel. Bytes 5, 7, and 9 drift slowly whether or not a
button is pressed, possibly an ambient light sensor. (observed, DTH-2700)

## Cintiq Pro 16 (DTH-167)

Pen data is the gen 2 report `0x10`, with tilt at ±64°. The pen display has a
single HID interface, and its first collection is a generic desktop
(page `0x01`) one; the pen collection follows on the same interface. Don't
wait for a separate vendor interface, as on the Intuos Pro; there isn't one.
The descriptor declares feature reports `0x02`, `0x07`, `0x0D`, and `0x14`.
After writes to `0x0D` and `0x02` (DATAMODE), pen reports arrive. (observed)

The DTH-1620 (2017) carries the same name and panel size, so use the touch
range to tell the two apart: 13824 × 7776 on the DTH-1620, 13768 × 7744 on
the DTH-167. (observed on the DTH-167, unverified on the DTH-1620)

## Cintiq touch

On every Cintiq with touch, the touch sensor is a separate USB device with
its own product ID, paired with the pen device.

**Cintiq 27QHD Touch (pen `0x032B`, touch `0x032C`).** Touch arrives as
report `0x88`: a standard HID Digitizer touch-screen collection that the
device's own descriptor fully describes. Parse it from the descriptor. The
kernel's `WACOM_27QHDT` layout (report `0x05`) is not what this device
sends. (observed)

**Cintiq Pro 24 (DTH-2420).** Also report `0x88`, but its descriptor
declares a tip switch and no contact identifier, so use the slot position
as the contact ID. (observed, descriptor)

**Cintiq Pro 16 (DTH-167, pen `0x03B2`, touch `0x03B3`).** Touch is a
standard HID Digitizer touch-screen collection with five contacts, at
13768 × 7744. Parse it from the descriptor. (observed)

**Cintiq 13HD, 22HD, and 24HD Touch.** The kernel's `wacom_24hdt_irq()`:
report `0x01`, four 14-byte contact records, and a frame-wide contact count
in `[61]`, so frames can span several reports. (kernel)

## ExpressKey Remote (EKR-100)

A wireless keypad with 17 keys and a touch ring, reached through its own
USB receiver (PID `0x0331`). Its 32-byte reports sit on an opaque vendor
collection, so the descriptor gives no layout.

Report `0x11`, remote event:

| Offset | Field | Confidence |
| --- | --- | --- |
| 3–5 | Remote serial, 24-bit little-endian | kernel |
| 7 | Battery: bits 0–6 percent, bit 7 charging | kernel |
| 9 | Bit 0 ring center button; bits 1–7 keys 1–7 | kernel |
| 10 | Keys 8–15 | kernel |
| 11 | Bits 0–1 keys 16–17; bits 6–7 active ring mode, 0–2 | observed (mode) |
| 12 | Ring: bit 7 touched, bits 0–6 position + 1 (so 0–71 after subtracting 1) | kernel |

The ring mode is a state, not an event: the center button changes it, and
the remote's firmware lights the matching LED. The host can read the mode
but can't set it. (observed)

Report `0x10`, the receiver's pairing table: five 6-byte slots, with slot
`i`'s remote serial at `[i*6 + 4]` to `[i*6 + 6]`. A slot is in use exactly
when its serial is non-zero; the kernel reads nothing else from it. The
table arrives about every 600 ms whether or not a remote is active.
(observed)

## Business and signature displays

Wacom's business line (signature pads and annotation displays) shares
product-ID space with the Cintiq, but MockTab doesn't target it. These
models stay recognized and decode where a format is known; nothing more
is planned.

| Model | Pen PID | Touch PID | Format |
| --- | --- | --- | --- |
| DTU-1031, DTU-1031X, DTU-1141, DTK-1651 | `0x00FB`, `0x032F`, `0x0336`, `0x0343` | — | `wacom_dtus_irq()` |
| DTU-1631, DTU-2231 | `0x00F0`, `0x00CE` | — | `wacom_dtu_irq()` |
| DTI-520 | `0x003A` | — | `wacom_dtu_irq()` |
| DTU-710, DTU-1931 | `0x0039`, `0x00C7` | — | `wacom_pl_irq()` |
| DTU-1141B | `0x0359` | — | generic HID |
| DTH-1152 | `0x035A` | `0x0368` | generic HID |
| DTH-2452 | `0x037D` | `0x037E` | generic HID |
| DTK-2451 | `0x0382` | — | generic HID; not in the registry |

Public recordings of a DTU-1031 and a DTU-2231 decode correctly through
TabletKit's DTUS and DTU decoders. (**observed**)

The last four have no fixed-format parser in the Linux driver: they fall
through to its generic path, which decodes whatever the report descriptor
declares. A "DTUS2" format for the DTU-1141B was proposed on the
linuxwacom mailing list but never merged. (**kernel**)

The DTH-2452 and DTK-2451 descriptors claim tilt, hover distance, tool
serials, and extra tools the hardware doesn't have. The kernel strips
them in `wacom_setup_device_quirks()`, because waiting for a serial that
never comes breaks proximity. Don't trust those fields on these two
models. The DTH-2452's touch sensor declares 17568 × 9882, five contacts
per report. (**kernel**; touch descriptor from the kernel's HID selftests)

## Formats known only from the kernel

No captures of these exist, so their layouts are left to the source. Read
the named function in `drivers/hid/wacom_wac.c`.

| Devices | Kernel function | Notes |
| --- | --- | --- |
| PL-400 to PL-800 (Cintiq 15X, 18SX) | `wacom_pl_irq()` | Report `0x02`, 8 bytes. Eraser vs. second button is decided once, on entering proximity. Feature report `[0x02, 0x02]` confirmed on a PL-800. |
| DTU-2231, DTU-1631 | `wacom_dtu_irq()` | 8 bytes, little-endian, 9-bit pressure |
| DTU-1031, DTU-1141, DTK-1651 | `wacom_dtus_irq()` | Pen on `0x11`, big-endian; four keys on `0x15` |
| Cintiq 13HD, 22HD, and 24HD Touch | `wacom_24hdt_irq()` | See Cintiq touch above |
| ExpressKey Remote | `wacom_remote_irq()`, `wacom_remote_status_irq()` | See above |

## Unverified

- Touch on the DTH-2400 and DTH-2200: separate interface, format unknown.
- Which ExpressKey Remote bit belongs to which physical key.

## Tests

These TabletKit tests check the layouts above, many with frames from real captures:

- [`CintiqV1DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/CintiqV1DecoderTests.swift)
- [`CintiqV1Decoder+PressureDepthTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/CintiqV1Decoder+PressureDepthTests.swift)
- [`DTUDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/DTUDecoderTests.swift)
- [`DTUSDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/DTUSDecoderTests.swift)
- [`WacomPLDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/WacomPLDecoderTests.swift)
- [`Wacom24HDTDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/Wacom24HDTDecoderTests.swift)
- [`Wacom27QHDTDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/Wacom27QHDTDecoderTests.swift)
- [`ExpressKeyRemoteDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/ExpressKeyRemoteDecoderTests.swift)
