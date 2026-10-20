# DTK-2400 Key Order: Top to Bottom, Side by Side

Supports [Older Cintiq models: ExpressKeys and touch strips](../Wacom-Pen-Display-Protocols.md#expresskeys-and-touch-strips).

**Capture:** each of the 16 ExpressKeys on a Cintiq 24HD (DTK-2400) over USB,
pressed one at a time from the top of the left side to the bottom, then the
same down the right side. `tools/hardware-check/key-order.sh` named each key
by its place in libwacom's layout and recorded the report it sent.

**What to look for:** report `0x0C` carries the left side's keys in byte 6
and the right side's in byte 8, one bit each from bit 0 at the top. On each
side, the first three are the mode keys beside the ring and the other five
the key block below it. libwacom's letters run A to H down the left side and
I to P down the right, in the same order as the bits.

```
 position                letter   report 0x0C                    key
 left, mode key 1          A      0c 00 00 00 00 00 01 00 00 00   left 1
 left, mode key 2          B      0c 00 00 00 00 00 02 00 00 00   left 2
 left, mode key 3          C      0c 00 00 00 00 00 04 00 00 00   left 3
 left, key block 1         D      0c 00 00 00 00 00 08 00 00 00   left 4
 left, key block 2         E      0c 00 00 00 00 00 10 00 00 00   left 5
 left, key block 3         F      0c 00 00 00 00 00 20 00 00 00   left 6
 left, key block 4         G      0c 00 00 00 00 00 40 00 00 00   left 7
 left, key block 5         H      0c 00 00 00 00 00 80 00 00 00   left 8
 right, mode key 1         I      0c 00 00 00 00 00 00 00 01 00   right 1
 right, mode key 2         J      0c 00 00 00 00 00 00 00 02 00   right 2
 right, mode key 3         K      0c 00 00 00 00 00 00 00 04 00   right 3
 right, key block 1        L      0c 00 00 00 00 00 00 00 08 00   right 4
 right, key block 2        M      0c 00 00 00 00 00 00 00 10 00   right 5
 right, key block 3        N      0c 00 00 00 00 00 00 00 20 00   right 6
 right, key block 4        O      0c 00 00 00 00 00 00 00 40 00   right 7
 right, key block 5        P      0c 00 00 00 00 00 00 00 80 00   right 8
```

The three panel buttons on the bezel aren't in libwacom's layout and weren't
part of this walk; their bits are listed under 24HD panel buttons.
