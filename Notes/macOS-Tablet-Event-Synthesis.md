# Synthesizing tablet events that macOS apps accept

A user-space tablet driver on macOS posts `CGEvent`s. Apps then decide from
those events' fields whether they came from a pen, which pen, and what it
can do. Missing fields don't fail loudly: an app quietly falls back to
mouse behavior or ignores a capability. Everything here was found by
capturing events from Wacom's driver and from a trackpad, comparing them
field by field with ours, and checking the result in the apps named.

## Proximity

Post a `tabletProximity` event when a pen end enters and when it leaves,
**and** the same fields again on a `mouseMoved` with `mouseEventSubtype` =
2. Cocoa apps that read proximity from `NSEvent` subtypes see only the
second copy.

| Field | Value |
| --- | --- |
| `VendorID`, `TabletID` | USB vendor and product ID |
| `DeviceID` | One per tablet, the same on every event from it |
| `PointerID` | Distinct for each end of a pen |
| `PointerType` | 1 pen, 2 cursor, 3 eraser; keep it on the leaving event too |
| `VendorPointerType` | The pen's tool code; set bit `0x8` for the eraser end |
| `VendorPointerSerialNumber` | The pen's serial, the same for both ends |
| `VendorUniqueID` | `toolCode << 32 \| serial`: different for each end |
| `CapabilityMask` | Below |
| `EnterProximity` | 1 entering, 0 leaving |

`VendorPointerSerialNumber` is field 34. An undocumented field 172 looks
plausible and does nothing.

**The eraser needs its own identity.** If the eraser end reports the pen's
tool code and the same unique ID, Photoshop and Krita treat it as the pen.
Wacom keeps the tool code, sets bit 3, and gives each end its own unique ID.

**Capability mask.** Wacom sends `0x15C7` for ordinary pens and `0x35C7`
for the Art Pen. The `0x2000` bit announces rotation: without it Photoshop
ignores barrel rotation (its Rotation brush control stays dead), though
Illustrator uses it regardless. Clear the tilt and orientation
bits (`0x1180`) for tablets without tilt.

## Pen samples

Each pen sample is a mouse event (`mouseMoved` or `leftMouseDragged`)
carrying tablet fields, with `mouseEventSubtype` = 1. Set the subtype
**first**: the tablet fields share storage keyed by it.

- Set both `tabletEventPointPressure` and `mouseEventPressure`. Photoshop
  reads the first.
- Set `tabletEventPointX`/`Y` (tablet coordinates), tilt, rotation and the
  device ID.
- Stamp each event with the time the tablet reported the sample, not the
  time it was posted. Brush engines derive speed from timestamps.
- Add `maskNonCoalesced` to every event. Wacom does, and without it the
  system merges moves and drops samples.
- Use real mouse event types for drags (`CGEventCreateMouseEvent`). On
  macOS 26, WindowServer's title-bar drag only follows pointer events
  created that way.

## Clicks

AppKit pairs a press with its drags and release through two fields that
synthetic events leave at zero:

- `mouseEventNumber`: increment on each press; repeat it on that press's
  drags and release.
- `mouseEventClickState`: always set on the press (1 for a single click);
  the release repeats the press's value, or 0 if the pointer moved more than
  a few points in between.

Without these, Pages, Keynote and Numbers refused double-clicks in headers
and footers and fought drag selection. With them, no per-app workarounds
were needed.

## Scrolling

Smooth scrolling from a pen, ring or touch posts continuous, phased
`scrollWheel` events. `CGEventCreateScrollWheelEvent2` leaves the delta
fields an app reads through `NSEvent` at zero, so fill them in:

- **Write the line delta first.** Setting it makes Core Graphics recompute
  the point and fixed-point deltas, so anything written before it is
  overwritten. Written last, it quantized every scroll to 8-point steps.
- Fixed-point deltas are fractional **lines** (about 10 points per line),
  not points.
- Point deltas are whole points.
- During a momentum tail, set the scroll phase to 0 and carry the sequence
  in the momentum phase. Setting both on one event confuses AppKit and
  WebKit.

**A limit we couldn't get past.** Some web pages and Calendar's Month and
Year views reject a synthesized phased stream that also carries momentum,
even when every field matches a trackpad's. What remains different can't
be set from user space: the sending process, the HID source state, and the
raw finger-contact gesture events. Scrolling there works with momentum off.
