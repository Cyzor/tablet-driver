# pages-click-probe

Dumps every CGEvent field of mouse-button events, so a **real USB mouse** and
**MockTab's synthetic pen events** can be compared payload for payload in one
session.

## Why

`Notes/Scratch/iWork-Plain-Mouse-Click-State-Trilemma.md` establishes by
experiment that `mouseEventClickState` is the sole differentiator for Pages
header/footer edit-mode entry, and that subtype, pressure/tilt, proximity
wrapping, and move suppression are not. What it never did was compare against
real hardware — so "Pages requires `clickState = 1`" is inference from our own
synthetic events, not a measurement of a working one.

Two things this can settle that the note leaves open:

1. **`eventSourceStateID`** — never varied in the original experiments. MockTab
   posts from `CGEventSource(stateID: .privateState)` (`0`); real hardware is
   `.hidSystemState` (`2`). Click counting is maintained *per source state*, so
   "Quartz auto-filled" is not one behavior — it is whatever that source's
   counter produces, and ours was never seeded by the user's real clicks. If a
   hardware first click carries `clickState = 1` while ours carries `0`, the
   field was a proxy for the source all along.

2. **Whether the trilemma is positional** — the probe also reports the
   accessibility role/subrole under the cursor. If Pages reports something
   distinct over a header/footer versus body text, the click-state rule can be
   made positional instead of global and all three interactions can be
   satisfied at once.

## Build

```bash
swiftc -O main.swift -o pages-click-probe
```

Needs Accessibility permission for **the terminal running it**, not for the
binary (System Settings → Privacy & Security → Accessibility). If the tap
cannot be created the probe says so and exits.

## Procedure

Run it filtered to Pages so ordinary desktop clicks don't fill the log:

```bash
./pages-click-probe --app Pages | tee ~/Desktop/pages-click-probe.txt
```

Then, in one session:

1. **Self-check.** Click once anywhere in Pages with the mouse. You should get
   a block of output. If nothing appears, the tap isn't seeing events — stop
   and fix that first.
2. **Hardware baseline, body text.** With the USB mouse, click once in body
   text, then drag-select a few words.
3. **Hardware baseline, header — the case that matters.** With the USB mouse,
   double-click into a header or footer so it enters edit mode. This is the
   working payload we have never captured.
4. **Same two with the pen.** Repeat 2 and 3 with the tablet pen through
   MockTab, including the double-tap into the header that currently fails.

Quit with Ctrl-C, then send the file.

## Reading it

Each event prints `sourceStateID` (`2` = hardware, `0` = MockTab synthetic),
`mouseEventClickState`, every nonzero field, and the AX role under the cursor.

The comparison to make is step 3 against step 4 — same interaction, one
working, one not. Specifically:

- Does the hardware first click carry `clickState = 1`, or `0`?
- Do the two differ in any field *other* than `clickState` and
  `sourceStateID`?
- Does the AX role differ between header and body text?

A hardware first click reading `clickState = 0` would be the most interesting
result: it would mean the field is not what Pages keys on, and the real
differentiator is the source.

## Notes

- Listen-only. Never modifies, swallows, or delays an event.
- Re-enables itself if the system disables the tap for timeout.
- `--no-ax` skips the accessibility hit-test. The AX call has a 50 ms timeout
  so a busy Pages cannot stall the tap, but use this if anything feels sticky.
- The binary is gitignored; rebuild from source.
