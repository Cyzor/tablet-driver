/*
 * xencelabs_battery_capture.c — sends the Xencelabs battery GET poll
 * ([0x02, 0xB4, 0x10, ...]) and logs every HID input report that comes
 * back, so we can find which tag/offset actually carries the battery
 * percentage. The app already sends this same poll during its normal
 * resync (see WacomKnownDevice.swift, resyncXencelabsOutputsAfterRelink)
 * but nothing currently decodes the reply.
 *
 * Opens the device directly via IOHIDManager (kIOHIDOptionsTypeNone — not
 * exclusive), so it works alongside MockTab or the vendor's own driver/app
 * if either is running. No SIP disable, no dtrace required.
 *
 * Build:
 *   clang -framework IOKit -framework CoreFoundation \
 *         tools/capture/xencelabs_battery_capture.c -o /tmp/xencelabs_battery_capture
 *
 * Run:
 *   /tmp/xencelabs_battery_capture
 *
 * Matches every Xencelabs device (VID 0x28BD — pen tablet/display, puck,
 * and wireless dongle all share this VID). For each matched device, sends
 * the battery poll once on connect and again every 5 seconds, and prints
 * every input/feature report it receives with a timestamp so replies can
 * be correlated with the poll that likely triggered them. Ctrl-C to stop.
 *
 * What to look for: a report arriving shortly after a "[poll sent]" line,
 * with a tag byte in the 0xB0-0xBF or 0xF0-0xFF range whose payload looks
 * like a small 0-100 value (vendor logs report "Battery get Value: 99 0",
 * i.e. a raw percentage) — note the byte offset and tag value and report
 * them back.
 *
 * Over the wireless dongle, an unaddressed poll is silently dropped by the
 * firmware — the app always appends the puck's 6-byte identity (read from
 * offset 10 of the connect-time status frame; see xencelabsDongleIdentity
 * in WacomKnownDevice.swift). This tool now does the same: it watches every
 * incoming report for one at least 16 bytes long, grabs bytes [10..15] as
 * the identity the first time it sees one, and appends that identity to
 * every poll from then on (both the initial send and the periodic resend).
 * If your dongle/puck was already connected before this tool started, no
 * status frame will arrive on its own — unplug and replug the dongle (or
 * power-cycle the puck) while this is running so the identity frame shows
 * up.
 */

#include <IOKit/hid/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define XENCELABS_VID 0x28BD
#define POLL_INTERVAL_SEC 5
#define IDENTITY_LENGTH 6

static uint8_t report_buf[512];
static uint8_t identity[IDENTITY_LENGTH];
static int have_identity = 0;

static void print_timestamp(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tmv;
    localtime_r(&ts.tv_sec, &tmv);
    printf("[%02d:%02d:%02d.%03ld] ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
           ts.tv_nsec / 1000000);
}

static void report_cb(void *ctx, IOReturn result, void *sender,
                       IOHIDReportType type, uint32_t report_id,
                       uint8_t *report, CFIndex length)
{
    const char *type_name =
        type == kIOHIDReportTypeInput ? "in" :
        type == kIOHIDReportTypeOutput ? "out" :
        type == kIOHIDReportTypeFeature ? "feat" : "?";
    print_timestamp();
    printf("[%s id=0x%02x len=%2zd]", type_name, report_id, (size_t)length);
    CFIndex cap = length < 64 ? length : 64;
    for (CFIndex i = 0; i < cap; i++) printf(" %02x", report[i]);
    if (length > 64) printf(" ...");
    printf("\n");
    fflush(stdout);

    /* Identity offset isn't constant: the one-off connect/restart
     * announcement (tag 0xF8, byte[2]==0x02, byte[3]==0x01) carries it at
     * offset 10, but ordinary ongoing traffic (live 0xF0 aux/button frames,
     * the 0xF2 battery-poll reply) carries it two bytes later, at offset
     * 12 — confirmed 2026-07-14 by diffing a captured aux frame against the
     * announce frame. Getting this wrong still looks like a valid capture
     * (nonzero, since it overlaps the real identity, just shifted), which
     * is exactly what silently broke battery polling until a power-cycle
     * re-emitted the announce frame this used to assume unconditionally. */
    int offset = (length > 3 && report[1] == 0xf8 && report[2] == 0x02 && report[3] == 0x01)
        ? 10 : 12;
    if (!have_identity && length >= offset + IDENTITY_LENGTH) {
        memcpy(identity, report + offset, IDENTITY_LENGTH);
        have_identity = 1;
        print_timestamp();
        printf("[identity] captured from this frame, offset %d, %d bytes:",
               offset, IDENTITY_LENGTH);
        for (int i = 0; i < IDENTITY_LENGTH; i++) printf(" %02x", identity[i]);
        printf(" — future polls will be addressed with it\n");
        fflush(stdout);
    }
}

static void send_battery_poll(IOHIDDeviceRef device, const char *name)
{
    CFTypeRef prop = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDMaxOutputReportSizeKey));
    long declared = 0;
    if (prop) CFNumberGetValue((CFNumberRef)prop, kCFNumberLongType, &declared);

    uint8_t poll[64] = {0x02, 0xB4, 0x10, 0, 0, 0, 0, 0, 0, 0};
    size_t base_len = 10;
    if (have_identity && base_len + IDENTITY_LENGTH <= sizeof(poll)) {
        memcpy(poll + base_len, identity, IDENTITY_LENGTH);
        base_len += IDENTITY_LENGTH;
    }
    size_t len = declared > (long)base_len && declared <= (long)sizeof(poll)
        ? (size_t)declared : base_len;

    IOReturn r = IOHIDDeviceSetReport(
        device, kIOHIDReportTypeOutput, poll[0], poll, (CFIndex)len);
    print_timestamp();
    printf("[poll sent] %s — battery GET, %zu bytes, addressed=%s, result=0x%x\n",
           name, len, have_identity ? "yes" : "no", r);
    fflush(stdout);
}

static void poll_timer_cb(CFRunLoopTimerRef timer, void *ctx)
{
    IOHIDDeviceRef device = (IOHIDDeviceRef)ctx;
    send_battery_poll(device, "(poll)");
}

static void device_matched(void *ctx, IOReturn result, void *sender,
                            IOHIDDeviceRef device)
{
    char name[256] = "(unknown)";
    CFStringRef prop = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (prop) CFStringGetCString(prop, name, sizeof(name), kCFStringEncodingUTF8);

    long vid = 0, pid = 0;
    CFNumberRef nvid = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    CFNumberRef npid = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    if (nvid) CFNumberGetValue(nvid, kCFNumberLongType, &vid);
    if (npid) CFNumberGetValue(npid, kCFNumberLongType, &pid);

    printf("[matched] %s  vid=0x%04lx pid=0x%04lx — registering report callback\n",
           name, vid, pid);
    fflush(stdout);

    IOHIDDeviceRegisterInputReportCallback(
        device, report_buf, (CFIndex)sizeof(report_buf), report_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        printf("[warn] IOHIDDeviceOpen returned 0x%x for %s\n", r, name);
        return;
    }

    send_battery_poll(device, name);

    CFRunLoopTimerContext timerCtx = {0, device, NULL, NULL, NULL};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + POLL_INTERVAL_SEC, POLL_INTERVAL_SEC,
        0, 0, poll_timer_cb, &timerCtx);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
}

int main(void)
{
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int vid = XENCELABS_VID;
    CFNumberRef n_vid = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), n_vid);

    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, device_matched, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen failed: 0x%x\n", r);
        return 1;
    }

    printf("Listening for Xencelabs devices (VID=0x%04x). Sends a battery poll on\n"
           "connect and every %d seconds. If polling over the wireless dongle and no\n"
           "[identity] line appears, unplug/replug the dongle or power-cycle the puck\n"
           "to force a fresh status frame. Ctrl-C to stop, then paste the output back.\n",
           XENCELABS_VID, POLL_INTERVAL_SEC);
    CFRunLoopRun();
    return 0;
}
