2026-03-27

## DTK-2400 (Cintiq 24HD) — Protocol Decoder Brief

**Context:** MockTab has partial input working on this device but with severe behavioral problems. The decoder was almost certainly written against the PTH-660's newer 27-byte `0x10` protocol. The DTK-2400 uses an older 10-byte `0x02` report format. Six labeled capture sessions confirm the full layout. The device works flawlessly under Wacom's native driver; all problems described below are decoder defects, not hardware defects.

***

### Report Format

All motion reports are Report ID `0x02`, 10 bytes. The report ID byte **is present** in the callback buffer — byte is always `0x02`.

```
[0]  = 0x02  (report ID, present in buffer)
 [github](https://github.com/libusb/hidapi/issues/239)  = status byte  — decode as follows:
         0xC2 = tool announcement (pen enters proximity)
         0x80 = tool leaves proximity
         0xE0 = in proximity, hovering — no contact
         0xE1 = tip pressed              (bit 0 set)
         0xE2 = barrel button 1          (bit 1 set)
         0xE3 = tip + barrel button 1    (bits 0+1)
         0xE4 = barrel button 2          (bit 2 set)
[2:4] = X, big-endian 16-bit unsigned
[4:6] = Y, big-endian 16-bit unsigned
[6]   = PRESSURE, 8-bit unsigned (0x00–0xFF)
[7]   = pen elevation/altitude angle — NOT pressure, NOT tilt X
[8]   = tilt X — bit 7 is a sync-parity toggle and MUST be masked:
         actual tilt X = byte[8] & 0x7F
[9]   = tilt Y, 8-bit unsigned
```

***

### Known Defects to Fix

#### 1. Pressure byte is wrong

The decoder is almost certainly reading `byte[7]` as pressure. **Do not do this.**

- `byte[7]` is pen elevation/altitude. Its hover baseline is ~36–41 and it **never reads zero**, even when the pen is far from the surface. Reading it as pressure means every hover registers as a light press. This explains the "heavy and leaky" pressure behavior — the system is always seeing fake pressure.
- `byte[6]` is the correct pressure field. It is definitively `0x00` when the pen is hovering at normal distance. It increases as the pen approaches and presses.

#### 2. Pressure gate and the tap-click problem

`byte[6]` begins rising while `byte [github](https://github.com/libusb/hidapi/issues/239)` is still `0xE0` — i.e., the pressure sensor activates **before** the tip-contact bit fires. This is Wacom's proximity-force ramp, and it is real data. However, if the decoder gates any click/event output on `byte [github](https://github.com/libusb/hidapi/issues/239) == 0xE1` only, a light tap may never transition to `E1` before the pen lifts, because the pressure peaked and dropped entirely within `E0` territory.

This is the root cause of the click behavior: a normal tap registers as `E0` with rising-then-falling `byte[6]`, never triggering `E1`. The decoder needs to treat a soft tap (pressure above threshold in `E0`) as a click, not require `E1`. Wacom's own driver does this. The `barrel-button + tip` workaround the user found works because holding the barrel button first guarantees `E2`/`E3` transitions regardless of pressure level.

**Fix:** Accept a click/tap event when `byte [github](https://github.com/libusb/hidapi/issues/239) == 0xE0` AND `byte[6]` exceeds a threshold (suggest 30–50 out of 255) for at least 2 consecutive reports, OR when `byte [github](https://github.com/libusb/hidapi/issues/239) == 0xE1`. Do not require `E1` exclusively.

#### 3. Tilt X jitter

`byte[8]` bit 7 is a hardware sync-parity toggle that alternates independently of actual pen movement — the pen can be physically motionless and bit 7 of `byte[8]` still flips every 1–2 reports. If the decoder uses the raw byte value as tilt X, tilt oscillates ±128 units per frame producing violent jitter in any tilt-sensitive application.

**Fix:** `tiltX = byte[8] & 0x7F`. Apply unconditionally to every motion report.

#### 4. Eraser is never detected

The pen/eraser distinction is encoded **only** in the `0xC2` announcement report, not in any motion report. Motion reports are byte-for-byte identical between pen and eraser.

Announcement report byte encodes tool type: [github](https://github.com/libusb/hidapi/issues/239)
- `0x22` = pen
- `0xA2` = eraser (bit 7 set)

Bytes [4:8] of the announcement report = tool serial number (`0x1801D4E1` in these captures).

**Fix:** On receiving `byte [github](https://github.com/libusb/hidapi/issues/239) == 0xC2`, cache `byte [ontrak](https://www.ontrak.net/xcode.htm) & 0x80` as the current tool type. Apply that cached tool type to all subsequent `0xE0`/`0xE1` motion reports until the next `0xC2` is received. Without this, eraser is always decoded as pen.

#### 5. Coordinate normalization

The Cintiq 24HD has a documented native coordinate range (per Linux kernel `wacom_wac.c` for product ID `0x00C5`) of:
- X max: **52,920**
- Y max: **33,530**

If the decoder normalizes against the PTH-660's coordinate range or any other device's values, pen position will map to the wrong screen region. The capture data shows the pen was used in a small central area (X: 34,611–38,511; Y: 11,834–18,646) — consistent with the center of a large tablet surface — confirming the 16-bit big-endian decode is correct but scale must match the DTK-2400 spec.

***

### What the Captures Did Not Show

None of the six capture sessions contain what a successful normal tap looks like. All sessions demonstrate the malfunctioning behavior (pressure-heavy hover, pressure ramp without E1 transition, tilt jitter). Do not use these logs to calibrate thresholds — use them only to confirm the byte layout. A new capture session should be recorded **after** the pressure byte fix (byte instead of byte) is applied, with a deliberate light tap at normal stylus angle, to verify the E0→pressure-ramp→click behavior and determine the appropriate pressure threshold. [blog.adafruit](https://blog.adafruit.com/2021/10/08/get-usb-hid-report-descriptors-via-mac-win-software-usb-todbot/)