# PTH-860 Bluetooth Keys: Held, Not Pulsed

Supports [Intuos Pro gen 2: Bluetooth Classic `0x80`](../Wacom-Intuos-Pro-Gen2-Protocol.md#bluetooth-classic-0x80-pth-660-pth-860).

**Capture:** a PTH-860 over Bluetooth Classic, pen away. Each ExpressKey,
top to bottom, pressed and held about two seconds, then a finger rested on a
key without pressing it. In a second capture, the ring's center button held
about five seconds. Bytes 276–287 of the 361-byte container, printed only
when they change.

**What to look for:** byte 282 has one bit per key, bit 0 at the top, and
stays set for as long as the key is held. Byte 283 is set while a finger
touches a key: it rises before the press, falls after the release, and also
rises for a finger that rests without pressing. Byte 281 carries the ring's
center button as `0x40` while it's held, over a constant `0x80`. Byte 284 is
the battery (`0x61`, 97%).

```
  time      [276 … 287]                           what happened
  2.82 s    00 00 00 00 00 80 00 01 61 7f 38 01   finger on key 1
  4.17 s    00 00 00 00 00 80 01 01 61 7f 38 01   key 1 pressed
  6.59 s    00 00 00 00 00 80 00 01 61 7f 38 01   key 1 let go
  6.69 s    00 00 00 00 00 80 00 00 61 7f 38 01   finger off
  7.78 s    00 00 00 00 00 80 00 02 61 7f 38 01   finger on key 2
  9.07 s    00 00 00 00 00 80 02 02 61 7f 38 01   key 2 pressed
 10.37 s    00 00 00 00 00 80 00 02 61 7f 38 01   key 2 let go
   …        keys 3–8 the same, bits 2–7
 34.64 s    00 00 00 00 00 80 80 80 61 7f 38 01   key 8 pressed
 37.41 s    00 00 00 00 00 80 00 80 61 7f 38 01   key 8 let go
 39.74 s    00 00 00 00 00 80 00 02 61 7f 38 01   finger rests on key 2, no press
 48.40 s    00 00 00 00 00 80 00 00 61 7f 38 01   finger off

  0.57 s    00 00 00 00 00 c0 00 00 61 7f 38 01   center button held
  5.66 s    00 00 00 00 00 80 00 00 61 7f 38 01   center button let go
```

So the keys run top to bottom in libwacom's order (A–D above the ring, E–H
below it), and a held key reads as held over Bluetooth just as over USB. The
PTH-660 over Bluetooth hasn't been captured this way.
