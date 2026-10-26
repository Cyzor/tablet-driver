# PTK-870 Key Order: Around Each Cluster

Supports [Intuos Pro gen 3: USB ExpressKey report `0x11`](../Wacom-Intuos-Pro-Gen3-Protocol.md#usb-expresskey-report-0x11)
and [Bluetooth LE report `0x1A`](../Wacom-Intuos-Pro-Gen3-Protocol.md#bluetooth-le-report-0x1a).

**Capture:** the ten keys on the top edge of a PTK-870, pressed one at a
time, once over USB and once over Bluetooth LE, with the tablet in landscape
for a right-handed user. `tools/hardware-check/key-order.sh` named each key by
its place in libwacom's layout and recorded the report it sent.

**What to look for:** each cluster's four outer keys take one bit each, in
the order top, right, bottom, left: bits 0–3 for the left cluster and 4–7 for
the right. Over USB they're byte 1 of report `0x11`; over Bluetooth, byte 18
of report `0x1A`. Each cluster's center key has its own bit: byte 3 over USB
and byte 19 over Bluetooth, bit 0 left and bit 1 right. libwacom's letters
follow the same order, A–D and E–H, with I and J at the centers.

```
 key                     letter   USB 0x11 [1] [3]   Bluetooth 0x1A [18] [19]
 left cluster, top         A          01   00              01   00
 left cluster, right       B          02   00              02   00
 left cluster, bottom      C          04   00              04   00
 left cluster, left        D          08   00              08   00
 left cluster, center      I          00   01              00   01
 right cluster, top        E          10   00              10   00
 right cluster, right      F          20   00              20   00
 right cluster, bottom     G          40   00              40   00
 right cluster, left       H          80   00              80   00
 right cluster, center     J          00   02              00   02
```

A full Bluetooth report, the left cluster's top key:

```
1a 02 00 00 00 00 00 00 00 00 00 00 00 00 c0 00 00 00 01 00
```

Byte 14's high nibble is the frame counter, so it differs from report to
report.
