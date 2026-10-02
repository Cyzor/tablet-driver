# Intuos Pro Bluetooth touch clock: 0.1 ms per count

Supports [Intuos Pro gen 2: the Bluetooth touch frame](../Wacom-Intuos-Pro-Gen2-Protocol.md).

**Capture:** one-finger touch on a PTH-660 over Bluetooth, for about a
minute.

**What to look for:** each 361-byte report `0x80` carries up to four touch
frames of 43 bytes, starting at byte 109. Each frame ends in a 16-bit
little-endian clock at frame bytes 41 (low) and 42 (high). Byte 0 of the frame
is `0x81`: bit 7 valid, one contact.

Consecutive frames are always exactly 100 counts apart. Reports arrive every
22.5 ms, with two or three frames each, so the tablet samples touch every
10 ms, not every 22.5 ms.

```
 arrival    frame  [0]  [41] [42]   clock
   0.0 ms     1     81   B4   8B    35764
   0.0 ms     2     81   18   8C    35864  +100
  22.5 ms     0     81   7C   8C    35964  +100
  22.5 ms     1     81   E0   8C    36064  +100
  45.0 ms     0     81   44   8D    36164  +100
  45.0 ms     1     81   A8   8D    36264  +100
  67.5 ms     0     81   0C   8E    36364  +100
  67.5 ms     1     81   70   8E    36464  +100
  90.0 ms     0     81   D4   8E    36564  +100
  90.0 ms     1     81   38   8F    36664  +100
  90.0 ms     2     81   9C   8F    36764  +100
 112.5 ms     0     81   00   90    36864  +100
```

Over the longest unbroken run in this session, 1,274 frames and 127,300
counts took 12,757.5 ms: 0.1002 ms per count. A second session gave the
same rate. At that rate the 16-bit clock wraps every 6.55 s.

Only the frame header and clock bytes are shown. The rest of each report,
including the pen's serial number, is left out.
