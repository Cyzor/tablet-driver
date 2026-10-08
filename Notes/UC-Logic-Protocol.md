# UC-Logic Protocol (Huion, Gaomon, XP-Pen, UGEE)

Many tablets from Huion, Gaomon, XP-Pen, UGEE, and Parblo run on chips from
one family, named UC-Logic after the company that started it. TabletKit
decodes their pen reports and buttons in `UCLogicDecoder`, and reads what
they say about themselves in `UCLogicTabletInfo`.

Labels work as in [the README](README.md), with **kernel** meaning Linux's
`hid-uclogic` driver. **Observed** covers a Xencelabs Pen Display 24, which
speaks UGEE v2, and public recordings of Huion tablets in the
[DIGImend tablet collection](https://github.com/DIGImend/tablets). Nobody
has tried a Huion tablet under macOS yet.

## Two Protocols

| | Huion v2 | UGEE v2 |
| --- | --- | --- |
| Brands | Huion, Gaomon | XP-Pen, UGEE, Parblo, Xencelabs |
| Vendor ID | `0x256C` | `0x28BD` |
| Switch on | Read string descriptor 200 | Send output report `02 B0 04` |
| Self-description | String descriptor 200 | String descriptor 100 |
| Pen report ID | `0x08` | `0x02` |

Older and smaller brands use UC-Logic's own vendor ID, `0x5543`, with either
protocol, or with older ones that don't describe themselves. Product IDs
don't identify models: Huion reuses a few across dozens of tablets. The
self-description sizes the tablet, so no model table is needed except to
name it. (kernel, observed)

Until switched on, these tablets act as a mouse. (kernel, observed)

**Huion v2.** Reading string descriptor 200 is itself the switch. Some
tablets answer every string descriptor they don't know with their product
name, so a reply that is only text isn't a self-description. (kernel,
observed)

**UGEE v2.** Send `[0x02, 0xB0, 0x04]` to the interface that declares
report `0x02`, padded with zeros to its largest output report size. The
firmware ignores a three-byte write even when the write succeeds. Then read
string descriptor 100. (kernel; padding observed)

Some XP-Pen tablets switch on with `02 B0 02` instead. The kernel doesn't
use it, and its difference from `02 B0 04` is unknown. (unverified)

String descriptors belong to the USB device, not its HID interface. On
macOS, IOHID can't read them, but a standard `GET_DESCRIPTOR` request
through IOKit's USB device interface can, without opening the device and
while a HID connection is open. A Wacom tablet answers unknown descriptors
with a USB stall, which is harmless. (observed)

## Self-Description

Offsets count from the start of the raw descriptor, including its two-byte
USB header. Values are little-endian.

String descriptor 200, Huion v2 (18 to 32 bytes):

| Bytes | Field | Confidence |
| --- | --- | --- |
| 2–4 | Maximum X | kernel, observed |
| 5–7 | Maximum Y | kernel, observed |
| 8–9 | Maximum pressure | kernel, observed |
| 10–11 | Resolution, lines per inch | kernel, observed |
| 13 | Buttons on the tablet | observed (four tablets) |

String descriptor 100, UGEE v2 (12 or 14 bytes):

| Bytes | Field | Confidence |
| --- | --- | --- |
| 2–3 | Maximum X; byte 12 is a third byte on 14-byte replies | kernel |
| 4–5 | Maximum Y | kernel, observed |
| 6 | Buttons on the tablet | kernel, observed |
| 7 | Controls: 0 buttons, 1 dial, 2 mouse-style | kernel |
| 8–9 | Maximum pressure | kernel, observed |
| 10–11 | Resolution, lines per inch | kernel, observed |

The Xencelabs Pen Display 24 answers string descriptor 100 with 105000 ×
59000, pressure 8191, 3 buttons, and 5080 lines per inch, matching its
known specs. (observed)

## Pen Report

| Field | Huion v2, report `0x08` | UGEE v2, report `0x02` |
| --- | --- | --- |
| Status | 1 | 1 |
| X | 2–3, third byte at 8 | 2–3, third byte at 10 on wide tablets |
| Y | 4–5, third byte at 9 | 4–5 |
| Pressure | 6–7 | 6–7, 13 bits |
| Tilt X, Y | 10, 11 | 8, 9 |

Tilt is a signed byte in degrees, −60 to 60. On Huion v2, tilt Y points the
other way, so negate it. (kernel; Huion observed in recordings)

The third X byte at 10 is from the Pen Display 24, whose X range doesn't fit
in 16 bits. The kernel doesn't read it. (observed)

Status byte bits:

| Bit | Huion v2 | UGEE v2 |
| --- | --- | --- |
| 0 | Tip | Tip |
| 1 | Barrel button | Barrel button |
| 2 | Second barrel button | Second barrel button |
| 3 | — | Third barrel button (observed) |
| 4 | Not pen data; see below | Not pen data; see below |
| 5 | — | In range |
| 6 | In range, but never set | Eraser (observed) |
| 7 | Always set | Set for a three-button pen, clear for a slim pen (observed) |

The kernel ignores UGEE bits 3, 6, and 7. The Pen Display 24 sends
`0xC0` when the pen leaves range. (observed)

**Huion v2 never says the pen left.** It sends no report when the pen
leaves; it simply stops. Treat 100 ms of silence as the pen leaving, as the
kernel does. (kernel, observed in recordings)

These pens have no serial number or tool code, so a driver can't tell one
pen from another of the same kind.

## Tablet Buttons

With bit 4 of the status byte set, a report carries the tablet's own
controls instead of pen data. (kernel, observed)

| Protocol | Status | Buttons | Confidence |
| --- | --- | --- | --- |
| Huion v2 | `0xE0` | Bitmap, lowest bit first, bytes 4–5 | observed (HS610 recording) |
| UGEE v2 | `0xF0` | Bitmap, lowest bit first, bytes 2–3 | kernel, observed |

The Pen Display 24 also sends battery on `0xF2` and echoes commands back as
`0xB0` to `0xBF`. Dials, rings, and touch strips use other status values;
TabletKit doesn't decode them yet. (observed)

## Unverified

- Any Huion v2 tablet switching on under macOS.
- Huion status bit 4 on a pen report, and `0xA0`/`0xA1` reports from Huion
  tablets, neither seen in any recording.
- Huion string descriptor 200 past byte 13.
- `02 B0 02`, above.
- The XP-Pen Artist 22R Pro and 24 Pro, which the kernel handles as a
  special case.
- Dials, rings, touch strips, and the older UC-Logic protocols.

## Tests

- [`UCLogicTabletInfoTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/UCLogicTabletInfoTests.swift)
- [`UCLogicDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/UCLogicDecoderTests.swift)
