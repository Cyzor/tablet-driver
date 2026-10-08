# Report Rate: Xencelabs Pen Display 24 and Cintiq 24HD

Supports [Xencelabs protocol](../Xencelabs-Protocol.md) and
[Intuos 10-byte format](../Wacom-Intuos-10-Byte-Protocol.md).

**Capture:** slow strokes on each pen display over USB, logging the time
each report arrived. The Cintiq test used an ordinary pen and an
Art Pen.

**What to look for:** the gap between reports, in milliseconds.

Xencelabs Pen Display 24, pen report `0x02` (bytes after 11 left out):

```
  gap      report
 4.97 ms   02 a0 ea 6b 63 86 00 00 21 00 00 00 …
 4.99 ms   02 a0 79 6b ea 86 00 00 21 00 00 00 …
 5.09 ms   02 a0 1b 6b 54 87 00 00 21 00 00 00 …
 4.11 ms   02 a0 8a 6a ec 87 00 00 21 00 00 00 …
 4.84 ms   02 a0 14 6a 73 88 00 00 21 00 00 00 …
```

Cintiq 24HD, ordinary pen:

```
  gap      report
 7.00 ms   02 e0 0a 8e 57 d3 00 3f d2 6c
 7.99 ms   02 e0 0a 8a 57 d5 00 3f d2 6c
 7.07 ms   02 e0 0a 86 57 d7 00 3f d2 6a
 6.98 ms   02 e0 0a 89 57 d8 00 3f d2 68
 7.05 ms   02 e0 0a 8b 57 d9 00 3f d2 68
```

| Device | Average gap | Position updates per second |
| --- | --- | --- |
| Xencelabs Pen Display 24 | 4.9 ms | about 200 |
| Cintiq 24HD, ordinary pen | 7.2 ms | about 140 |
| Cintiq 24HD, Art Pen | 9.1 ms | about 65 |

With an Art Pen, the Cintiq mixes rotation packets (`0xEA`) in with
position packets (`0xE0` and `0xE1`). About 4 in 10 reports carry only the
pen's rotation.

**What this doesn't show:** how long a stroke takes to reach the screen.
Drawing felt more responsive on the Cintiq, under both MockTab and the
vendor drivers, even though the Xencelabs sends position more often. The
delay must come from somewhere else, likely smoothing inside the tablet or
the display itself. (unverified)
