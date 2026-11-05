# macOS Pen Events

A tablet driver running as an ordinary app posts `CGEvent`s. Apps read their
fields to tell a pen from a mouse, which pen it is, and what it can do. A
missing field raises no error; the app just treats the pen as a mouse.
Everything here matches real hardware field by field.

## Proximity

When a pen end enters or leaves range, post a `tabletProximity` event and a
`mouseMoved` event with `mouseEventSubtype` = 2, both with the same fields.
Cocoa apps see only the second.

| Field | Value |
| --- | --- |
| `VendorID`, `TabletID` | USB vendor and product ID |
| `DeviceID` | One per tablet, the same on every event from it |
| `PointerID` | Different for each end of a pen |
| `PointerType` | 1 pen, 2 cursor, 3 eraser; keep it on the leaving event too |
| `VendorPointerType` | The pen's tool code; set bit `0x8` for the eraser end |
| `VendorPointerSerialNumber` | The pen's serial, the same for both ends (field 34) |
| `VendorUniqueID` | `toolCode << 32 \| serial`: different for each end |
| `CapabilityMask` | Below |
| `EnterProximity` | 1 entering, 0 leaving |

Without its own tool code bit and unique ID, Photoshop and Krita treat the
eraser as the pen. Undocumented field 172 looks like a serial, but setting it
does nothing.

**Capability mask.** `0x15C7` for ordinary pens, `0x35C7` for the Art Pen,
plus `0x0200` when the pen reports hover height.

- `0x2000`, rotation: without it, Photoshop ignores barrel rotation and its
  Rotation brush control does nothing. Illustrator uses rotation regardless.
- `0x1180`, tilt and orientation: keep these set, even on a tablet without
  tilt. Without them, Rebelle's rotation brushes flip unpredictably.

**Announce a change of pen.** Some tablets name the pen only after it enters
range; the Intuos Pro gen 3 doesn't in its first frame. Post a leave for the
old pen and an enter for the new one, or apps keep the old pen's abilities
and ignore an Art Pen's rotation, for example.

**Announce again when the front app changes.** Proximity reaches only the
frontmost app, so an app brought forward with the pen in range never saw it
arrive. Rebelle then paints with the pen as a mouse, or with the other end's
brush. Post a leave and an enter in place. If a pen click brought the app
forward, wait for the tip to lift: the stroke belongs to the app it started
in.

## Pen Samples

Each sample is a `mouseMoved` or `leftMouseDragged` event with
`mouseEventSubtype` = 1. Set the subtype **first**: it decides which tablet
fields the event holds.

- Set both `tabletEventPointPressure`, which Photoshop reads, and
  `mouseEventPressure`.
- Set `tabletEventPointX` and `Y` in tablet coordinates, plus tilt, rotation,
  and the device ID.
- Stamp each event with the time the tablet reported it, not the time you
  post it. Brush engines work out speed from timestamps.
- Add `maskNonCoalesced`, or the system merges moves and loses samples.
- Create drags with `CGEventCreateMouseEvent`. On macOS 26, dragging a window
  by its title bar follows only events created that way.

## Clicks

AppKit pairs a press with its drags and release through two fields that
synthetic events leave at zero:

- `mouseEventNumber`: start from the system's press count (the sum of
  `CGEventSource.counterForEventType` over the three press types), add 1 per
  press, and repeat it on that press's drags and release. macOS 27 can
  mishandle a press numbered below the system's count: windows fail to
  activate, or clicks vanish. (unverified; another input tool reported it and
  adopted the same fix)
- `mouseEventClickState`: set it on every press, 1 for a single click. The
  release repeats it, or uses 0 if the pointer moved more than a few points.

Without them, Pages, Keynote, and Numbers missed double-clicks in headers and
footers and fought drag selection. With them, no app needed special handling.

## Scrolling

Smooth scrolling posts `scrollWheel` events with scroll phases.
`CGEventCreateScrollWheelEvent2` leaves the deltas `NSEvent` reads at zero, so
fill them in:

- **Write the line delta first.** Setting it recomputes the point and
  fixed-point deltas. Written last, it rounded every scroll to 8-point steps.
- Fixed-point deltas count fractions of a **line**, about 10 points; point
  deltas are whole points.
- During momentum, set the scroll phase to 0 and use the momentum phase.
  Both on one event confuses AppKit and WebKit.
- Set phases even without momentum. AppKit holds phase-free scrolling on the
  first view it reached until scrolling pauses, so it can't move on to the
  next view, as in Finder's column view. (observed)
- AppKit also holds a phased gesture on the view its first motion picked.
  When a pan turns clearly to the other axis, end the gesture and begin a new
  one, as lifting fingers off a trackpad does. (observed, Finder's column
  view)

**A known limit.** Some web pages reject synthesized scrolling with
momentum, though every field an app can set matches a trackpad's
([evidence](Evidence/Scroll-Event-Parity.md)). What differs can't be set by an
ordinary app: the sending process, its HID source state, and the trackpad's
raw contact events. Scrolling works there with momentum turned off.
