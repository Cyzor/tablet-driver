2026-04-06

# Wacom Rotation Support Research

The core behavioral difference across Rebelle, Krita, and Photoshop traces back to two things: **how each app interprets the `vendorPointerType` field in the proximity event**, and **how Qt's macOS tablet backend derives a rotation value from tilt for non-Art-Pen tools**. The precise mechanics are worth understanding.

## The Proximity Event Is the Gating Signal

Apple's `tabletProximityEvent` fields — particularly `vendorPointerType` and `capabilityMask` — are what apps use to classify the tool before any pointer data arrives. Your `postProximityEvent` already sets `vendorPointerType` to `0x0812` for Art Pen tool codes and `0x0802` (Grip Pen fallback) for everything else. That distinction is load-bearing for both Krita and Photoshop.[^1]

The relevant Apple documentation is `NSEvent`'s `vendorPointerType` and `capabilityMask` properties. The `capabilityMask` value `0x05C7` you currently post advertises pressure, tilt, rotation, and buttons simultaneously. Wacom's own developer docs confirm that `rotation` in `NSEvent` is only meaningful for the Art Pen and describes the angle between the pen's "front" and the top of the tablet — not purely barrel twist — so tilt changes can move it without any physical twist.[^2][^3][^4]

## Why Krita Reads Tilt as Rotation

Krita is Qt-based, so the relevant code path is Qt's `qnsview_tablet.mm` macOS backend. Qt reads `[event vendorPointingDeviceType]` from the proximity event: if the lower byte is `0x12` (Art Pen subtype), Qt constructs a `QTabletEvent` with device type `RotationStylus`; otherwise it uses `Stylus`. The critical wrinkle is that **for all pen types, Qt computes a rotation value from tilt azimuth** — essentially `atan2(tiltX, -tiltY)` converted to degrees — and passes it as `QTabletEvent::rotation()`. Krita brush presets configured with the "Rotation" sensor receive this derived azimuth angle regardless of tool type. From the user's perspective, tilting the pen steers what looks like a rotation parameter. This is by Qt design, not a Krita bug, and it means:[^5][^6]

- With `vendorPointerType = 0x0802`, Krita's brush engine still exposes a "rotation" value derived from tilt direction, which is why tilt-driven brushes *look* like they're using rotation.
- With `vendorPointerType = 0x0812`, Krita switches to the actual `tabletEventRotation` field (barrel/azimuth rotation from the Art Pen), and the Qt-side tilt-derived rotation is no longer the primary source.

The Krita manual documents the "Pen Tilt Direction Offset" setting added in 5.3, which directly acknowledges this tilt-to-rotation derivation and lets users tune it.[^7]

## How Photoshop Reads Tablet Fields

Photoshop does not use Qt. It has its own internal tablet API layer above CGEvents. Three things matter for full fidelity:

1. **Pressure** — Photoshop reads `tabletEventPointPressure` (the tablet union field), *not* `mouseEventPressure` alone. Your code already sets both fields on every `mouseDown`, `mouseUp`, and `mouseDragged` event, which is exactly why pressure "took finagling" to get working — most third-party drivers only set `mouseEventPressure`. The comment in your `postMouseDown` makes this explicit.[^1]
2. **Rotation vs. tilt** — Adobe maps `tabletEventRotation` to its "Pen Rotation" brush angle control, and `tabletEventTiltX`/`tabletEventTiltY` to its "Pen Tilt" control. If `tabletEventRotation` is non-zero even for a standard pen (because tilt produces a non-zero azimuth that gets packed into that field), Photoshop's "Angle Jitter → Pen Rotation" control will respond to it — which is the "tilt interpreted as rotation" symptom.[^8]
3. **Shim replay** — Photoshop historically fires `eSendTabletEvent` Apple Events (`eEventPointer`, `eEventProximity`) to request the driver re-emit the last tablet state at paint time. Your `replayPointerEvent` and `replayProximityEvent` methods handle this. Without them, Photoshop's brush dynamics silently discard tablet data for strokes that begin mid-frame.[^1]

## The Behavioral Matrix

| App | Tool-type detection | Rotation source | Tilt source |
| :-- | :-- | :-- | :-- |
| **Rebelle** | Ignores `vendorPointerType` | `tabletEventRotation` directly | `tiltX`/`tiltY` directly |
| **Krita (Qt)** | `vendorPointerType` byte `0x12` → `RotationStylus` | `tabletEventRotation` (Art Pen) or Qt-derived azimuth from tilt (Grip Pen) | `xTilt`/`yTilt` from `QTabletEvent` |
| **Photoshop** | `vendorPointerType` + proximity `capabilityMask` | `tabletEventRotation` → "Pen Rotation" control | `tabletEventTiltX`/`Y` → "Pen Tilt" control |

## Key Documentation Sources

- **Apple CGEvent field reference**: [`CGEventField`](https://developer.apple.com/documentation/coregraphics/cgeventfield) — defines `tabletEventTiltX`, `tabletEventTiltY`, `tabletEventRotation`, `tabletEventPointPressure`, `mouseEventPressure`, `mouseEventSubtype`, and the proximity fields.[^4]
- **Apple NSEvent tablet properties**: [`NSEvent` — tabletProximity fields](https://developer.apple.com/documentation/appkit/nsevent) — `vendorPointerType`, `capabilityMask`, `rotation`, `tilt`.[^2]
- **Qt macOS tablet source**: [`qnsview_tablet.mm`](https://code.qt.io/cgit/qt/qtbase.git/tree/src/plugins/platforms/cocoa/qnsview_tablet.mm) — shows exactly how Qt maps `vendorPointingDeviceType` to `QTabletEvent::TabletDevice` and derives azimuth-rotation from tilt components.
- **Wacom Developer Docs — NSEvents Basics**: [developer-docs.wacom.com](https://developer-docs.wacom.com/docs/icbt/macos/ns-events/ns-events-basics/) covers the `rotation` field semantics and the Art Pen specifically.[^3]
- **Wacom Developer Docs — Driver Request Interface**: [DRI Basics](https://developer-docs.wacom.com/docs/icbt/macos/dri/dri-basics/) documents the `eSendTabletEvent` Apple Events (`eEventPointer`/`eEventProximity`) that Photoshop fires.[^9]

The practical fix if you want a standard-pen user to avoid Photoshop's "angle jitter uses rotation instead of tilt" behavior is to ensure `tabletEventRotation` is `0.0` for non-Art-Pen tools (which your `WacomGenericDevice` already does — it always passes `rotation: 0.0` in its `TabletPoint` structs ). For Krita, the tilt-as-rotation behavior is inherent to Qt's azimuth derivation and cannot be suppressed at the driver level — users need to select brushes that use the "Tilt" sensor rather than "Rotation" when using a non-Art-Pen tool.[^10]
<span style="display:none">[^11][^12][^13][^14][^15][^16][^17][^18][^19][^20][^21][^22][^23][^24][^25][^26][^27][^28][^29][^30][^31][^32][^33][^34][^35][^36][^37][^38][^39][^40][^41][^42]</span>

<div align="center">⁂</div>

[^1]: InputInjector.txt

[^2]: https://developer.apple.com/documentation/appkit/nsevent/rotation

[^3]: https://developer-docs.wacom.com/docs/icbt/macos/ns-events/ns-events-basics/

[^4]: https://developer.apple.com/documentation/appkit/nsevent/capabilitymask

[^5]: https://krita-artists.org/t/pen-rotation-issue-twisting-stylus-vs-changing-drawing-angle/64547

[^6]: https://doc.qt.io/qt-6/qtabletevent.html

[^7]: https://docs.krita.org/en/reference_manual/preferences/tablet_settings.html

[^8]: https://community.adobe.com/questions-712/shape-dynamics-wrongly-warns-of-no-tilting-tablet-1149002

[^9]: https://developer-docs.wacom.com/docs/icbt/macos/dri/dri-basics/

[^10]: WacomGenericDevice-2.txt

[^11]: https://forum.kde.org/viewtopic.php%3Ff=139\&t=156141.html

[^12]: https://community.adobe.com/bug-reports-711/pen-tilt-not-functioning-in-photoshop-mac-os-657313

[^13]: https://community.adobe.com/questions-712/mac-big-sur-m1-pen-pressure-pen-tilt-has-a-warning-sign-despite-it-working-in-other-app-1124656

[^14]: https://www.reddit.com/r/XPpen/comments/1dfmm7r/xp_pen_deco_v2_tilt_photoshop_doesnt_work/

[^15]: https://www.reddit.com/r/wacom/comments/1epl146/rotation_touch_gesture_in_photoshop/

[^16]: https://developer.apple.com/documentation/appkit/nsevent/eventtypemask/tabletproximity?changes=__3

[^17]: https://www.youtube.com/watch?v=c5L3klgiFdo

[^18]: https://community.adobe.com/bug-reports-711/p-pen-tilt-partially-unresponsive-since-latest-update-658674

[^19]: https://developer.apple.com/documentation/appkit/nsresponder/tabletpoint(with:)

[^20]: https://helpx.adobe.com/photoshop/using/touch-gestures.html

[^21]: https://developer.apple.com/documentation/appkit/nsevent/eventtype/rotate

[^22]: https://www.reddit.com/r/DigitalArt/comments/lbmi5s/cant_get_tilt_to_work_on_photoshop/

[^23]: https://www.reddit.com/r/krita/comments/1ft8ys8/how_can_i_avoid_this_rotation_artifact_on_line/

[^24]: https://www.reddit.com/r/krita/comments/zi83w0/krita_canvas_rotation_issue/

[^25]: https://www.reddit.com/r/krita/comments/8gsbhe/how_does_one_rotate_the_canvas_in_tablet_mode/

[^26]: https://www.reddit.com/r/ArtistLounge/comments/1qf4kt5/opentabletdriver_compatability_with_any_given/

[^27]: https://www.reddit.com/r/krita/comments/uo65gq/rotate_mode_not_working/

[^28]: https://developer.apple.com/documentation/appkit/nsevent/eventtypemask/tabletproximity

[^29]: https://developer-docs.wacom.com/docs/icbt/macos/ns-events/ns-events-overview/

[^30]: https://developer-docs.wacom.com/docs/icbt/web/web-api-overview/

[^31]: https://developer-docs.wacom.com/docs/icbt/macos/ns-events/ns-events-reference/

[^32]: https://developer-docs.wacom.com/docs/icbt/macos/multi-touch/multitouch-framework-reference/

[^33]: https://www.reddit.com/r/wacom/comments/144909h/art_pen_barrel_rotation/

[^34]: https://www.luckyclan.com/forum/index.php?topic=3320.0

[^35]: https://forum.qt.io/topic/135387/qt-drawpie-location-and-rotation-issue

[^36]: https://krita-artists.org/t/how-can-i-rotate-the-view-with-the-tactil-panel-of-the-tablet/7199

[^37]: https://github.com/KDE/krita/blob/master/libs/ui/canvas/kis_canvas_controller.cpp

[^38]: https://www.klayout.de/doc/code/class_QTabletEvent.html

[^39]: https://stuff.mit.edu/afs/athena/software/texmaker_v5.0.2/qt57/doc/qtgui/qtabletevent.html

[^40]: https://docs.krita.org/de/reference_manual/brushes/brush_settings/options.html

[^41]: https://srinikom.github.io/pyside-docs/PySide/QtGui/QTabletEvent.html

[^42]: https://invent.kde.org/khey/krita-callig/-/blob/v5.2.0-prealpha/3rdparty/ext_qt/0003-Add-support-for-pen-tilt-rotation-for-Android.patch


2026-04-06

There are at least three distinct problems here, none of which the proximity event changes alone address. Let me go through them in order of certainty.

## Bug 1: Delta Gate Drops Rotation-Only Changes

The delta gate in `inject()` only fires when position or pressure changes: 

```swift
let moved = !hasPostedPoint
    || abs(screenPoint.x - lastPostedPoint.x) > Self.positionEpsilon
    || abs(screenPoint.y - lastPostedPoint.y) > Self.positionEpsilon
    || (tipDown && abs(pressure - lastPostedPressure) > Self.pressureEpsilon)
```

If the pen is twisted without meaningful position change — exactly the "turning screwdriver" motion — every rotation-update report gets silently dropped. No app sees those events. Rotation needs its own tracked axis:

```swift
private static let rotationEpsilon: Double = 0.005  // ~0.3 degrees
private var lastPostedRotation: Double = 0.0

// In the moved condition, add:
|| abs(point.rotation - lastPostedRotation) > Self.rotationEpsilon

// After posting, add:
lastPostedRotation = point.rotation

// On proximity exit, reset:
lastPostedRotation = 0.0
```

You should also reset `lastPostedRotation` at the same point you reset `lastPostedPressure` (on proximity exit).

## Bug 2: Qt Caches QPointingDevice Per Tool — Won't Re-register

Krita uses Qt 6's macOS tablet backend (`qnsview_tablet.mm`), which creates a `QPointingDevice` the first time it sees a given `(vendorID, pointerID)` combination in a proximity event. It stores the device's declared capabilities at that moment and **does not update them** when a later proximity event arrives with the same ID but a different `vendorPointerType` or `capabilityMask`.

Your code always posts `tabletProximityEventPointerID = 1`. If Krita already registered this device from a previous session or from a proximity event fired before your revision deployed, it has a cached `QPointingDevice` without `QInputDevice::Capability::Rotation`. The new proximity events with `vendorPointerType = 0x0812` and the rotation capability bit are ignored because Qt matches by ID and reuses the cached device object. 

The fix is to derive the pointer ID from the tool type, so an Art Pen presents a different ID than a Grip Pen and forces Qt to register a new device:

```swift
// In postProximityEvent, replace the fixed value 1 with:
let pointerID: Int64 = Int64(activeToolCode) & 0xFF  // e.g. 0x12 for Art Pen, 0x02 for Grip Pen
e.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
```

This must stay consistent across the proximity event and all subsequent pointer events. You'll need to store the current pointer ID as instance state and use it in `postTabletPointerEvent`, `postMouseDown`, etc., wherever `tabletEventDeviceID` is set — otherwise Qt may discard pointer events that don't match the registered device ID.

## Bug 3: What `NSEvent.rotation` Actually Measures (and What Krita/Photoshop Expect)

The Wacom developer docs state explicitly: "Rotation is the angle between the 'front' of the pen and the top of the tablet... For styli, this rotation is different than 'twisting' the barrel of the pen. While twisting the barrel of the pen does cause a rotation change, **the rotation can change without actually twisting the barrel**." [developer-docs.wacom](https://developer-docs.wacom.com/docs/icbt/macos/ns-events/ns-events-basics/)

This means the `tabletEventRotation` field encodes a compound orientation angle that moves with tilt even without any barrel twist. If your Art Pen device driver computes `point.rotation` as pure barrel twist (just the axial spin component of the HID report), there will be a mismatch: apps will see rotation that doesn't respond to tilt the way they expect.

Additionally, the CGEvent field `tabletEventRotation` expects **radians** (range roughly −π to π), while `NSEvent.rotation` returns **degrees** — AppKit converts automatically. If your device driver is setting `point.rotation` in degrees and that value flows directly into `tabletEventRotation`, Qt and Photoshop will receive wildly out-of-range radian values when read back through `NSEvent.rotation`. Rebelle may avoid this if it reads the CGEvent field directly. Confirm the units your dedicated Art Pen driver uses for `point.rotation`.

## Fix Sequence

| Priority | Issue | Fix |
|---|---|---|
| 1 | Delta gate drops twist-only events | Add `rotationEpsilon` gate and `lastPostedRotation` tracking |
| 2 | Qt caches stale device without rotation capability | Derive `pointerID` from tool code; keep it consistent across all event types |
| 3 | Unit mismatch in `tabletEventRotation` | Ensure device driver outputs radians (−π to π); verify `NSEvent.rotation` reads correctly in test app |

Fixing bug 1 alone is a prerequisite for verifying anything else — without it, twisting the pen in place sends nothing to any app. With bug 2 fixed, Krita will register a fresh `QPointingDevice` with rotation capability declared. With bug 3 confirmed, the values will be in the correct range for both apps.