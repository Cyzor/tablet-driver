# PTH-850 Pressure: No Jump at First Touch

Supports [Intuos 10-byte format: pen data packet](../Wacom-Intuos-10-Byte-Protocol.md#pen-data-packet-types-0x000x03).

**Capture:** 27 touchdowns with an Art Pen on a PTH-850 over USB, from a
light touch to a firm tap.

**What to look for:** pressure is 11 bits, from bytes 6 and 7 and the low
bit of byte 1. It climbs a few counts per report from the first contact.
This is the lightest touchdown:

```
  time      pen packet                     pressure
 -13 ms     02 e0 4d 33 0f 9c 00 10 57 3e      0
   0 ms     02 e1 4d 24 0f 97 01 90 57 3d     13   0.6%
  12 ms     02 e0 4d 15 0f 92 02 d0 d7 39     22   1.1%
  25 ms     02 e0 4d 0a 0f 8e 04 10 d7 3a     32   1.6%
  37 ms     02 e1 4c fa 0f 87 05 50 d7 39     43   2.1%
  50 ms     02 e0 4c e8 0f 80 06 50 d7 3e     50   2.4%
  62 ms     02 e1 4c d9 0f 7a 06 d0 d8 3c     55   2.7%
```

The first reading ranged from 0.6% to 30% of full pressure across all 27
touchdowns. The high values came from firm taps, which reach that force
before the first report. No touchdown jumped from a low value to a high one.

If pressure seems to jump, check two things. Art Pen rotation packets
(status `0xEA`) carry the angle where pressure would be, and tool packets
(status `0xC2`) aren't pen data. Read either one as a pen packet and you get
a false spike.
