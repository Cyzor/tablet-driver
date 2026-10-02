# PTK-870 tilt: range and direction

Supports [Intuos Pro gen 3: Bluetooth LE report `0x1A`](../Wacom-Intuos-Pro-Gen3-Protocol.md#bluetooth-le-report-0x1a).

**Capture:** a PTK-870 over Bluetooth, with the pen held still at a steep
angle in each of four directions. A separate session lays the pen as flat as
it goes, to the left and then to the right.

**What to look for:** byte 11 is tilt X and byte 12 is tilt Y, both signed.
The status in byte 3 is `C0`: in proximity, with tilt valid.

**Direction.** The sign says which way the top of the pen leans: +X to the
right, +Y toward the user. So a tip pointing left reads +X.

```
                       report 0x1A                                       X     Y
tip pointing left      1A 42 80 C0 7A 22 30 5A 04 00 00 3C F8 CD AD 2B 8C EA 00 00   +60    −8
tip pointing right     1A 42 80 C0 A0 E4 F0 78 05 00 00 C4 F9 4A 6D 28 33 9E 00 00   −60    −7
tip pointing away      1A 42 80 C0 7D 7F 20 16 01 00 00 02 39 5E FF 14 2B A7 00 00    +2   +57
tip pointing toward    1A 42 80 C0 D7 7B 70 E9 06 00 00 11 C5 75 D0 14 CA 63 00 00   +17   −59
```

**Range.** Laid flat, the pen reaches −64 on one side and +63 on the other.

```
laid flat, left        1A 42 80 C0 86 7E 50 42 05 00 00 C0 24 42 51 2B 97 3A 00 00   −64
laid flat, right       1A 42 80 C0 74 68 90 F5 04 00 00 3F 3F 00 D0 30 48 69 00 00   +63
```

Values alone only show that a number changed. To confirm a direction, draw
with a flat brush, as described in
[Measurement methods](../Measurement-Methods.md#tilt-direction).
