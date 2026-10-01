# Wacom Intuos Pro gen 3 protocol (PTK-x70)

The Intuos Pro released in 2025: PTK-470, PTK-670 and PTK-870 (USB PIDs
`0x03F5`, `0x03F7`, `0x03F9`), over USB and Bluetooth LE. The Movink 13
(DTH-135) shares the USB pen report. TabletKit decodes it in
`IntuosV3Decoder`. The Linux driver we checked (input-wacom 4.18) has no
entry for these tablets, so almost everything here comes from PTK-870
captures.

The PTK-870's surface is 69800 × 39000 units at 200 units/mm, with pressure
0–8191 and tilt ±64°.

Confidence labels: **observed** · **kernel** · **unverified**, as in
[the gen 2 page](Wacom-Intuos-Pro-Gen2-Protocol.md). Multi-byte values are
little-endian; offsets include the report ID at `[0]`.

## Setup

Both transports need feature report `[0x02, 0x02]`. Until they get it, they
send only an idle report `0x06`.

Over USB the tablet exposes a vendor interface (usage page `0xFFD1`, 1-byte
reports) that enumerates **before** the pen interface (usage page `0x01`,
usage `0x80`, 192-byte reports). The vendor interface declares feature
reports but rejects this one; the write fails with `0xE0005000` (endpoint
not found) and the tablet never leaves idle. Send it to the interface that
declares feature report `0x02`. (observed)

## Reports

| Report | Transport | Carries | Confidence |
| --- | --- | --- | --- |
| `0x1E` | USB | Pen, 24-bit coordinates | observed |
| `0x11` | USB | ExpressKeys and dials | observed |
| `0x1A` | Bluetooth LE | Pen, keys and dials on one interface | observed |
| `0x1B` | Bluetooth LE | Battery, once per second | observed |
| `0x06` | both | Idle, before setup | observed |
| `0x1F` | USB | Pen, 16-bit coordinates | unverified |

## USB pen report `0x1E`

| Offset | Field |
| --- | --- |
| 2 | Status |
| 3–5 | X, 24-bit |
| 6–8 | Y, 24-bit |
| 9–10 | Pressure |
| 11–12 | Tilt X, signed 16-bit, ±64 |
| 13–14 | Tilt Y, signed 16-bit, ±64 |
| 15–16 | Rotation, signed 16-bit, −900…899 (1800 counts per turn) |
| 19 | Hover distance; 255 = at or past the sensing limit |
| 20–23 | Tool serial; 0 out of proximity |
| 24–25 | Tool code; 0 out of proximity |

All observed. Serial and tool code were checked against an Art Pen of known
identity (tool code `0x0804`). Byte 26 is the top byte of a 32-bit tool-code
field and carries something else.

Status bits: `0x80` proximity, `0x20` eraser, `0x08`/`0x04`/`0x02` barrel
buttons 3/2/1 (all three pressed in a Movink 13 capture), `0x01` tracks the
tip. `0x40` is set on every frame with measured tilt and hover. TabletKit
reads it as the tip switch; Wacom's Cintiq Pro 2022 layout calls the same
bit "range". Which reading is right is open.

**Stub frames.** The tablet interleaves position-only frames among full
ones. Stubs have status `0x80`, tilt and rotation zero, and hover 255; full
frames are `0xC0` or higher. In one capture the split was exact across 178
frames. Hold tilt and rotation through stubs rather than reading the zeros.

**Rotation filler.** A raw rotation of exactly 0 means "no reading this
frame", not an angle. It appears in under 1% of Art Pen frames, and in
nearly all frames for pens without a rotation sensor. Replay the last real
value.

## USB ExpressKey report `0x11`

| Offset | Field |
| --- | --- |
| 1 | Keys 1–8, one bit each |
| 3 | Center keys: bit 0 left cluster, bit 1 right cluster |
| 4 | Left dial, signed 7-bit step count (bits 0–6) |
| 5 | Right dial, signed 7-bit step count |

Observed, and backed by the tablet's HID descriptor. One full turn of
either dial is 24 steps; the dials' raised ridges are grip texture, not
detents. The dials only turn: they have no push switch, and the center key
between each cluster is an ordinary key.

## Bluetooth LE report `0x1A`

One HID interface carries everything. The pen layout is the gen 2 Bluetooth
frame with both coordinates widened to 20 bits and packed, which pushes every
later field along by a byte.

| Offset | Field |
| --- | --- |
| 1 | Packet class (low nibble) and a rolling counter (high nibble) |
| 3 | Status |
| 4–6 | X, 20 bits: `[4] \| [5] << 8 \| ([6] & 0x0F) << 16` |
| 6–8 | Y, 20 bits: `[6] >> 4 \| [7] << 4 \| [8] << 12` |
| 9–10 | Pressure, 0–8191 |
| 11 | Tilt X, signed byte, ±64 |
| 12 | Tilt Y, signed byte, ±64 |
| 13–14 | Rotation, signed 12 bits: `[13]` and the low nibble of `[14]`; same −900…899 scale as USB |
| 14 (high nibble) | Frame counter; mask it off rotation |
| 15 | Hover distance: 20 in contact, rising with height, 255 out of range |
| 16–17 | Changes every frame; timing or sequence data |
| 18 | ExpressKeys: bits 0–3 left cluster, 4–7 right cluster |
| 19 | Dial flags, below |

All observed. X really is 20 bits: read as 16, it wraps at 65536 (the
rightmost 21 mm of a PTK-870) and the cursor jumps to the far edge. Pressure
needs both bytes: `[10]` alone, which peaks at 31, reads every stroke at
1/256 of its force.

**Status `[3]`:** `0x80` proximity, `0x40` close tip fix (tilt and pressure
valid), `0x20` eraser end in range, `0x10` eraser pressed, `0x04`/`0x02`
barrel buttons, `0x01` tip. Treat either eraser bit as the eraser. `0x00` is
the exit frame: leaving runs `0x80` → `0xC0` → `0x80` → `0x00`, one exit
frame per withdrawal. (observed; `0x02` and the eraser bits also match the
kernel's gen 2 and Pro 2022 layouts)

**Packet class**, from the low nibble of `[1]`:

- Class 1 carries identity, not a position: serial at `[4–7]`, tool code at
  `[8–9]`, byte for byte the same as USB `[20–25]`. Decoding it as a
  position yields a fixed phantom point with the tip down. Six different
  class-1 patterns turned up, one per pen, so match on the class, not the
  bytes.
- Class 1 is sent once on approach and is often missed: a session that
  starts with the pen already in range may never see one. Nothing else
  identifies the pen.

**Dial flags `[19]`:** bit 0 left cluster active, bit 1 right cluster active,
bit 2 left dial step, bit 3 left dial counterclockwise, bit 4 right dial
step, bit 5 right dial counterclockwise. One frame per detent, so each
flagged frame is exactly one step.

## Bluetooth LE battery `0x1B`

`[1]`: bit 7 charging, bits 0–6 percent. The rest of the 20 bytes is zero.
Charging readings of `0xCC` and `0xE4` (76% and 100%) settle the bit split.
(observed)

## Edge behavior

These tablets keep reporting after the tip leaves the drawable area. Both
transports do it, so it is the digitizer, not the link. (observed, PTK-870)

- **Groove fold-back.** A pen in the moulded groove past an edge is reported
  about 800–850 units *inside* the edge, so no inset or clamp can catch it.
  The tablet does flag it: the close-tip-fix bit is set on 99.8% of samples
  along the real border and on 0–4% in the groove. Combine that bit, or a
  railed hover reading, with a band near the edge; high hover mid-tablet
  also clears the bit and also reads 255.
- **Barrel takeover.** Past the edge the position starts coming from the
  pen's barrel, so the cursor leaps inward along the tilt direction. Real
  re-entries move at most 254 units per frame and barrel leaps at least
  2648, so a continuity check separates them. A one-frame proximity exit
  often comes between them, so don't reset the check on exit. It reduces the
  leaps but doesn't remove them all.

## Unverified

- **USB report `0x1F`** (16-bit coordinates): layout from OpenTabletDriver
  only; no capture contains it.
- **Bluetooth barrel button 1**: never pressed in a capture.
- **Bluetooth byte `[2]`** loosely tracks the status; meaning unknown.
- **USB status bit 6**: tip switch or range; see above.
