// virtual_digitizer_spike.c — proof-of-concept for the IOHIDUserDevice escape hatch.
//
// Creates a virtual HID pen digitizer in userspace and streams a scripted
// stroke through it, while a listen-only CGEvent tap in the same process
// records what the system makes of those reports. Answers, without any
// hardware attached:
//
//   1. Can this process create an IOHIDUserDevice at all?
//      (Needs root or the com.apple.developer.hid.virtual.device entitlement.)
//   2. Does the system pointer track the virtual pen's absolute X/Y?
//   3. Do the resulting events carry tablet semantics — pressure, tilt,
//      tablet subtype / kCGEventTabletPointer — or arrive as plain mouse?
//
// This is the fallback path if a future macOS restricts CGEventPost: pen
// input would enter the HID stack as a real digitizer instead of synthesized
// events. See Notes/Scratch/Virtual-digitizer-spike-2026-07-16.md.
//
// Build:  clang -O2 -o virtual_digitizer_spike virtual_digitizer_spike.c \
//             -framework IOKit -framework CoreFoundation -framework ApplicationServices
// Run:    sudo ./virtual_digitizer_spike [--seconds N] [--no-touch] [--observe-only]
//
//   --seconds N      stroke duration (default 6)
//   --no-touch       hover only: in-range sweep with tip up, zero pressure
//   --observe-only   just run the event tap (Ctrl-C to stop); no virtual device

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Report descriptor: a minimal but honest pen. One 9-byte input report,
// no report ID: [flags][X lo][X hi][Y lo][Y hi][P lo][P hi][tiltX][tiltY]
// flags bit 0 tip, 1 barrel, 2 invert, 3 eraser, 4 in-range.
// ---------------------------------------------------------------------------

#define LOGICAL_MAX   32767
#define PRESSURE_MAX  8191

static const uint8_t kReportDescriptor[] = {
    0x05, 0x0D,        // Usage Page (Digitizers)
    0x09, 0x02,        // Usage (Pen)
    0xA1, 0x01,        // Collection (Application)
    0x09, 0x20,        //   Usage (Stylus)
    0xA1, 0x00,        //   Collection (Physical)
    0x09, 0x42,        //     Usage (Tip Switch)
    0x09, 0x44,        //     Usage (Barrel Switch)
    0x09, 0x3C,        //     Usage (Invert)
    0x09, 0x45,        //     Usage (Eraser)
    0x09, 0x32,        //     Usage (In Range)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x75, 0x01,        //     Report Size (1)
    0x95, 0x05,        //     Report Count (5)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x75, 0x03,        //     Report Size (3)
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x03,        //     Input (Const)          — pad to a byte
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x15, 0x00,        //     Logical Minimum (0)
    0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
    0x75, 0x10,        //     Report Size (16)
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x09, 0x31,        //     Usage (Y)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x05, 0x0D,        //     Usage Page (Digitizers)
    0x09, 0x30,        //     Usage (Tip Pressure)
    0x26, 0xFF, 0x1F,  //     Logical Maximum (8191)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x09, 0x3D,        //     Usage (X Tilt)
    0x15, 0xC4,        //     Logical Minimum (-60)
    0x25, 0x3C,        //     Logical Maximum (60)
    0x75, 0x08,        //     Report Size (8)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0x09, 0x3E,        //     Usage (Y Tilt)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    0xC0,              //   End Collection
    0xC0,              // End Collection
};

// ---------------------------------------------------------------------------
// Event-tap side: count what the system produces while we drive the pen.
// ---------------------------------------------------------------------------

static _Atomic long gMoveEvents        = 0;  // mouseMoved / mouseDragged
static _Atomic long gTabletSubtype     = 0;  // ...of those, with tablet subtype
static _Atomic long gTabletPointer     = 0;  // kCGEventTabletPointer
static _Atomic long gTabletProximity   = 0;  // kCGEventTabletProximity
static _Atomic long gClicks            = 0;  // left down/up
static double gMaxPressure = 0;              // worst-case data race is benign here
static double gMinX = 1e9, gMaxX = -1e9, gMinY = 1e9, gMaxY = -1e9;
static int8_t gSeenTiltX = 0, gSeenTiltY = 0;

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type,
                              CGEventRef event, void *info) {
    switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged: {
        atomic_fetch_add(&gMoveEvents, 1);
        int64_t subtype = CGEventGetIntegerValueField(event, kCGMouseEventSubtype);
        if (subtype == 1 /* tablet point */) atomic_fetch_add(&gTabletSubtype, 1);
        CGPoint p = CGEventGetLocation(event);
        if (p.x < gMinX) gMinX = p.x;
        if (p.x > gMaxX) gMaxX = p.x;
        if (p.y < gMinY) gMinY = p.y;
        if (p.y > gMaxY) gMaxY = p.y;
        double pr = CGEventGetDoubleValueField(event, kCGTabletEventPointPressure);
        if (pr > gMaxPressure) gMaxPressure = pr;
        break;
    }
    case kCGEventLeftMouseDown:
    case kCGEventLeftMouseUp: {
        atomic_fetch_add(&gClicks, 1);
        double pr = CGEventGetDoubleValueField(event, kCGTabletEventPointPressure);
        if (pr > gMaxPressure) gMaxPressure = pr;
        break;
    }
    case kCGEventTabletPointer: {
        atomic_fetch_add(&gTabletPointer, 1);
        double pr = CGEventGetDoubleValueField(event, kCGTabletEventPointPressure);
        if (pr > gMaxPressure) gMaxPressure = pr;
        int64_t tx = CGEventGetIntegerValueField(event, kCGTabletEventTiltX);
        int64_t ty = CGEventGetIntegerValueField(event, kCGTabletEventTiltY);
        if (tx != 0) gSeenTiltX = 1;
        if (ty != 0) gSeenTiltY = 1;
        break;
    }
    case kCGEventTabletProximity:
        atomic_fetch_add(&gTabletProximity, 1);
        break;
    default:
        break;
    }
    return event;  // listen-only tap; return value ignored
}

static CFMachPortRef startTap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved)
                     | CGEventMaskBit(kCGEventLeftMouseDragged)
                     | CGEventMaskBit(kCGEventLeftMouseDown)
                     | CGEventMaskBit(kCGEventLeftMouseUp)
                     | CGEventMaskBit(kCGEventTabletPointer)
                     | CGEventMaskBit(kCGEventTabletProximity);
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                         kCGEventTapOptionListenOnly, mask,
                                         tapCallback, NULL);
    if (!tap) {
        fprintf(stderr, "warning: could not create event tap (need root or "
                        "Input Monitoring); running blind — watch the cursor.\n");
        return NULL;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(tap, true);
    return tap;
}

// ---------------------------------------------------------------------------
// Virtual device side.
// ---------------------------------------------------------------------------

static void dictSetInt(CFMutableDictionaryRef d, CFStringRef key, int64_t value) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFDictionarySetValue(d, key, n);
    CFRelease(n);
}

static IOHIDUserDeviceRef createVirtualPen(void) {
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef desc = CFDataCreate(NULL, kReportDescriptor, sizeof(kReportDescriptor));
    CFDictionarySetValue(props, CFSTR(kIOHIDReportDescriptorKey), desc);
    CFRelease(desc);
    dictSetInt(props, CFSTR(kIOHIDVendorIDKey), 0x4D54);   // "MT"
    dictSetInt(props, CFSTR(kIOHIDProductIDKey), 0x0001);
    dictSetInt(props, CFSTR(kIOHIDVersionNumberKey), 1);
    CFDictionarySetValue(props, CFSTR(kIOHIDManufacturerKey), CFSTR("MockTab"));
    CFDictionarySetValue(props, CFSTR(kIOHIDProductKey), CFSTR("MockTab Virtual Pen"));
    CFDictionarySetValue(props, CFSTR(kIOHIDTransportKey), CFSTR("Virtual"));

    IOHIDUserDeviceRef dev = IOHIDUserDeviceCreateWithProperties(NULL, props, 0);
    CFRelease(props);
    return dev;
}

struct penState {
    int tip, barrel, invert, eraser, inRange;
    int x, y, pressure;     // logical units
    int tiltX, tiltY;       // degrees
};

static IOReturn sendReport(IOHIDUserDeviceRef dev, const struct penState *s) {
    uint8_t r[9];
    r[0] = (uint8_t)((s->tip & 1) | (s->barrel & 1) << 1 | (s->invert & 1) << 2 |
                     (s->eraser & 1) << 3 | (s->inRange & 1) << 4);
    r[1] = (uint8_t)(s->x & 0xFF);
    r[2] = (uint8_t)((s->x >> 8) & 0xFF);
    r[3] = (uint8_t)(s->y & 0xFF);
    r[4] = (uint8_t)((s->y >> 8) & 0xFF);
    r[5] = (uint8_t)(s->pressure & 0xFF);
    r[6] = (uint8_t)((s->pressure >> 8) & 0xFF);
    r[7] = (uint8_t)(int8_t)s->tiltX;
    r[8] = (uint8_t)(int8_t)s->tiltY;
    return IOHIDUserDeviceHandleReportWithTimeStamp(dev, mach_absolute_time(),
                                                    r, sizeof(r));
}

// ---------------------------------------------------------------------------
// Scripted stroke, run off the main runloop (which services the tap).
// ---------------------------------------------------------------------------

struct strokeArgs {
    IOHIDUserDeviceRef dev;
    double seconds;
    int touch;  // 0 = hover only
};

static void *strokeThread(void *arg) {
    struct strokeArgs *a = arg;
    struct penState s = {0};
    IOReturn kr;

    sleep(2);  // let the HID stack enumerate the new device
    fprintf(stderr, "[stroke] pen entering range\n");
    s.inRange = 1;
    s.x = LOGICAL_MAX / 5;
    s.y = LOGICAL_MAX / 5;
    s.tiltX = 20;
    s.tiltY = -15;
    kr = sendReport(a->dev, &s);
    if (kr != kIOReturnSuccess)
        fprintf(stderr, "[stroke] HandleReport failed: 0x%x\n", kr);
    usleep(300000);

    // Diagonal there-and-back at ~200 Hz with a triangular pressure ramp.
    const double hz = 200.0;
    const long steps = (long)(a->seconds * hz);
    const int lo = LOGICAL_MAX / 5, hi = LOGICAL_MAX * 4 / 5;
    if (a->touch) fprintf(stderr, "[stroke] tip down, sweeping with pressure ramp\n");
    else          fprintf(stderr, "[stroke] hovering, sweeping with tip up\n");
    long errors = 0;
    for (long i = 0; i < steps; i++) {
        double phase = (double)i / (double)steps;          // 0..1 overall
        double leg = phase < 0.5 ? phase * 2 : 2 - phase * 2;  // 0..1..0
        s.x = lo + (int)((hi - lo) * leg);
        s.y = lo + (int)((hi - lo) * leg);
        if (a->touch) {
            double ramp = phase < 0.5 ? phase * 2 : 2 - phase * 2;
            s.pressure = (int)(PRESSURE_MAX * ramp);
            s.tip = s.pressure > 0;
        }
        if (sendReport(a->dev, &s) != kIOReturnSuccess) errors++;
        usleep((useconds_t)(1000000.0 / hz));
    }
    if (errors) fprintf(stderr, "[stroke] %ld of %ld reports failed\n", errors, steps);

    fprintf(stderr, "[stroke] pen leaving range\n");
    s.tip = 0;
    s.pressure = 0;
    sendReport(a->dev, &s);
    usleep(100000);
    s.inRange = 0;
    sendReport(a->dev, &s);
    sleep(1);  // let trailing events reach the tap

    CFRunLoopStop(CFRunLoopGetMain());
    return NULL;
}

// ---------------------------------------------------------------------------

int main(int argc, char **argv) {
    double seconds = 6;
    int touch = 1, observeOnly = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--no-touch")) touch = 0;
        else if (!strcmp(argv[i], "--observe-only")) observeOnly = 1;
        else { fprintf(stderr, "usage: %s [--seconds N] [--no-touch] [--observe-only]\n", argv[0]); return 2; }
    }

    CFMachPortRef tap = startTap();

    IOHIDUserDeviceRef dev = NULL;
    pthread_t thread;
    if (!observeOnly) {
        dev = createVirtualPen();
        if (!dev) {
            fprintf(stderr,
                "error: IOHIDUserDeviceCreateWithProperties returned NULL.\n"
                "       This call needs root or the com.apple.developer.hid.virtual.device\n"
                "       entitlement. Re-run with sudo.\n");
            return 1;
        }
        fprintf(stderr, "[device] virtual pen created — check: ioreg -p IOService -n 'MockTab Virtual Pen'\n");
        struct strokeArgs args = { dev, seconds, touch };
        pthread_create(&thread, NULL, strokeThread, &args);
    } else {
        fprintf(stderr, "[observe] tap running; Ctrl-C to stop\n");
    }

    CFRunLoopRun();

    if (!observeOnly) pthread_join(thread, NULL);
    if (dev) CFRelease(dev);

    if (tap) {
        fprintf(stderr, "\n=== what the system made of the virtual pen ===\n");
        fprintf(stderr, "pointer move/drag events : %ld\n", gMoveEvents);
        fprintf(stderr, "  with tablet subtype    : %ld\n", gTabletSubtype);
        fprintf(stderr, "tabletPointer events     : %ld\n", gTabletPointer);
        fprintf(stderr, "tabletProximity events   : %ld\n", gTabletProximity);
        fprintf(stderr, "click events (down/up)   : %ld\n", gClicks);
        fprintf(stderr, "max pressure observed    : %.3f  (expect ~1.0 on the ramp peak)\n", gMaxPressure);
        fprintf(stderr, "tilt seen (x/y)          : %s / %s\n",
                gSeenTiltX ? "yes" : "no", gSeenTiltY ? "yes" : "no");
        if (gMoveEvents > 0)
            fprintf(stderr, "pointer travel           : x %.0f–%.0f, y %.0f–%.0f\n",
                    gMinX, gMaxX, gMinY, gMaxY);
        fprintf(stderr, "\nverdict: ");
        if (gMoveEvents == 0 && gTabletPointer == 0)
            fprintf(stderr, "the HID stack produced NO pointer events — descriptor not "
                            "adopted by the system event driver.\n");
        else if (gMaxPressure > 0.05 && (gTabletSubtype > 0 || gTabletPointer > 0))
            fprintf(stderr, "full tablet semantics — pressure flows natively. "
                            "The escape hatch is real.\n");
        else
            fprintf(stderr, "pointer moves but WITHOUT tablet semantics — pen arrives "
                            "as a plain mouse. Descriptor iteration needed.\n");
    }
    return 0;
}
