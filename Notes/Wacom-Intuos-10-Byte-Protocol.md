# Wacom Intuos 10-Byte Protocol (Intuos 1/2/4/5, Intuos Pro Gen 1)

The 10-byte pen report the Linux driver handles in `wacom_intuos_irq()`. It is
used by the Intuos and Intuos2 (GD/XD), Intuos4 (PTK-x40), Intuos5 (PTH/PTK-x50),
and Intuos Pro gen 1 (PTH-x51), by the 2015–2018 consumer Intuos (CTL/CTH-x90,
CTL-x72), by the Intuos3 (PTZ) with differences noted below, and by the
older Cintiqs. TabletKit decodes it in `IntuosV1Decoder`; device
coverage lives in `TabletKit/registry.json` (`"parser": "intuosV1"`).

Hardware evidence comes from the Intuos5 L (PTH-850), Intuos Pro L (PTH-851),
and a first-generation Intuos 6×8 (GD-0608-U). Mappings for other models
come from the kernel and OpenTabletDriver, which agree.

Confidence labels: **observed** · **kernel** · **unverified**, as in
[the gen 2 page](Wacom-Intuos-Pro-Gen2-Protocol.md). Offsets include the
report ID at `[0]`. Unlike the gen 2 format, multi-byte values here are
**big-endian**.

## Setup

Until the tablet receives feature report `[0x02, 0x02]` (SET_REPORT, report
ID 2), it behaves as a mouse and sends no pen data. Nothing more is needed:
no second step, no delay. (observed)

USB interfaces on the PTH-850: interface 0 carries pen and pad reports along
with a mouse collection that the OS claims by default. Interface 1 (usage
page `0xFF00`) carries finger touch in the [64-byte container](Wacom-Consumer-Tablet-Protocols.md#the-64-byte-container-report-0x02). (observed)

## Reports

| Report | Size | Carries |
| --- | --- | --- |
| `0x02` or `0x10` | 10 | Pen. The ID varies by model; the layout does not |
| `0x03` | 10 | ExpressKeys and touch ring (Intuos5, Intuos Pro gen 1) |
| `0x0C` | 10 | ExpressKeys and touch ring (Intuos4) |
| `0x11` | — | ExpressKeys on some models |
| `0x03`, `0x04` | 22, 32 | PTK-540WL over Bluetooth: 2 or 3 packed frames |
| `0x80` | 32 | ACK-40401 dongle link status; see [wireless](Wacom-Wireless-and-Battery.md) |

## Pen Report: Status Byte `[1]`

Byte 1 decides the packet's kind:

| Test | Packet | Confidence |
| --- | --- | --- |
| `([1] & 0xFC) == 0xC0` | Tool enter: serial and tool ID | observed |
| `([1] & 0xFE) == 0x20` | In range, no position (bytes 6–8 are zero) | observed |
| `([1] & 0xFE) == 0x80` | Exit | observed |
| anything else | Data packet | observed |

In a data packet, bit 5 (`0x20`) is proximity and bit 6 (`0x40`) is high
confidence. Bits 1–4, read as `([1] >> 1) & 0x0F`, give the packet type:

| Type | Packet | Confidence |
| --- | --- | --- |
| `0x00`–`0x03` | Pen. Bits 1 and 2 are also barrel buttons 1 and 2 | observed |
| `0x04` | 4D mouse, first packet | kernel |
| `0x05` | Rotation (Art Pen on Intuos3 and later; 4D mouse) | observed (Art Pen, PTH-850) |
| `0x06` | Mouse (Intuos4-era, KC-100) | kernel |
| `0x08` | 2D mouse or lens cursor | kernel |
| `0x0A` | Airbrush, second packet | kernel |

Leaving range, the status steps `0x60` → `0x40` → `0x20` → `0x00`. Treat
only proximity and confidence both clear as an exit. An Art Pen flips the
confidence bit near the edge of range while still in use. (observed)

**In-range packets carry no position.** Decoding `0x20`/`0x21` as a pen
packet yields tilt just past full scale and hover pinned at 63; a PTH-850 on
the wireless dongle sends long runs of them. The kernel returns before
decoding them. A hand resting at high hover holds this state indefinitely,
so it is not an exit for an ordinary pen. (observed)

`0xA0` (proximity set, confidence clear) is an ordinary hover with real
pressure on the GD-0608-U, not boundary noise. (observed)

## Pen Data Packet (Types `0x00`–`0x03`)

| Offset | Field | Confidence |
| --- | --- | --- |
| 2–3 | X, high 16 bits | observed |
| 4–5 | Y, high 16 bits | observed |
| 6–7 | Pressure, with bit 0 of `[1]` | observed |
| 7–8 | Tilt X and Y | observed |
| 9 | X and Y low bits, hover distance | observed |

```
x        = ([2] << 8 | [3]) << 1 | ([9] >> 1) & 1
y        = ([4] << 8 | [5]) << 1 | [9] & 1
pressure = [6] << 3 | ([7] & 0xC0) >> 5 | [1] & 1     // 11 bits
tiltX    = (([7] << 1) & 0x7E | [8] >> 7) - 64        // ±64
tiltY    = ([8] & 0x7F) - 64
hover    = [9] >> 2                                    // 0–63
```

Devices with 1024 pressure levels (Intuos 1/2) use `pressure >> 1`.
OpenTabletDriver instead keeps the full 11 bits and declares a maximum of
2046; the ratio is the same. (observed, GD-0608-U)

**Coordinate scale.** The extra low bit doubles the resolution. For Intuos
1/2 the kernel discards it (`x >>= 1`, `y >>= 1`, and hover `>>= 1` to a
maximum of 31) and declares 20320 × 16240 for the GD-0608-U. TabletKit and
OpenTabletDriver keep the bit, which makes the range 40640 × 32480 (203.2 ×
162.4 mm at 100 lines/mm, doubled). Pairing kept bits with the kernel's
maxima maps only the top-left quarter of the tablet. Intuos3 and later keep
the bit in the kernel too. (observed + kernel)

## Tool Enter Packet

```
serial  = ([3] & 0x0F) << 28 | [4] << 20 | [5] << 12 | [6] << 4 | [7] >> 4
tool ID = [2] << 4 | [3] >> 4 | ([7] & 0x0F) << 16 | ([8] & 0xF0) << 8   // kernel
```

The two ends of one GD-series Grip Pen share a serial and differ only in the
high nibble of byte 3 (`0x29` tip, `0xA9` eraser); bit 3 of the tool ID marks
the eraser. (observed)

TabletKit packs the same nibbles into 16 bits differently from the kernel:
`([7] & 0x0F) << 12` and `([8] & 0xF0) << 4`. The two agree only when the
high nibble of `[8]` is zero, as it is in every capture so far.

## Other Packets

**Mouse, type `0x06`.** `[6]` buttons: `0x01` left, `0x02` middle, `0x04`
right, `0x08`/`0x10` side. Wheel: `([7] & 0x80) >> 7` minus
`([7] & 0x40) >> 6`. (kernel)

**Mouse, type `0x08`.** `[8]`: wheel as bit 0 minus bit 1; buttons `0x04`
left, `0x08` middle, `0x10` right. Lens cursors use a different button map.
(kernel)

**Airbrush, type `0x0A`.** Wheel `[6] << 2 | ([7] >> 6) & 3`; tilt as in the
pen packet. It arrives between pen packets and has no pressure, so don't read it
as a tip release. (kernel)

**Rotation, type `0x05`.** 11-bit value `t = [6] << 3 | ([7] >> 5) & 7`, with
`[7] & 0x20` selecting the half-turn. The kernel maps it to −900…899 for one
turn: `450 − t/2` with the bit clear; with it set, `(t − 1)/2 + 450`, or
`(t − 1)/2 − 1350` above 900.

An Art Pen sends one rotation packet after every pen packet, with status
`0xEA` in contact and `0xAA` in hover. Bit 1 of that status is part of the
type, not a barrel button, and bytes 6–7 hold the angle, not pressure. A
decoder that reads it as a pen packet presses button 1 and jumps pressure on
every other report. (observed, PTH-850 with an Intuos4/5 Art Pen)

## ExpressKeys and Touch Ring

**Intuos5 and Intuos Pro gen 1, report `0x03`.** The same layout arrives over
USB and through the ACK-40401 dongle. (observed, PTH-850)

| Offset | Field |
| --- | --- |
| 1 | Constant `0x80` |
| 2 | Touch ring: bit 7 active, bits 0–6 position 0–71 |
| 3 | Ring center button, 0 or 1 |
| 4 | Keys 1–8, one bit each |
| 5 | Copy of `[4]` |

**Intuos4, report `0x0C`.** `[1]` ring (bit 7 valid, position 0–71), `[2]`
bit 0 ring center button, `[3]` keys. (kernel, matches OpenTabletDriver)

## Intuos4 Wireless over Bluetooth (PTK-540WL)

Bluetooth Classic packs ordinary 10-byte frames together with a trailing
power byte:

| Report | Layout |
| --- | --- |
| `0x03` (22 bytes) | `[1–10]`, `[11–20]` frames, `[21]` power |
| `0x04` (32 bytes) | `[1–10]`, `[11–20]`, `[21–30]` frames, `[31]` power |

Each frame decodes as over USB: pen frames as above, pad frames as `0x0C`.
Power byte: bits 0–2 index the battery table `1, 15, 30, 45, 60, 70, 85, 100`
percent; bit 3 charging; bit 4 external power. Check the minimum lengths:
the kernel once read past short reports here (GHSA-4mjh-m2x6-5qg4). (kernel)

## Intuos3 (PTZ-x30, PTZ-x31)

Same pen packet, tool enter packet, and status tests. TabletKit decodes it
separately (`Intuos3Decoder`) because it reads proximity from bit 6 (`0x40`),
with no separate confidence bit, and because the pad differs:

- Report `0x0C`: on the 6×11 (PTZ-631W) and 12×19 wide models, `[1]–[2]`
  and `[3]–[4]` are the two touch strips, 13 bits each
  (`([1] & 0x1F) << 8 | [2]`), with one bit set for the finger's zone and
  0 for no finger. Other models carry four keys in the low nibbles of
  `[5]` and `[6]`.
- Report `0x03`: eight keys in `[4]`.

Kernel only (`wacom_intuos_pad()`); no capture exists.

## Unverified

- 4D mouse, lens cursor, and airbrush: no hardware on hand.
- Intuos4 and CTL/CTH-x90 rows: mapped from the kernel, no captures.

## Tests

These TabletKit tests check the layouts above, many with frames from real captures:

- [`IntuosV1DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV1DecoderTests.swift)
- [`IntuosV1Decoder+ExtendedTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV1Decoder+ExtendedTests.swift)
- [`Intuos3DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/Intuos3DecoderTests.swift)
