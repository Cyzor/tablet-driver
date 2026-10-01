# Wacom consumer tablet protocols (Graphire, Bamboo, Intuos 2013–2018)

Wacom's consumer line changed pen formats several times while keeping a
shared 64-byte container for touch and ExpressKeys. This page covers the
formats used by these tablets; the 2015–2018 generation's pen report is the
[Intuos 10-byte format](Wacom-Intuos-10-Byte-Protocol.md). TabletKit decodes
them in `GraphireDecoder`, `BambooDecoder` and `BPT3ContainerDecoder`.

Confidence labels: **observed** · **kernel** · **unverified**, as in
[the gen 2 page](Wacom-Intuos-Pro-Gen2-Protocol.md). Offsets include the
report ID at `[0]`.

## Which format each generation uses

| Generation | Models | Pen report | Touch and keys |
| --- | --- | --- | --- |
| Graphire, Volito, Bamboo Fun (2000s) | CTE-, MTE-, CTF- | `0x02`, 8 bytes, little-endian | in the pen report |
| Bamboo (2009–2011) | CTL-460/470/660, CTH-460/461/470 | `0x02`, 9 bytes, little-endian | 20-byte touch report (CTH) or 64-byte container |
| Intuos (2013) | CTL/CTH-480/680 | `0x02`, 10 bytes, little-endian | 64-byte container |
| Intuos (2015–2018) | CTL/CTH-490/690, CTL-472/672 | `0x10`, 10 bytes, **big-endian** | 64-byte container |
| Intuos (2018) | CTL-4100/6100 | 192-byte gen 2 format | — |

**Setup.** The Bamboo and Intuos generations start as a relative mouse
sending 4-byte packets on report `0x01`. Feature report `[0x02, 0x02]`
switches them to the formats below. (observed, CTL-460)

## Graphire and Bamboo Fun: report `0x02`, 8 bytes

| Offset | Field |
| --- | --- |
| 1 | Status: `0x80` proximity; `0x60` tool (0 pen, 1 eraser, 2 mouse with wheel, 3 mouse); `0x04`/`0x02` barrel buttons (mouse middle/right); `0x01` tip (mouse left) |
| 2–3 | X |
| 4–5 | Y |
| 6–7 | Pressure, 10 bits: `[6] \| ([7] & 0x03) << 8` |
| 7 | Hover distance `[7] & 0x3F`; pad bits on some models |
| 8 | Touch ring (Bamboo Fun) |

Bamboo Fun (CTE-450/650, MTE-450) pad: `[7]` `0x08` back, `0x10`
forward, `0x20`/`0x40` the lower function keys; `[8]` bit 7 finger on the
ring, bits 0–6 position 0–71. The pad is sent whether or not the pen is in
range. Graphire 4: `[7]` bits 6 and 7 are its two buttons, bits 3–5 a
relative wheel.

The pen path and the Bamboo Fun pad bits are observed on a CTE-650. Which
pad bit belongs to which key, and everything for other models, is kernel.

## Bamboo: report `0x02`, 9 bytes

| Offset | Field |
| --- | --- |
| 1 | Status: `0x20` proximity, `0x08` eraser, `0x04`/`0x02` barrel buttons, `0x01` tip |
| 2–3 | X |
| 4–5 | Y |
| 6–7 | Pressure |
| 8 | Hover distance |

Observed on a CTL-460 (PID `0x00D4`, labeled CTL-460/K) across hover,
contact, both buttons, the eraser and exit. Bit `0x10` also toggles; its
meaning is unknown. The CTL-460 has no ExpressKeys. Its descriptor declares
480 × 320, which is not the pen's coordinate range.

## Intuos (2013): report `0x02`, 10 bytes

The same fields as the 9-byte Bamboo report, one byte longer. Read as
big-endian, coordinates come out near 130,600 on every model; read as
little-endian, they reach each model's maximum exactly. (observed, CTH-480
family)

## The 64-byte container (report `0x02`)

Shared unchanged by the 2013 and 2015–2018 Intuos and some Bamboos, and
also used by the Intuos5 and Intuos Pro gen 1 for touch on their second USB
interface. On the 2013 models the pen report has the same ID, so tell them
apart by length. (observed, CTH-690 and CTH-480 family)

`[1]` bits 0–2 give a message count; up to seven 8-byte messages follow
from `[2]`. Messages carry only what changed, so keep contacts between
reports.

| Message ID `[0]` | Contents |
| --- | --- |
| 2–17 | Finger: `[1]` bit 7 down; X `[2] << 4 \| [4] >> 4`; Y `[3] << 4 \| [4] & 0x0F` (12 bits each); `[5]` width, `[6]` height |
| `0x80` | ExpressKeys: `[1]` bits 0–3, one per key |
| `0x81` | Lift mask: `[3]–[4]` are a 16-bit mask of the fingers still down |

Ignore the `0x81` mask and a lifted finger can stay down for the rest of
the session. Which key sets which pad bit has not been mapped.

**Don't drop touch while the pen is in range.** The kernel does, but a pen
resting in low-confidence hover (half the hover reports from a PTH-850 Grip
Pen) then kills touch for as long as a hand is near the tablet. Arbitrate
using sustained pen activity rather than raw proximity. (observed)

## Bamboo touch: report `0x02`, 20 bytes (CTH-460/461)

A separate USB interface with two fixed finger slots, big-endian 11-bit
coordinates in a 480 × 320 space, and the four ExpressKeys in `[1]`
(bits 3, 2, 1, 0). `[1]` bit 7 selects an 8- or 9-byte stride between slots.
(kernel)

## Unverified

- Graphire, Volito and Graphire 4 beyond the CTE-650: kernel only.
- 20-byte Bamboo touch report: no capture.
- ExpressKey order in the 64-byte container.
