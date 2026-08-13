/*
 * xencelabs_flicker_capture.c — barrel-button / proximity flicker timing.
 *
 * Companion to hid_input_capture.c, specialized for one question: when a
 * Xencelabs pen rides its button-sensing boundary during a loosely-held
 * pan, do the button bits drop out as many short blips or occasional long
 * ones? The answer decides what up-debounce window the driver can afford
 * (see InputInjector.buttonUpDebounceInterval).
 *
 * Decodes Report ID 2 tag bytes only (see XencelabsDecoder.swift for the
 * full layout) and logs every transition of tip / barrel 1-3 / eraser /
 * proximity with a monotonic ms timestamp and, on each release edge and
 * reassert edge, how long the previous state lasted. Frames that aren't
 * live pen data (aux 0xF0, battery 0xF2, config echoes 0xB_) are skipped
 * with the same gating the driver uses.
 *
 * At exit (Ctrl-C) prints a histogram of "released" gap durations per
 * button — the distribution that matters: if gaps cluster well under the
 * current 150 ms window, the window can shrink; if they spread up to and
 * past it, flicker and deliberate release genuinely overlap.
 *
 * Build:
 *   clang -framework IOKit -framework CoreFoundation \
 *         tools/capture/xencelabs_flicker_capture.c -o /tmp/xencelabs_flicker_capture
 *
 * Run (defaults to VID 28bd, any PID):
 *   /tmp/xencelabs_flicker_capture [pid-hex]
 *
 * Suggested protocol: hold a barrel button and sweep loose, tilted pans at
 * increasing hover height until the click audibly flickers in whatever app
 * shows it; also do ~20 deliberate press/release cycles for contrast.
 */

#include <IOKit/hid/IOHIDLib.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define XENCELABS_VID 0x28BD
#define TAG_OUT_OF_RANGE 0xC0

static mach_timebase_info_data_t timebase;
static uint64_t start_ticks;

/* Tracked bits: tip, barrel-low (3-button pen), barrel1, barrel2, eraser,
 * plus proximity as a derived signal. */
typedef struct {
    const char *name;
    uint8_t mask;          /* bit in the tag byte; 0 for proximity */
    int down;
    double edge_ms;        /* time of the last transition */
    /* Gap histogram: durations of "released" intervals that ended in a
     * reassert (flicker) vs total release count. Buckets in ms. */
    int gap_counts[7];     /* <20, <40, <80, <150, <300, <1000, >=1000 */
    int releases;
    int reasserts;
    double max_flicker_gap;
} BitTrack;

static BitTrack tracks[] = {
    { "tip",     0x01 }, { "barrelLo", 0x02 }, { "barrel1", 0x04 },
    { "barrel2", 0x08 }, { "eraser",   0x40 }, { "prox",    0x00 },
};
enum { N_TRACKS = sizeof(tracks) / sizeof(tracks[0]), PROX_IDX = N_TRACKS - 1 };

static double now_ms(void)
{
    uint64_t elapsed = mach_absolute_time() - start_ticks;
    return (double)elapsed * timebase.numer / timebase.denom / 1e6;
}

static void bucket_gap(BitTrack *t, double gap_ms)
{
    static const double edges[] = { 20, 40, 80, 150, 300, 1000 };
    int i;
    for (i = 0; i < 6 && gap_ms >= edges[i]; i++) {}
    t->gap_counts[i]++;
    if (gap_ms > t->max_flicker_gap) t->max_flicker_gap = gap_ms;
}

/* Pen pose at the frame carrying the transition — tilt is the current
 * suspect for what drives dropouts (tilting the pen may carry the button
 * sensor out of its shorter range while position tracking holds on), so
 * every edge logs it. Tilt bytes are signed degrees, ±60 spec'd max. */
static int cur_tilt_x, cur_tilt_y, cur_pressure;

static void transition(int idx, int down, double t)
{
    BitTrack *tr = &tracks[idx];
    if (down == tr->down) return;
    double held = t - tr->edge_ms;
    if (down) {
        /* Reassert: the gap just ended — this is the flicker duration. */
        tr->reasserts++;
        bucket_gap(tr, held);
        printf("%10.1f  %-8s DOWN  (gap %7.1f ms)  tilt %+3d/%+3d  p %4d\n",
               t, tr->name, held, cur_tilt_x, cur_tilt_y, cur_pressure);
    } else {
        tr->releases++;
        printf("%10.1f  %-8s up    (held %7.1f ms)  tilt %+3d/%+3d  p %4d\n",
               t, tr->name, held, cur_tilt_x, cur_tilt_y, cur_pressure);
    }
    tr->down = down;
    tr->edge_ms = t;
    fflush(stdout);
}

static void report_cb(void *ctx, IOReturn result, void *sender,
                      IOHIDReportType type, uint32_t report_id,
                      uint8_t *report, CFIndex length)
{
    if (type != kIOHIDReportTypeInput || report_id != 0x02 || length < 2) return;
    uint8_t tag = report[1];
    /* Same non-pen-frame gating as XencelabsDecoder: config echoes and
     * aux/battery/dongle-status frames aren't pen state. */
    if ((tag & 0xF0) == 0xB0) return;
    if (tag & 0x10) return;

    double t = now_ms();
    if (tag == TAG_OUT_OF_RANGE) {
        /* Out of range: proximity down; button bits are unknowable, leave
         * them as-is so a post-return reassert still measures the gap the
         * driver would actually experience. Tilt/pressure aren't updated
         * either — the logged line shows the last in-range pose, i.e. the
         * pose the pen dropped out at, which is the datum of interest. */
        transition(PROX_IDX, 0, t);
        return;
    }
    if (length >= 10) {
        cur_tilt_x = (int8_t)report[8];
        cur_tilt_y = (int8_t)report[9];
        cur_pressure = report[6] | report[7] << 8;
    }
    transition(PROX_IDX, 1, t);
    for (int i = 0; i < PROX_IDX; i++)
        transition(i, (tag & tracks[i].mask) != 0, t);
}

static void print_summary(int sig)
{
    static const char *labels[] =
        { "<20ms", "20-40", "40-80", "80-150", "150-300", "300-1s", ">=1s" };
    printf("\n=== released-gap histogram (gaps that ended in a reassert) ===\n");
    printf("%-8s %8s %8s", "bit", "ups", "reasserts");
    for (int b = 0; b < 7; b++) printf(" %8s", labels[b]);
    printf(" %10s\n", "max gap");
    for (int i = 0; i < N_TRACKS; i++) {
        BitTrack *t = &tracks[i];
        if (!t->releases && !t->reasserts) continue;
        printf("%-8s %8d %8d", t->name, t->releases, t->reasserts);
        for (int b = 0; b < 7; b++) printf(" %8d", t->gap_counts[b]);
        printf(" %9.1fms\n", t->max_flicker_gap);
    }
    printf("\nReading it: a gap that ended in a reassert is a flicker the "
           "driver must absorb;\na final release never reasserts, so it "
           "appears in 'ups' but no gap bucket.\nIf flicker gaps sit left of "
           "a bucket edge, that's a safe up-debounce window.\n");
    exit(0);
}

int main(int argc, char **argv)
{
    mach_timebase_info(&timebase);
    start_ticks = mach_absolute_time();
    signal(SIGINT, print_summary);

    long pid = argc > 1 ? strtol(argv[1], NULL, 16) : 0;

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int vid = XENCELABS_VID;
    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vidNum);
    CFRelease(vidNum);
    if (pid) {
        int p = (int)pid;
        CFNumberRef pidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &p);
        CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), pidNum);
        CFRelease(pidNum);
    }
    IOHIDManagerSetDeviceMatching(mgr, match);
    CFRelease(match);

    IOHIDManagerRegisterInputReportCallback(mgr, report_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen failed: 0x%x\n", r);
        return 1;
    }
    printf("Capturing Xencelabs (VID 28bd%s). Timestamps in ms. Ctrl-C for summary.\n",
           pid ? ", PID filtered" : "");
    CFRunLoopRun();
    return 0;
}
