# Wacom ring LEDs and ExpressKey OLEDs

Host-to-tablet feature reports that light the touch-ring mode LEDs, and the
Intuos4's per-key OLED displays. All are HID **feature** reports
(SET_REPORT). Confidence labels: **observed** · **kernel** · **unverified**.
"Observed" here means seen in the traffic Wacom's own driver sends, or
confirmed by the LEDs responding on our hardware.

## Intuos Pro gen 2 (PTH-x60)

**USB:** two reports, sent as a pair on every mode change:

```
0x31  [0x31, 0x46, 0x46, 0x46, 0x46, 0x46]   brightness, all channels (0x46 = 70)
0x32  [0x32, 0x46, slot]                     select LED 0–3
```

LED numbering on the wire runs bottom-left, top-left, top-right,
bottom-right. (observed, PTH-660 and PTH-860)

**Bluetooth:** report `0x82`, 51 bytes:

| Offset | Value |
| --- | --- |
| 0 | `0x82` |
| 1 | `0x02` (fixed; `0x00` doesn't work) |
| 4–9 | `0x46`, brightness for six channels |
| 10 | LED 0–3 |
| 11– | `0x00` |

Reading the report back returns the current state in the same layout, with
the tablet's serial at `[11]`–`[18]`; clear those bytes before writing.
(observed, PTH-660)

**Ruled out on USB** (tested on a live PTH-660/860):

- `0x3B`: not declared in the descriptor; writes are silently ignored.
- `0xCC`: declared (usage page `0xFF0D`, usage `0x10CC`), but the Linux
  generic-device layout `[0xCC, brightness, slot, …]` doesn't move the ring.
- Report 35 (usage `0x0055`, 1 byte, on the second interface): no visible
  effect; purpose unknown.

## Intuos5 and Intuos Pro gen 1

**Wired:** report `0x20`, 9 bytes, with everything packed into `[1]`:

```
[1] = cropLum << 4 | ringLum << 2 | slot
      slot     bits 0–1  LED 0–3
      ringLum  bits 2–3  0 low, 1 medium, 2 high, 3 off
      cropLum  bits 4–5  the lit corner marks framing the active area, same scale
[2]–[8] = 0
```

Sending the Intuos4 layout below to these tablets leaves the ring on LED 0
and makes mode changes toggle the corner marks instead. (observed, PTH-850)

**Through the ACK-40401 dongle:** report `0x03`, 13 bytes, with the same
packed value at `[4]`. (kernel)

## Intuos4 and earlier

Report `0x20`, 9 bytes: `[1]` = luminance (bits 0–4) | LED (bits 5–7);
`[2]` = high luminance (bits 0–4). (kernel)

## Cintiq 24HD and 21UX2

Report `0x20`, 9 bytes, driving both rings:

```
[1] = 0x44 | rightSlot | leftSlot << 4
      0x04 right ring on, 0x40 left ring on
      bits 0–1 right ring LED 0–2, bits 4–5 left ring LED 0–2
[2]–[8] = 0
```

Wacom's driver sends no brightness bytes. On the DTK-2400 this report is
declared on the digitizer interface itself, with no separate LED device on
the bus. (observed, DTK-2400)

## Intuos4 ExpressKey OLEDs

Eight 64 × 32 displays, one beside each key, written as images over feature
reports (`wacom_led_putimage()` in `wacom_sys.c`):

```
0x21  [0x21, 0x01]                         begin transfer
0x23  [0x23, key & 0x07, chunk, 256 bytes] four chunks per key (USB)
0x21  [0x21, 0x00]                         end transfer
```

Over USB each image is 1024 bytes of 4-bit grayscale in the kernel's
row-interleaved order. Bluetooth uses a different command and a 1-bit,
bit-scrambled encoding. (kernel; no Intuos4 on hand)

Intuos5 and Intuos Pro have no key displays.

## Devices the host can't set

The ExpressKey Remote lights its own ring-mode LEDs; the host can only read
which mode is active (see [pen displays](Wacom-Pen-Display-Protocols.md#expresskey-remote-ekr-100)). (observed)

## Tests

These TabletKit tests check the layouts above, many with frames from real captures:

- [`WacomOutputProtocolTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/WacomOutputProtocolTests.swift)
- [`IntuosOLEDImageEncoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosOLEDImageEncoderTests.swift)
