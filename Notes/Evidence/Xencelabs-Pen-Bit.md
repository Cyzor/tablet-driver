# Xencelabs: telling the two pens apart

Supports [Xencelabs: pen bits](../Xencelabs-Protocol.md#input-byte-1-decides-the-frame).

**Capture:** a Pen Display 24 over USB, in one session that switches
between the Thin Pen and the 3 Button Pen several times. Each pen hovers,
touches down, and flips to its eraser, with each barrel button pressed in
turn.

**What to look for:** byte 1 is the status. Bit 7 (`0x80`) is set for every
3 Button Pen frame and clear for every Thin Pen frame. Neither pen sends a
serial number or tool code, so this bit is the only way to tell them apart.

Below is the first frame of each status seen in the session, bytes 0–11.

```
 report 0x02                            [1]   pen            state
 02 20 CC FF C5 43 00 00 04 07 00 00    20    Thin Pen       hovering
 02 21 93 01 FD 44 FE 00 06 04 01 00    21    Thin Pen       tip down
 02 24 A6 FF 9D 42 00 00 06 00 00 00    24    Thin Pen       button 2
 02 28 93 FF 43 41 00 00 0A 00 00 00    28    Thin Pen       button 3
 02 60 69 01 91 30 00 00 00 00 01 00    60    Thin Pen       eraser hovering
 02 61 10 05 3E 43 6D 00 00 00 01 00    61    Thin Pen       eraser down
 02 A0 33 FC C6 56 00 00 00 01 00 00    A0    3 Button Pen   hovering
 02 A1 51 FD 56 57 C8 01 04 07 00 00    A1    3 Button Pen   tip down
 02 A2 B6 FC D4 54 00 00 03 00 00 00    A2    3 Button Pen   button 1
 02 A4 79 FC EA 52 00 00 06 09 00 00    A4    3 Button Pen   button 2
 02 A8 F6 F9 FD 4E 00 00 1B 0C 00 00    A8    3 Button Pen   button 3
 02 E0 D7 FC C2 4E 00 00 00 00 00 00    E0    3 Button Pen   eraser hovering
 02 E1 C7 FD AC 50 25 00 0F 00 00 00    E1    3 Button Pen   eraser down
 02 C0 14 FF 70 4D 00 00 00 00 00 00    C0    either         out of range
```

`0x40` marks the eraser end, and `0x20` is set while either end is in
range. The out-of-range frame `C0` has bit 7 set no matter which pen left,
so a decoder should keep the last pen through it rather than read bit 7
there.

Bytes 12–31 are left out. Nothing in them changes from one pen to the other.
