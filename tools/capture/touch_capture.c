/*
 * touch_capture.c — raw HID report logger for the Wacom PTH-860 touch interface.
 *
 * The touch interface (UsagePage 0xFF00) is separate from the pen interface and
 * is not claimed by MockTab, so it can be opened directly without seizing.
 *
 * Build:
 *   clang -framework IOKit -framework CoreFoundation tools/capture/touch_capture.c \
 *         -o /tmp/touch_capture
 *
 * Run (sudo required to open HID device):
 *   sudo /tmp/touch_capture
 *
 * Then touch the tablet surface with 1–5 fingers. Each input report is printed
 * as a hex dump with report ID and length. Ctrl-C to stop.
 *
 * Expected format (wacom_bpt3_touch, Report ID 0x02):
 *   byte 0    : report ID (0x02)
 *   byte 1    : contact count in bits [2:0]; up to 7 per frame
 *   bytes 2+  : 8-byte blocks per contact (stride 8):
 *                 [0] msg_id  (2–17 = finger, 128 = button block)
 *                 [1] bit7 = touch active
 *                 [2] X high byte
 *                 [3] Y high byte
 *                 [4] X low nibble [7:4], Y low nibble [3:0]
 *                     X = (data[2]<<4)|(data[4]>>4)   → 12-bit, max 62200
 *                     Y = (data[3]<<4)|(data[4]&0x0F) → 12-bit, max 43200
 *                 [5] touch major (width * 100 for INTUOSP2)
 *                 [6] touch minor
 *                 [7] reserved
 */

#include <IOKit/hid/IOHIDLib.h>
#include <stdio.h>
#include <string.h>

#define VID      0x056a
#define PID      0x0358
#define UP_TOUCH 0xFF00

static uint8_t report_buf[512];

static void report_cb(void *ctx, IOReturn result, void *sender,
                      IOHIDReportType type, uint32_t report_id,
                      uint8_t *report, CFIndex length)
{
    printf("[id=0x%02x len=%2zd]", report_id, (size_t)length);
    CFIndex cap = length < 64 ? length : 64;
    for (CFIndex i = 0; i < cap; i++) printf(" %02x", report[i]);
    if (length > 64) printf(" ...");
    printf("\n");
    fflush(stdout);
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
    print_matched(device, name, "registering report callback");
    fflush(stdout);

    IOHIDDeviceRegisterInputReportCallback(
        device, report_buf, (CFIndex)sizeof(report_buf), report_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess)
        printf("[warn] IOHIDDeviceOpen returned 0x%x — try sudo\n", r);
}

int main(void)
{
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    int vid = VID, pid = PID, up = UP_TOUCH;
    CFNumberRef n_vid = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef n_pid = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFNumberRef n_up  = CFNumberCreate(NULL, kCFNumberIntType, &up);

    CFStringRef keys[]   = { CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey),
                              CFSTR(kIOHIDDeviceUsagePageKey) };
    CFTypeRef   values[] = { n_vid, n_pid, n_up };
    CFDictionaryRef match = CFDictionaryCreate(NULL,
        (const void **)keys, (const void **)values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, device_matched, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen failed: 0x%x\n", r);
        return 1;
    }

    printf("Listening on VID=0x%04x PID=0x%04x UsagePage=0xFF00 — touch the surface. Ctrl-C to stop.\n",
           VID, PID);
    CFRunLoopRun();
    return 0;
}
