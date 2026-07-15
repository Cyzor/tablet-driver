/*
 * driver_latency_probe.c — measures raw-HID-report -> system-pointer-event
 * latency for whichever driver currently owns the tablet, MockTab or the
 * vendor's own app. Run once per driver (quit the other one first) and
 * diff the two logs.
 *
 * Two clocks feed one correlation:
 *   1. IOHIDDeviceRegisterInputReportWithTimeStampCallback gives the kernel
 *      receipt time of each raw report straight off the wire (mach_absolute_time
 *      domain), independent of which driver is running — this tool opens the
 *      device non-exclusively, same as tools/hid_input_capture.c, so it can
 *      listen alongside Wacom Desktop Center or Xencelabs Driver Hub without
 *      taking the device away from them.
 *   2. A CGEventTap on mouse-moved/dragged events timestamps the first
 *      system-visible pointer event that lands after each report, using the
 *      same mach_absolute_time domain CGEventGetTimestamp reports in.
 *
 * The delta between (1) and the next (2) is everything the running driver's
 * pipeline cost: decode, event injection, and whatever queuing happens in
 * between. It does NOT include the device's own USB/BT polling interval
 * (that's baked into how often (1) fires at all) or anything downstream of
 * event injection (compositor, app redraw, display refresh) — this measures
 * the one segment that's actually under a driver's control.
 *
 * Build:
 *   clang -framework IOKit -framework CoreFoundation -framework ApplicationServices \
 *         tools/driver_latency_probe.c -o /tmp/driver_latency_probe
 *
 * Run (needs Accessibility/Input Monitoring granted to the terminal, same as
 * any CGEventTap consumer):
 *   /tmp/driver_latency_probe <vid-hex> <pid-hex>
 *   e.g. /tmp/driver_latency_probe 28bd 0914
 *
 * Procedure for an A/B comparison:
 *   1. Quit MockTab. Leave the vendor driver running. Run this tool, draw a
 *      few seconds of continuous pen strokes, Ctrl-C.
 *   2. Quit the vendor driver. Launch MockTab. Run this tool again, same
 *      strokes as best you can reproduce, Ctrl-C.
 *   3. Compare the printed p50/p90/max — see tools/latency_report.py (or just
 *      eyeball the per-report lines) for the two runs.
 *
 * Only one driver should be moving the pointer at a time, or the tap can't
 * tell which driver produced a given CGEvent — that's why this is an A/B
 * protocol, not a live head-to-head.
 */

#include <IOKit/hid/IOHIDLib.h>
#include <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static mach_timebase_info_data_t g_timebase;
static uint64_t g_last_report_ts = 0;
static int g_have_pending_report = 0;
static uint64_t g_report_count = 0;
static uint64_t g_matched_count = 0;

static double mach_to_ms(uint64_t ticks)
{
    return (double)ticks * g_timebase.numer / g_timebase.denom / 1e6;
}

static void report_cb(void *ctx, IOReturn result, void *sender,
                       IOHIDReportType type, uint32_t report_id,
                       uint8_t *report, CFIndex length, uint64_t timestamp)
{
    if (type != kIOHIDReportTypeInput) return;
    g_last_report_ts = timestamp;
    g_have_pending_report = 1;
    g_report_count++;
}

static void device_matched(void *ctx, IOReturn result, void *sender,
                            IOHIDDeviceRef device)
{
    char name[256] = "(unknown)";
    CFStringRef prop = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (prop) CFStringGetCString(prop, name, sizeof(name), kCFStringEncodingUTF8);
    printf("[matched] %s — registering timestamped report callback\n", name);
    fflush(stdout);

    static uint8_t buf[512];
    IOHIDDeviceRegisterInputReportWithTimeStampCallback(
        device, buf, (CFIndex)sizeof(buf), report_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess)
        printf("[warn] IOHIDDeviceOpen returned 0x%x for %s\n", r, name);
}

static CGEventRef tap_cb(CGEventTapProxy proxy, CGEventType type,
                          CGEventRef event, void *ctx)
{
    if (g_have_pending_report &&
        (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged)) {
        uint64_t event_ts_ns = CGEventGetTimestamp(event); /* already nanoseconds */
        uint64_t report_ts_ns = (uint64_t)(mach_to_ms(g_last_report_ts) * 1e6);
        double delta_ms = (double)(event_ts_ns > report_ts_ns
                                        ? event_ts_ns - report_ts_ns
                                        : 0) / 1e6;
        printf("report->pointer-event latency: %.2f ms\n", delta_ms);
        fflush(stdout);
        g_have_pending_report = 0;
        g_matched_count++;
    }
    return event;
}

static void heartbeat_cb(CFRunLoopTimerRef timer, void *ctx)
{
    fprintf(stderr,
        "[heartbeat] %llu HID reports seen, %llu matched to a pointer event so far. "
        "If reports stays at 0, the device match (VID/PID) is wrong or the driver "
        "isn't running. If reports grows but matched stays 0, this process cannot "
        "see system pointer events — check Input Monitoring / Accessibility for "
        "this exact terminal app in System Settings.\n",
        (unsigned long long)g_report_count, (unsigned long long)g_matched_count);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <vid-hex> <pid-hex>\n", argv[0]);
        return 1;
    }
    mach_timebase_info(&g_timebase);

    int vid = (int)strtol(argv[1], NULL, 16);
    int pid = (int)strtol(argv[2], NULL, 16);

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef n_vid = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef n_pid = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), n_vid);
    CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), n_pid);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, device_matched, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen failed: 0x%x\n", r);
        return 1;
    }

    if (!CGPreflightListenEventAccess()) {
        fprintf(stderr,
            "[warn] this process is not yet approved for Input Monitoring — macOS "
            "should show a permission prompt now. If it doesn't (common when running "
            "a rebuilt /tmp binary that already got silently denied once), open "
            "System Settings > Privacy & Security > Input Monitoring, remove any "
            "stale entry for this tool, then run it again.\n");
        CGRequestListenEventAccess();
    }

    CFMachPortRef tap = CGEventTapCreate(
        kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDragged),
        tap_cb, NULL);
    if (!tap) {
        fprintf(stderr, "CGEventTapCreate failed outright — grant Input Monitoring/"
                         "Accessibility to this terminal in System Settings and retry.\n");
        return 1;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    CFRunLoopTimerRef hb = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0, heartbeat_cb, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), hb, kCFRunLoopCommonModes);

    printf("Listening on VID=0x%04x PID=0x%04x. Draw with the pen now, whichever "
           "driver is currently running owns the numbers you'll see. Status lines "
           "print every 5s on stderr. Ctrl-C to stop.\n",
           vid, pid);
    CFRunLoopRun();
    return 0;
}
