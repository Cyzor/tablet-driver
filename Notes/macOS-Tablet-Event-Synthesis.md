# Synthesizing tablet events that macOS apps accept

A tablet driver that runs as an ordinary app on macOS posts `CGEvent`s.
Apps read those events' fields to decide whether they came from a pen,
which pen it was, and what it can do. A missing field causes no error. The
app just treats the pen as a mouse, or ignores what it can do.

Everything here comes from capturing events from Wacom's driver and from a
trackpad, comparing them field by field with MockTab's, and checking the
result in the apps named.

## Proximity

When a pen end comes into range or leaves it, post two events with the same
fields:

1. a `tabletProximity` event, and
2. a `mouseMoved` event with `mouseEventSubtype` = 2.

Cocoa apps read proximity from `NSEvent` subtypes, so they see only the
second one.

| Field | Value |
| --- | --- |
| `VendorID`, `TabletID` | USB vendor and product ID |
| `DeviceID` | One per tablet, the same on every event from it |
| `PointerID` | Different for each end of a pen |
| `PointerType` | 1 pen, 2 cursor, 3 eraser; keep it on the leaving event too |
| `VendorPointerType` | The pen's tool code; set bit `0x8` for the eraser end |
| `VendorPointerSerialNumber` | The pen's serial, the same for both ends |
| `VendorUniqueID` | `toolCode << 32 \| serial`: different for each end |
| `CapabilityMask` | Below |
| `EnterProximity` | 1 entering, 0 leaving |

`VendorPointerSerialNumber` is field 34. Field 172 is undocumented and
looks like it might hold the serial, but setting it does nothing.

**Give the eraser its own identity.** Photoshop and Krita treat the eraser
as the pen when it reports the same tool code and unique ID. Wacom keeps
the tool code but sets bit 3, and gives each end its own unique ID.

**Capability mask.** Wacom sends `0x15C7` for ordinary pens and `0x35C7`
for the Art Pen, and adds `0x0200` when the pen reports hover height.

- The `0x2000` bit says the pen can rotate. Without it, Photoshop ignores
  barrel rotation, and its Rotation brush control does nothing. Illustrator
  uses rotation either way.
- Keep the tilt and orientation bits (`0x1180`) set. Without them, Rebelle's
  rotation brushes flipped unpredictably. Setting them for a tablet that
  has no tilt does no harm.

**Announce a change of pen.** Apps learn what a pen can do only from
proximity events. Sometimes you learn which pen it is only after it's come
into range: the Intuos Pro gen 3, for one, doesn't say in the first frame.
When that happens, post a leave for the old pen, then an enter for the new
one. Otherwise apps keep the old pen's abilities. An Art Pen's rotation,
for example, is ignored until the pen leaves range.

## Pen samples

Each pen sample is a mouse event (`mouseMoved` or `leftMouseDragged`) with
`mouseEventSubtype` = 1 and the tablet fields filled in. Set the subtype
**first**, because which tablet fields the event holds depends on it.

- Set both `tabletEventPointPressure` and `mouseEventPressure`. Photoshop
  reads the first.
- Set `tabletEventPointX` and `Y` in tablet coordinates, along with tilt,
  rotation, and the device ID.
- Give each event the time the tablet reported the sample, not the time it
  was posted. Brush engines work out speed from timestamps.
- Add `maskNonCoalesced` to every event. Wacom does, and without it the
  system merges moves and drops samples.
- Create drag events with `CGEventCreateMouseEvent`. On macOS 26, dragging
  a window by its title bar only follows events created that way.

## Clicks

AppKit matches a press with its drags and its release using two fields.
Synthetic events leave both at zero, so set them:

- `mouseEventNumber`: add 1 for each press, and repeat that number on the
  press's drags and release.
- `mouseEventClickState`: always set it on the press, 1 for a single click.
  The release repeats the press's value, or uses 0 if the pointer moved
  more than a few points in between.

Without these fields, Pages, Keynote, and Numbers wouldn't take
double-clicks in headers and footers, and fought drag selection. With
them, no app needed special handling.

## Scrolling

Smooth scrolling from a pen, ring, or touch posts a continuous series of
`scrollWheel` events with scroll phases. `CGEventCreateScrollWheelEvent2`
leaves the deltas that apps read through `NSEvent` at zero, so fill them in:

- **Write the line delta first.** Setting it makes Core Graphics recompute
  the point and fixed-point deltas, overwriting anything already written.
  Written last, it rounded every scroll to 8-point steps.
- Fixed-point deltas count fractions of a **line**, about 10 points each,
  not points.
- Point deltas are whole points.
- While momentum carries a scroll on after release, set the scroll phase to
  0 and use the momentum phase instead. Setting both on one event confuses
  AppKit and WebKit.

**A known limit.** Some web pages reject synthesized scrolling that
includes momentum, though every field that matters matches a trackpad's
([evidence](Evidence/Scroll-Event-Parity.md)). The rest can't be set by an
ordinary app: which process sent the event, the state of its HID source,
and the trackpad's raw finger-contact events. Scrolling works there with
momentum turned off.
