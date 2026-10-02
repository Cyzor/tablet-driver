# Xencelabs protocol (Pen Tablet, Pen Display, Quick Keys)

Xencelabs hardware uses vendor ID `0x28BD`, which is UGEE's; the devices
identify as "HANVON UGEE". TabletKit decodes them in `XencelabsDecoder` and
builds the host-to-device writes in `XencelabsOutputProtocol`.

| Device | PID |
| --- | --- |
| Pen Tablet Medium | `0x5201` |
| Pen Tablet Small | `0x5204` |
| Quick Keys | `0x5202` |
| Wireless dongle | `0x5203` |
| Pen Display 16 | `0x520B` |
| Pen Display 24 | `0x520D` |

Everything below was observed on a Pen Display 24 and a Quick Keys, wired
and through the dongle, unless marked otherwise.

## The vendor tunnel, report `0x02`

All live data in both directions uses report `0x02` on a vendor collection
(usage page `0xFF0A`): input reports from the device and **output** reports
from the host. The descriptor also declares a standard digitizer collection
on report `0x07`, but it never carries data. Report sizes differ by device:
the wired Quick Keys sends 10 bytes, the dongle and Pen Display 32. Pad
host writes to the device's maximum output report size.

**Setup:** output report `[0x02, 0xB0, 0x04]`, zero-padded. Until then the
device acts as a mouse.

## Input: byte `[1]` decides the frame

| `[1]` | Frame |
| --- | --- |
| `0xC0` | Pen out of range |
| top nibble `0x2_`, `0xA_` | Pen; bits below |
| `0xF0` exactly | Quick Keys keys and dial |
| `0xF2` with `[2]` = `0x01` | Battery reply: `[3]` percent |
| `0xF2`, `0xF8` otherwise | Dongle status around connection; not input |
| top nibble `0xB_` | Echo of a host write (`0xB0`, `0xB4`, `0xB5`, `0xB8`); not input |

Reading echoes or status frames as key frames produces phantom key presses
that never release.

**Pen bits:** `0x01` tip, `0x02`/`0x04`/`0x08` barrel buttons 1–3 (the
3 Button Pen uses all three, the Thin Pen 2 and 3), `0x40` eraser end in
range, `0x80` set for the 3 Button Pen and clear for the Thin Pen (`0xA0`
vs. `0x20` hovering).

## Pen frame

| Offset | Field |
| --- | --- |
| 2–3, 10 | X, 24-bit: `[2] \| [3] << 8 \| [10] << 16` |
| 4–5, 11 | Y, 24-bit, same pattern |
| 6–7 | Pressure, 0–8191 (observed peak about 6400) |
| 8 | Tilt X, signed, 1° per count, ±60 at the pen's mechanical stop |
| 9 | Tilt Y, same |

The Pen Display 24's X range is 0–105000 (about 200 units/mm), so reading
only `[2]`–`[3]` wraps mid-screen. Tilt follows the HID convention: +X
right, +Y toward the user. Neither pen sends a serial or tool code,
but bit `0x80` tells them apart: a capture with both pens in one session
shows it tracking the pen and nothing else. The out-of-range tag `0xC0`
has the bit set for both pens, so keep the last pen through it.

## Quick Keys frame (`[1]` = `0xF0`)

| Offset | Field |
| --- | --- |
| 2 | Keys 1–8, key N at bit N−1 |
| 3 | Bit 0 mode button, bit 1 dial center click |
| 7 | Dial step: 1 counterclockwise, 2 clockwise |

Key numbering follows Xencelabs': hold the puck in landscape with the dial
on the right; keys 1–4 are the top row and 5–8 the bottom row, left to
right. Confirmed with single-key presses (key 1 alone gives `0x01`, key 8
alone `0x80`); a sweep can't distinguish the two orders.

## Host writes

Output reports on `0x02`. Bytes 10–15 carry a 6-byte device address. Through
the dongle, which serves up to two paired devices, the address is required:
an all-zero address has no effect. Over USB it's optional.

| Write | Frame |
| --- | --- |
| Quick Keys label text | `02 B1 <field> <index LE16> <chunk bytes> <chunks left> 00 00 00 <addr> <UTF-16LE, 16 bytes>` |
| Quick Keys text rotation | `02 B1 <steps + 1> 00 … <addr>`; 0–3 quarter turns |
| Quick Keys OLED brightness | `02 B1 0A 01 <0 off … 3 bright> … <addr>` |
| Dial LED color | `02 B4 01 01 00 00 R G B 00 <addr>` |
| Dial sensitivity | `02 B4 04 01 01 <1–5> … <addr>`; default 3 |
| Quick Keys sleep timer | `02 B4 08 01 <minutes, 0 = never> … <addr>`; survives power cycles |
| Pen Display brightness | `02 B5 01 03 00 00 <0–100> 00` |

Label text over 8 UTF-16 code units is split into 8-unit chunks, with the
chunk count counting down to 0; an empty string clears the field. In the
sleep-timer and OLED-brightness frames, byte 3 = `0x01` sets the value and
`0x00` reads it back.

The Pen Display's bezel-button backlight answers to the dial LED color
frame. The vendor driver pre-scales brightness into the RGB values, and its
palette is calibrated to the LEDs (its "white" is warm, not `FFFFFF`).

## Unverified

- Pen Tablet Small and Medium, and the Pen Display 16: same family, not on
  hand.
- Other Pen Display panel controls in the `0xB5` family.
