# PTK-870 edge and groove

Supports [Intuos Pro gen 3: edge behavior](../Wacom-Intuos-Pro-Gen3-Protocol.md#edge-behavior).

**Capture:** a PTK-870 over Bluetooth, in two sweeps from top to
bottom. In the first, the pen ran along the right edge of the drawing area.
In the second, it ran along the molded groove just past that edge.

**What to look for:** X is 20 bits, `[4] | [5] << 8 | ([6] & 0x0F) << 16`.
Byte 3 is the status, where `0x40` is the close-tip-fix bit. Byte 15 is hover
distance, with 255 meaning out of range.

**Along the edge,** X sits at 69800, the surface's specified maximum, and the
close-tip-fix bit is set.

```
 report 0x1A                                                    status     X   hover
 1A 02 20 C0 A8 10 61 4D 04 00 00 25 05 00 50 3A 88 08 20 00     C0    69800    58
 1A 02 20 C0 A8 10 51 4E 04 00 00 25 05 00 60 3A A9 08 20 00     C0    69800    58
 1A 02 20 C0 A8 10 31 4F 04 00 00 25 05 00 70 3A CA 08 20 00     C0    69800    58
 1A 02 20 C0 A8 10 11 50 04 00 00 25 05 00 80 3A EB 08 20 00     C0    69800    58
```

**In the groove,** the pen is farther out, but X reads about 700 units
*inside* the edge. The close-tip-fix bit is clear, and hover reads 255.

```
 1A 02 00 80 F2 0D 01 0C 06 00 00 00 00 00 70 FF D4 40 00 00     80    69106   255
 1A 02 00 80 EE 0D 81 0D 06 00 00 00 00 00 80 FF FC 40 00 00     80    69102   255
 1A 02 00 80 EC 0D 41 10 06 00 00 00 00 00 90 FF 38 41 00 00     80    69100   255
 1A 02 00 80 F4 0D F1 10 06 00 00 00 00 00 A0 FF 60 41 00 00     80    69108   255
```

Across each whole sweep:

| Sweep | Frames | X | Close-tip-fix bit |
| --- | --- | --- | --- |
| Right edge | 2,471 | 69800 on every frame | set on 99.6% |
| Right groove | 2,197 | 68553–69393, median 69163 | set on none |

Sweeps of the other three grooves read inside their edges in the same way,
with medians between 637 and 924 units in. A clamp at the edge can't catch
these positions, but the status bit can.
