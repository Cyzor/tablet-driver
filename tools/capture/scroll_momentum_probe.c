// scroll_momentum_probe.c — post a synthetic began/changed/ended live scroll
// sequence followed by a momentum tail, independent of MockTab's
// InputInjector/MomentumTail machinery, to isolate whether a raw CGEvent
// stream alone (not anything else in MockTab's pipeline) is what macOS 27
// handles differently for Finder column view's horizontal pan.
//
// v2: v1 jumped straight to momentum-phase-only events from a cold start and
// failed to move ANY axis horizontally in ANY Finder view (even icon/list,
// where MockTab's real horizontal panning works fine) — so v1 wasn't a fair
// repro. Real MockTab (PanScrollTracker.swift) always brackets a real pan
// with .began -> N x .changed -> .ended live-phase events (each with a
// companion "gesture" CGEvent, type 29) BEFORE handing off to the momentum
// tail; momentum-only from a cold start is not a shape AppKit ever actually
// receives from MockTab. v2 reproduces that full contract.
//
// Field set mirrors MockTab's InputInjector+CGEvents.swift postPanScroll /
// postPanScrollGesture / postPanScrollMomentum / applyTrackpadDeltaFields
// exactly (per the 2026-08-10 code audit): pixel units, continuous=1,
// live phase carried in scrollWheelEventScrollPhase (began=1/changed=2/
// ended=4) with scrollWheelEventMomentumPhase=0, then during the tail
// scrollPhase=0 with momentumPhase carrying begin=1/continue=2/end=3;
// axis1=Y axis2=X point+fixedPt+derived-line deltas; single reused
// CGEventSource(.privateState); posted via kCGHIDEventTap.
//
// Usage:
//   clang -o scroll_momentum_probe scroll_momentum_probe.c \
//       -framework ApplicationServices -framework CoreFoundation
//   ./scroll_momentum_probe horizontal   # or: vertical
//
// Point the mouse at a Finder column view (deep enough to need horizontal
// scroll) before running. Requires Accessibility permission for Terminal.
// Gives 3 seconds to focus the target window before posting.

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef enum { PhaseNone = 0, PhaseBegin = 1, PhaseContinue = 2, PhaseEnd = 3 } MomentumPhase;
typedef enum { ScrollBegan = 1, ScrollChanged = 2, ScrollEnded = 4 } LivePhase;

static void setTrackpadDeltaFields(CGEventRef e, double dx, double dy) {
    int64_t ix = (int64_t)dx, iy = (int64_t)dy;
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis1, iy);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis2, ix);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventFixedPtDeltaAxis1, (int64_t)(dy * 65536.0));
    CGEventSetIntegerValueField(e, kCGScrollWheelEventFixedPtDeltaAxis2, (int64_t)(dx * 65536.0));
    int64_t lineY = iy == 0 ? 0 : (iy > 0 ? 1 : -1) * (llabs(iy) / 10 > 1 ? llabs(iy) / 10 : 1);
    int64_t lineX = ix == 0 ? 0 : (ix > 0 ? 1 : -1) * (llabs(ix) / 10 > 1 ? llabs(ix) / 10 : 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1, lineY);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis2, lineX);
}

// Companion "gesture" event MockTab posts alongside every live-phase wheel
// event (not during the momentum tail) — mirrors postPanScrollGesture.
static void postGestureEvent(double dx, double dy, LivePhase phase, CGPoint loc) {
    // Bare event of raw type 29 (kCGEventGesture) with no backing source,
    // matching CGEvent(source: nil) in Swift.
    CGEventRef g = CGEventCreate(NULL);
    CGEventSetType(g, (CGEventType)29);
    CGEventSetLocation(g, loc);
    CGEventSetIntegerValueField(g, (CGEventField)110, 6);
    CGEventSetIntegerValueField(g, (CGEventField)132, phase);
    CGEventSetDoubleValueField(g, (CGEventField)116, dx);
    CGEventSetDoubleValueField(g, (CGEventField)119, dy);
    CGEventPost(kCGHIDEventTap, g);
    CFRelease(g);
}

static void postLiveScrollEvent(CGEventSourceRef source, double dx, double dy, LivePhase phase, CGPoint loc) {
    postGestureEvent(dx, dy, phase, loc);
    CGEventRef e = CGEventCreateScrollWheelEvent2(
        source, kCGScrollEventUnitPixel, 2, (int32_t)dy, (int32_t)dx, 0);
    CGEventSetLocation(e, loc);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, phase);
    setTrackpadDeltaFields(e, dx, dy);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void postMomentumEvent(CGEventSourceRef source, double dx, double dy, MomentumPhase phase, CGPoint loc) {
    CGEventRef e = CGEventCreateScrollWheelEvent2(
        source, kCGScrollEventUnitPixel, 2, (int32_t)dy, (int32_t)dx, 0);
    CGEventSetLocation(e, loc);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, 0);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventMomentumPhase, phase);
    setTrackpadDeltaFields(e, dx, dy);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

int main(int argc, char **argv) {
    int horizontal = 1;
    if (argc > 1 && strcmp(argv[1], "vertical") == 0) horizontal = 0;

    printf("Posting synthetic %s began->changed->ended->momentum scroll in 3 seconds — focus the target window now.\n",
           horizontal ? "horizontal" : "vertical");
    for (int i = 3; i > 0; i--) { printf("%d...\n", i); fflush(stdout); sleep(1); }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint loc = CGEventGetLocation(probe);
    CFRelease(probe);

    double peak = horizontal ? 8.0 : 0.0;
    double peakY = horizontal ? 0.0 : 8.0;

    // began: zero-delta bracket, matches PanScrollTracker.engage().
    postLiveScrollEvent(source, 0, 0, ScrollBegan, loc);
    usleep(16000);

    // changed: ~15 ticks of real per-frame delta, matches an actual pen-drag
    // pan long enough to accumulate a release velocity worth handing off to
    // momentum (PanScrollTracker.process()/recentVelocities).
    for (int i = 0; i < 15; i++) {
        postLiveScrollEvent(source, peak, peakY, ScrollChanged, loc);
        usleep(16000);
    }

    // ended: zero-delta bracket, matches PanScrollTracker.disengage(), posted
    // BEFORE the momentum tail starts — same order as InputInjector+CGEvents.
    postLiveScrollEvent(source, 0, 0, ScrollEnded, loc);

    // Momentum tail: begin at the release magnitude, decay tail, end.
    postMomentumEvent(source, peak * 5, peakY * 5, PhaseBegin, loc);
    usleep(16000);
    double dx = peak * 5, dy = peakY * 5;
    for (int i = 0; i < 40; i++) {
        dx *= 0.93;
        dy *= 0.93;
        if (dx < 0.5 && dy < 0.5) break;
        postMomentumEvent(source, dx, dy, PhaseContinue, loc);
        usleep(16000);
    }
    postMomentumEvent(source, 0, 0, PhaseEnd, loc);

    CFRelease(source);
    printf("Done.\n");
    return 0;
}
