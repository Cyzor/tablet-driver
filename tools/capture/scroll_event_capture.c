// scroll_event_capture.c — capture scroll-wheel CGEvents and dump every field
// relevant to how apps distinguish real-trackpad streams from synthetic ones.
//
// Usage:
//   clang -o scroll_event_capture scroll_event_capture.c \
//       -framework ApplicationServices -framework CoreFoundation
//   ./scroll_event_capture [seconds]
//
// Do a two-finger trackpad scroll, and separately a MockTab Scroll Drag pan,
// over the SAME failing app (e.g. Calendar Month view). Diff the two dumps.
//
// Requires Accessibility permission for whichever app runs it (Terminal).

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

static int64_t intField(CGEventRef e, CGEventField f) {
    return CGEventGetIntegerValueField(e, f);
}

static double dblField(CGEventRef e, CGEventField f) {
    return CGEventGetDoubleValueField(e, f);
}

// Gesture event types are not in the public CGEventTypes enum on all SDKs;
// define their stable values explicitly.
#ifndef kCGEventGesture
#define kCGEventGesture ((CGEventType)29)
#endif
#ifndef kCGEventMagnify
#define kCGEventMagnify ((CGEventType)30)
#endif
#ifndef kCGEventSwipe
#define kCGEventSwipe ((CGEventType)31)
#endif
#ifndef kCGEventRotate
#define kCGEventRotate ((CGEventType)32)
#endif

static const char *typeName(CGEventType t) {
    switch (t) {
        case kCGEventScrollWheel: return "scrollWheel";
        case kCGEventGesture:     return "gesture";
        case kCGEventSwipe:       return "swipe";
        case kCGEventMagnify:     return "magnify";
        case kCGEventRotate:      return "rotate";
        default:                  return "other";
    }
}

static CGEventRef callback(CGEventTapProxy proxy, CGEventType type,
                           CGEventRef event, void *userInfo) {
    if (type != kCGEventScrollWheel && type != kCGEventGesture &&
        type != kCGEventSwipe && type != kCGEventMagnify && type != kCGEventRotate) {
        return event;
    }

    CGPoint loc = CGEventGetLocation(event);
    CGEventSourceRef src = CGEventCreateSourceFromEvent(event);

    printf("=== %s t=%lld loc=(%.1f,%.1f) flags=0x%llx\n",
           typeName(type),
           (long long)CGEventGetTimestamp(event),
           loc.x, loc.y,
           (unsigned long long)CGEventGetFlags(event));

    if (type == kCGEventScrollWheel) {
        // The raw wheel fields CGEvent(scrollWheelEvent2Source:) populates.
        printf("  wheelAxis1=%d wheelAxis2=%d wheelAxis3=%d\n",
               (int)intField(event, kCGScrollWheelEventDeltaAxis1) /*placeholder, printed below via delta too*/,
               (int)intField(event, kCGScrollWheelEventDeltaAxis2),
               (int)intField(event, kCGScrollWheelEventDeltaAxis3));
        // The families that actually differentiate real vs synthetic.
        printf("  deltaAxis(1,2,3) = %lld, %lld, %lld\n",
               (long long)intField(event, kCGScrollWheelEventDeltaAxis1),
               (long long)intField(event, kCGScrollWheelEventDeltaAxis2),
               (long long)intField(event, kCGScrollWheelEventDeltaAxis3));
        printf("  fixedPtDeltaAxis(1,2) = %lld, %lld  (=%.3f, %.3f px)\n",
               (long long)intField(event, kCGScrollWheelEventFixedPtDeltaAxis1),
               (long long)intField(event, kCGScrollWheelEventFixedPtDeltaAxis2),
               intField(event, kCGScrollWheelEventFixedPtDeltaAxis1) / 65536.0,
               intField(event, kCGScrollWheelEventFixedPtDeltaAxis2) / 65536.0);
        printf("  pointDeltaAxis(1,2)  = %lld, %lld\n",
               (long long)intField(event, kCGScrollWheelEventPointDeltaAxis1),
               (long long)intField(event, kCGScrollWheelEventPointDeltaAxis2));
        printf("  isContinuous=%lld  scrollPhase=%lld  momentumPhase=%lld\n",
               (long long)intField(event, kCGScrollWheelEventIsContinuous),
               (long long)intField(event, kCGScrollWheelEventScrollPhase),
               (long long)intField(event, kCGScrollWheelEventMomentumPhase));
        printf("  scrollCount=%lld\n",
               (long long)intField(event, kCGScrollWheelEventScrollCount));
        // Whether the event came from the HID system vs a synthetic source.
        if (src) {
            CGEventSourceStateID sid = CGEventSourceGetSourceStateID(src);
            const char *sidName = sid == kCGEventSourceStateHIDSystemState ? "HIDSystem"
                                : sid == kCGEventSourceStatePrivate ? "private"
                                : "combinedSession";
            printf("  source: stateID=%d (%s)\n", (int)sid, sidName);
            CFRelease(src);
        }
    }
    fflush(stdout);
    return event;
}

int main(int argc, char **argv) {
    double seconds = (argc > 1) ? atof(argv[1]) : 20.0;

    CGEventMask mask =
        CGEventMaskBit(kCGEventScrollWheel) |
        CGEventMaskBit(kCGEventGesture) |
        CGEventMaskBit(kCGEventSwipe) |
        CGEventMaskBit(kCGEventMagnify) |
        CGEventMaskBit(kCGEventRotate);

    CFMachPortRef tap = CGEventTapCreate(
        kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
        mask, callback, NULL);
    if (!tap) {
        fprintf(stderr, "Failed to create event tap — grant Accessibility permission.\n");
        return 1;
    }

    CFRunLoopSourceRef src =
        CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    printf("Capturing scroll events for %.0f s. Do a real trackpad scroll and a "
           "MockTab Scroll Drag over the SAME target app.\n", seconds);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    return 0;
}
