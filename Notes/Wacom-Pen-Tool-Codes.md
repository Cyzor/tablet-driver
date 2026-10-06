# Wacom pen tool codes

Every Wacom pen reports a tool code (what kind of pen) and a serial (which
pen). Where each sits in a report depends on the protocol; see the protocol
pages. This page lists only codes seen on hardware and the rules that hold
across them. For the full list of pens, see libwacom's stylus database
(`data/wacom-stylus.tablet` in the libwacom repository).

## Codes seen on hardware

| Code | Pen | Seen on |
| --- | --- | --- |
| `0x0802` / `0x080A` | Grip Pen, tip / eraser | PTH-860 (Bluetooth), PTK-870 |
| `0x0842` | Pro Pen 2 (KP-504E) | PTH-660, PTK-870 |
| `0x0804` | Art Pen | PTK-870 (checked against a pen of known identity) |
| `0x1108` | Art Pen | PTH-660 (Bluetooth) |
| `0x1804` | Art Pen, Intuos4/5 era (kernel `0x10804`) | PTH-850 |
| `0x0200` | Pro Pen 3 | PTK-870 |
| `0x8822` / `0x882A` | GD-series Grip Pen, tip / eraser | GD-0608-U |
| `0x1E02` | Pro Pen (KP-503E) | Cintiq 27QHD (DTK-2700), two units |

The last two are 16-bit packings of wider IDs and depend on how the decoder
folds the bits; see "Width" below.

## Rules

**Eraser bit.** For most pens bit 3 (`0x0008`) marks the eraser end: the
same pen body reports `0x0802` tip and `0x080A` eraser, with the same
serial. The GD-0608-U pen is the same: tip and eraser share serial
`0x998005E5` and differ only in that bit. (observed)

**Art Pen exception.** `0x1108` has bit 3 set but is a pen tip, not an
eraser. Test for known Art Pen codes before applying the eraser rule, and
prefer the report's own eraser and invert status bits over the tool code
wherever a protocol provides them. (observed)

**Rotation.** Only the Art Pen family reports barrel rotation. Other pens
leave the rotation field at a constant or at noise, so gate on the tool
code. Where the tool code can be missed (Bluetooth on the [PTK-x70](Wacom-Intuos-Pro-Gen3-Protocol.md)), use the protocol's "no reading" value instead. (observed)

**Pro Pen 3** has no eraser end and three side-switch positions.

**Serials.** The serial identifies a physical pen and is the same for both
ends. Both fields read 0 out of proximity on the Intuos Pro gen 3.
(observed)

## Art Pen generations

| Full ID | Pen | libwacom group |
| --- | --- | --- |
| `0x804` | Art Pen (Intuos4 era) | intuos4 |
| `0x10804` | Art Pen (Pro Pen 2 generation) | propengen2 |
| `0x204` | Art Pen 2 (Pro Pen 3 generation) | propen3 |

Tablets that report only 16 bits, such as the Intuos Pro gen 2 over USB and
gen 3, show both older pens as `0x0804`. Only the 10-byte format's full ID
tells them apart. On an Intuos Pro gen 3, one Art Pen of unknown generation
loses rotation and tracking at about a quarter of the hover height another
reaches; the same pen works through the full range on a PTH-860. (observed)

## Width

The Linux driver treats tool IDs as wider than 16 bits: for example
`0x10804` (Intuos4 Art Pen) and `0x16802` (Pro Pen KP-503E). Each protocol
spreads the ID across nibbles in its own way (see the [Intuos 10-byte page](Wacom-Intuos-10-Byte-Protocol.md#tool-enter-packet)),
and a decoder that stores 16 bits has to fold the high bits down. TabletKit
folds `0x16802` to `0x1E02`, which is no longer the same number as libwacom's.
Compare codes only within one convention. (kernel)

## Old notes this replaces

Earlier tables in these notes listed `0x0804` as the Pro Pen 3 and
`0x0812` as an Art Pen. On hardware, `0x0804` is the Art Pen and the Pro
Pen 3 is `0x0200`; the Linux driver lists `0x812` as the Inking Pen.

## Tests

These TabletKit tests check the codes above, many with frames from real captures:

- [`IntuosV2BTDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV2BTDecoderTests.swift)
- [`IntuosV2USBDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV2USBDecoderTests.swift)
- [`IntuosV3DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV3DecoderTests.swift)
- [`IntuosV1DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV1DecoderTests.swift)
- [`CintiqV1DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/CintiqV1DecoderTests.swift)
