# PTH-850 Key Order: Top to Bottom

Supports [Intuos 10-byte format: ExpressKeys and touch ring](../Wacom-Intuos-10-Byte-Protocol.md#expresskeys-and-touch-ring).

**Capture:** each ExpressKey and the ring's center button on a PTH-850 over
USB, pressed one at a time from the top of the left edge to the bottom, with
the tablet in landscape for a right-handed user. `tools/hardware-check/key-order.sh`
named each key by its place in libwacom's layout and recorded the report it
sent.

**What to look for:** byte 4 has one bit per key, from bit 0 at the top to
bit 7 at the bottom, skipping the ring; byte 5 copies it. Byte 3 is the ring's
center button. So key N in MockTab's Buttons pane is the Nth key from the top,
and libwacom's letters run B to I down the edge, with A at the ring's center.

```
 position              letter   report 0x03                    key
 upper group, 1st        B      03 80 00 00 01 01 00 00 00 00   1
 upper group, 2nd        C      03 80 00 00 02 02 00 00 00 00   2
 upper group, 3rd        D      03 80 00 00 04 04 00 00 00 00   3
 upper group, 4th        E      03 80 00 00 08 08 00 00 00 00   4
 ring center             A      03 80 00 01 00 00 00 00 00 00   center
 lower group, 1st        F      03 80 00 00 10 10 00 00 00 00   5
 lower group, 2nd        G      03 80 00 00 20 20 00 00 00 00   6
 lower group, 3rd        H      03 80 00 00 40 40 00 00 00 00   7
 lower group, 4th        I      03 80 00 00 80 80 00 00 00 00   8
```

Intuos5 and Intuos Pro gen 1 share this report, so the order holds for them.
Intuos4 sends its keys in report `0x0C` and isn't covered here.
