# PTK-870 Dial: 24 Steps per Turn

Supports [Intuos Pro gen 3: USB ExpressKey report `0x11`](../Wacom-Intuos-Pro-Gen3-Protocol.md#usb-expresskey-report-0x11).

**Capture:** one slow clockwise turn of the left dial on a PTK-870 over
USB, starting and stopping at a mark. A second turn, and a turn of the right
dial, gave the same count.

**What to look for:** byte 4 is the left dial's signed step count. Each
report carries `01`, one step clockwise, and one full turn takes 24 reports.
Nothing else in the report changes.

```
 time      report 0x11                  
  0.00 s   11 00 00 00 01 00 00 00 00   step 1
  1.68 s   11 00 00 00 01 00 00 00 00   step 2
  2.62 s   11 00 00 00 01 00 00 00 00   step 3
  3.56 s   11 00 00 00 01 00 00 00 00   step 4
  4.59 s   11 00 00 00 01 00 00 00 00   step 5
  6.47 s   11 00 00 00 01 00 00 00 00   step 6
  7.38 s   11 00 00 00 01 00 00 00 00   step 7
  8.37 s   11 00 00 00 01 00 00 00 00   step 8
  9.25 s   11 00 00 00 01 00 00 00 00   step 9
 10.17 s   11 00 00 00 01 00 00 00 00   step 10
 11.07 s   11 00 00 00 01 00 00 00 00   step 11
 11.95 s   11 00 00 00 01 00 00 00 00   step 12
 12.83 s   11 00 00 00 01 00 00 00 00   step 13
 13.70 s   11 00 00 00 01 00 00 00 00   step 14
 14.94 s   11 00 00 00 01 00 00 00 00   step 15
 16.14 s   11 00 00 00 01 00 00 00 00   step 16
 17.07 s   11 00 00 00 01 00 00 00 00   step 17
 17.97 s   11 00 00 00 01 00 00 00 00   step 18
 18.76 s   11 00 00 00 01 00 00 00 00   step 19
 19.53 s   11 00 00 00 01 00 00 00 00   step 20
 20.34 s   11 00 00 00 01 00 00 00 00   step 21
 21.37 s   11 00 00 00 01 00 00 00 00   step 22
 22.43 s   11 00 00 00 01 00 00 00 00   step 23
 23.60 s   11 00 00 00 01 00 00 00 00   step 24
```

The dial's surface has 38 raised ridges, so counting ridges gives the wrong
answer. They're grip texture, not detents.
