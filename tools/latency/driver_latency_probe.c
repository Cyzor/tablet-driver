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
 *      device non-exclusively, same as tools/capture/hid_input_capture.c, so it can
 *      listen alongside Wacom Desktop Center or Xencelabs Driver Hub without
 *      taking the device away from them.
 *   2. A CGEventTap on mouse-moved/dragged events notes when each pointer
 *      event reaches the session, on the same clock.
 *
 * The event's own timestamp can't stand in for (2): MockTab stamps each event
 * with its report's receipt time, so apps see when the pen moved, and Wacom's
 * driver stamps a nominal clock. Arrival is what the driver can't fake.
 *
 * Each pointer event yields up to two numbers:
 *   - latency: the first event after a report, against that report. Works for
 *     any driver; use it for A/B comparisons.
 *   - exact: the event's stamp matches a report this tool also saw, so the
 *     pairing is certain. Only drivers that stamp receipt time produce it
 *     (MockTab, except Bluetooth samples it paces, which carry their
 *     scheduled time).
 *
 * Either one is everything the running driver's pipeline cost: decode, event
 * injection, and whatever queuing happens in between. It does NOT include the
 * device's own USB/BT polling interval (that's baked into how often (1) fires
 * at all) or anything downstream of the session (compositor, app redraw,
 * display refresh) — this measures the one segment that's actually under a
 * driver's control. Logs from before arrival timing (2026-10-09) measured the
 * stamp instead, and read near zero for MockTab.
 *
 * Build:
 *   clang -framework IOKit -framework CoreFoundation -framework ApplicationServices \
 *         tools/latency/driver_latency_probe.c -o /tmp/driver_latency_probe
 *
 * Run (needs Accessibility/Input Monitoring granted to the terminal, same as
 * any CGEventTap consumer):
 *   /tmp/driver_latency_probe <vid-hex> <pid-hex> [seconds]
 *   e.g. /tmp/driver_latency_probe 28bd 0914
 *
 * Procedure for an A/B comparison:
 *   1. Quit MockTab. Leave the vendor driver running. Run this tool, draw a
 *      few seconds of continuous pen strokes, Ctrl-C.
 *   2. Quit the vendor driver. Launch MockTab. Run this tool again, same
 *      strokes as best you can reproduce, Ctrl-C.
 *   3. Compare the printed p50/p90/max — see tools/latency/latency_summary.py (or just
 *      eyeball the per-report lines) for the two runs.
 *
 * Only one driver should be moving the pointer at a time, or the tap can't
 * tell which driver produced a given CGEvent — that's why this is an A/B
 * protocol, not a live head-to-head.
 */

#include <IOKit/hid/IOHIDLib.h>
#include <ApplicationServices/ApplicationServices.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static mach_timebase_info_data_t g_timebase;
static uint64_t g_last_report_ns = 0;
static int g_have_pending_report = 0;
static uint64_t g_report_count = 0;
static uint64_t g_matched_count = 0;
static uint64_t g_exact_count = 0;

/* Receipt times of recent reports, for matching an event's stamp. Reports
   arrive milliseconds apart, so 50 µs of slack can't match the wrong one;
   it absorbs MockTab's floating-point tick conversion. */
#define RECENT_REPORTS 64
#define STAMP_SLACK_NS 50000
static uint64_t g_recent_ns[RECENT_REPORTS];
static unsigned g_recent_next = 0;

static uint64_t ticks_to_ns(uint64_t ticks)
{
    return ticks * g_timebase.numer / g_timebase.denom;
}

static uint64_t receipt_matching(uint64_t stamp_ns)
{
    for (unsigned i = 0; i < RECENT_REPORTS; i++) {
        uint64_t r = g_recent_ns[i];
        if (r == 0) continue;
        uint64_t d = r > stamp_ns ? r - stamp_ns : stamp_ns - r;
        if (d <= STAMP_SLACK_NS) return r;
    }
    return 0;
}

static void report_cb(void *ctx, IOReturn result, void *sender,
                       IOHIDReportType type, uint32_t report_id,
                       uint8_t *report, CFIndex length, uint64_t timestamp)
{
    if (type != kIOHIDReportTypeInput) return;
    g_last_report_ns = ticks_to_ns(timestamp);
    g_recent_ns[g_recent_next++ % RECENT_REPORTS] = g_last_report_ns;
    g_have_pending_report = 1;
    g_report_count++;
}

/* Reads this device's VID/PID so every capture names the hardware it came
   from. A filename or a remembered PID is not evidence: two tablets in one
   session, or a file passed along later, both lose that context. Printed in
   the same `[matched] <name>  vid=… pid=…` shape the other capture tools
   use, which tools/capture/touch_speed_summarize.py already parses. */
static void print_matched(IOHIDDeviceRef device, const char *name, const char *suffix)
{
    long vid = 0, pid = 0;
    CFNumberRef nvid = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    CFNumberRef npid = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    if (nvid) CFNumberGetValue(nvid, kCFNumberLongType, &vid);
    if (npid) CFNumberGetValue(npid, kCFNumberLongType, &pid);
    printf("[matched] %s  vid=0x%04lx pid=0x%04lx — %s\n", name, vid, pid, suffix);
}

static void device_matched(void *ctx, IOReturn result, void *sender,
                            IOHIDDeviceRef device)
{
    char name[256] = "(unknown)";
    CFStringRef prop = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (prop) CFStringGetCString(prop, name, sizeof(name), kCFStringEncodingUTF8);
    print_matched(device, name, "registering timestamped report callback");
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
    if (type != kCGEventMouseMoved && type != kCGEventLeftMouseDragged) return event;
    /* CGEventGetTimestamp is nanoseconds on mach_absolute_time's clock, which
     * CLOCK_UPTIME_RAW also reads. Only the HID report stamp is in raw ticks. */
    uint64_t arrival_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t receipt_ns = receipt_matching(CGEventGetTimestamp(event));

    char line[128];
    int n = 0;
    if (g_have_pending_report && arrival_ns > g_last_report_ns) {
        n += snprintf(line + n, sizeof(line) - n, "report->pointer-event latency: %.2f ms",
                      (arrival_ns - g_last_report_ns) / 1e6);
        g_have_pending_report = 0;
        g_matched_count++;
    }
    if (receipt_ns && arrival_ns > receipt_ns) {
        n += snprintf(line + n, sizeof(line) - n, "%sexact: %.2f ms",
                      n ? "  " : "", (arrival_ns - receipt_ns) / 1e6);
        g_exact_count++;
    }
    if (n) {
        puts(line);
        fflush(stdout);
    }
    return event;
}

static void heartbeat_cb(CFRunLoopTimerRef timer, void *ctx)
{
    fprintf(stderr,
        "[heartbeat] %llu HID reports seen, %llu matched to a pointer event so far "
        "(%llu exact). If reports stays at 0, the device match (VID/PID) is wrong or "
        "the driver isn't running. If reports grows but matched stays 0, this process "
        "cannot see system pointer events — check Input Monitoring / Accessibility for "
        "this exact terminal app in System Settings.\n",
        (unsigned long long)g_report_count, (unsigned long long)g_matched_count,
        (unsigned long long)g_exact_count);
}

/* Same real-time policy as MockTab's input thread, so under CPU load the
   numbers measure the driver, not this tool waiting for a core. */
static void promote_to_time_constraint(void)
{
    double ticks_per_ms = 1e6 * g_timebase.denom / g_timebase.numer;
    thread_time_constraint_policy_data_t policy = {
        .period = (uint32_t)(7.5 * ticks_per_ms),
        .computation = (uint32_t)(0.5 * ticks_per_ms),
        .constraint = (uint32_t)(2.0 * ticks_per_ms),
        .preemptible = 1,
    };
    kern_return_t kr = thread_policy_set(
        mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY,
        (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (kr != KERN_SUCCESS)
        fprintf(stderr, "[warn] time-constraint policy refused (%d); numbers under load "
                        "include this tool's own scheduling\n", kr);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <vid-hex> <pid-hex> [seconds]\n", argv[0]);
        return 1;
    }
    mach_timebase_info(&g_timebase);
    promote_to_time_constraint();

    int vid = (int)strtol(argv[1], NULL, 16);
    int pid = (int)strtol(argv[2], NULL, 16);
    double seconds = argc > 3 ? atof(argv[3]) : 0;

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
           "print every 5s on stderr. %s\n",
           vid, pid, seconds > 0 ? "Stops by itself." : "Ctrl-C to stop.");
    fflush(stdout);
    if (seconds > 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    else
        CFRunLoopRun();
    return 0;
}
