# Wacom Ring LEDs and ExpressKey OLEDs

Host-to-tablet feature reports that light the touch-ring mode LEDs, and the
Intuos4's per-key OLED displays. All are HID **feature** reports
(SET_REPORT). Confidence labels: **observed** · **kernel** · **unverified**.
"Observed" here means the LEDs responded on real hardware.

## Intuos Pro Gen 2 (PTH-x60)

**USB:** send two reports as a pair on every mode change:

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

- `0x3B`: not declared in the descriptor; the tablet silently ignores writes.
- `0xCC`: declared (usage page `0xFF0D`, usage `0x10CC`), but the Linux
  generic-device layout `[0xCC, brightness, slot, …]` doesn't move the ring.
- Report 35 (usage `0x0055`, 1 byte, on the second interface): no visible
  effect; purpose unknown.

## Intuos5 and Intuos Pro Gen 1

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

## Intuos4 and Earlier

Report `0x20`, 9 bytes:

```
[1] = selected mode 0–3 | 0x04     the 0x04 bit is a required enable bit, not
                                   decoration; without it the ring stays dark
[2] = ring LED luminance (0–127)
[3] = ring LED luminance on contact (0–127)
[4] = OLED brightness | 0x10       low nibble 0–15; 0x10 = OLEDs enabled
[5]–[8] = 0                        never written by the vendor driver
```

This is shared with the Cintiq 24HD/21UX2 branch below, which ORs the second
ring into the high nibble of `[1]`. (kernel)

The LED bytes are a continuous ramp: a lightmeter saw a new level at every
step of `01 03 05 08 0a 10 20 40 80 ff`, the biggest jump near the top, so
mid-range values look alike. The OLED nibble is likewise multi-level.
(observed, PTK-640)

### Idle dimming

Wacom's driver rewrites this report from an idle timer
(`CPTKTabletControls::SendDisplayProperties`). It indexes three tables by a
display brightness level: the user's setting (default 6) while awake, 3 after
300 s without input, and 0 after another 300 s, when the timer stops until
input arrives.

```
kLEDNormalBrightness = [10,10,10,10,10,10,10,32,32,32]    -> [2]
kLEDHighBrightness   = [10,40,40,40,40,40,40,127,127,127] -> [3]
kOLEDBrightness      = [ 0, 5, 5, 5,10,10,10,15,15,15]    -> [4] | 0x10 unless level 0
```

A PTK-640 therefore sends `[2,3,4]` = `10,40,0x1a` awake, `10,40,0x15` dimmed
and `10,10,0x00` off. The PTK-540WL uses its own OLED table
(`[0,7,7,7,12,12,12,15,15,15]`) and, on battery, 60 s / 90 s delays. The
PTK-440 has no key displays and is left out (`HasOLEDS`). `[2]`/`[3]` are the
kernel's `llv`/`hlv`. The firmware switches the ring from `[2]` to `[3]` by
itself while the pen tip is down (the Intuos4 mouse is untested), so once the
displays are off, contact no longer brightens it. (disassembly, observed on
PTK-640)

TabletKit's `Intuos4DisplayProperties` holds these tables. MockTab runs the
cycle for the wired PTK-640/840/1240/540WL and sends the kernel defaults
(10, 20, 10) to every other `.intuosV1` device.

## Cintiq 24HD and 21UX2

Report `0x20`, 9 bytes, driving both rings:

```
[1] = 0x44 | rightSlot | leftSlot << 4
      0x04 right ring on, 0x40 left ring on
      bits 0–1 right ring LED 0–2, bits 4–5 left ring LED 0–2
[2]–[8] = 0
```

The report carries no brightness bytes. On the DTK-2400, the digitizer
interface itself declares this report, and no separate LED device appears
on the bus. (observed, DTK-2400)

## Intuos4 ExpressKey OLEDs

Eight 64 × 32 displays, one beside each key. The host writes images to
them over feature reports (`wacom_led_putimage()` in `wacom_sys.c`):

```
0x21  [0x21, 0x01]                             begin transfer
0x23  [0x23, key & 0x07, chunk 0–3, 256 bytes] four chunks per key (USB)
0x21  [0x21, 0x00]                             end transfer
```

Over USB each image is 1024 bytes of 4-bit grayscale in the kernel's
row-interleaved order. Bluetooth uses a different command and a 1-bit,
bit-scrambled encoding. (kernel)

Wacom's driver (`CPTKUSBGraphicsTablet::SendImageToDisplay`) frames each
key the same way: one start/stop pair per key around four 259-byte `0x23`
reports. MockTab's frames match it byte for byte. (disassembly, observed on
PTK-640)

Intuos5 and Intuos Pro have no key displays.

## Devices the Host Can't Set

The ExpressKey Remote lights its own ring-mode LEDs; the host can only read
which mode is active (see [pen displays](Wacom-Pen-Display-Protocols.md#expresskey-remote-ekr-100)). (observed)

## Tests

These TabletKit tests check the layouts above, many with frames from real captures:

- [`WacomOutputProtocolTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/WacomOutputProtocolTests.swift)
- [`IntuosOLEDImageEncoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosOLEDImageEncoderTests.swift)
- [`Intuos4DisplayPropertiesTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/Intuos4DisplayPropertiesTests.swift)
