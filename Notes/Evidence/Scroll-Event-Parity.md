# Scroll events: MockTab and a trackpad

Supports [Synthesizing tablet events: scrolling](../macOS-Tablet-Event-Synthesis.md#scrolling).

**Capture:** the same flick-and-coast scroll, once on Apple's trackpad and
once through MockTab with momentum on, recorded as events reach an app.
That gave 333 trackpad scroll events and 477 from MockTab.

**What to look for:** the phases each scroll goes through, and which fields
each source sets.

Both run through the same phases in the same order:

| Step | Scroll phase | Momentum phase | Trackpad | MockTab |
| --- | --- | --- | --- | --- |
| Fingers down | 1, began | 0 | 1 event | 1 event |
| Moving | 2, changed | 0 | 11 | 6 |
| Fingers up | 4, ended | 0 | 1 | 1 |
| Coast starts | 0 | 1, began | 1 | 1 |
| Coasting | 0 | 2, continued | 128 | 32 |
| Coast ends | 0 | 3, ended | 1 | 1 |

Both set the same deltas: line, point, and fixed-point, on both axes. Both
mark the scroll as continuous.

One field differs. The trackpad sets `scrollWheelEventScrollCount` to 1 on
almost every event; MockTab leaves it unset. Setting it made no difference,
so MockTab doesn't. The other differences are fields an ordinary app can't
set, such as which process sent the event.

Some web pages still reject MockTab's momentum scrolling. The cause lies in
those fields we can't set, or somewhere this capture doesn't show.
(unverified)
