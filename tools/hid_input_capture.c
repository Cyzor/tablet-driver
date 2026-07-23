/*
 * hid_input_capture.c — raw HID input-report logger for any vendor/product.
 *
 * Opens the device directly via IOHIDManager (kIOHIDOptionsTypeNone — not
 * exclusive), so it works alongside a vendor's own driver/app that already
 * has the device open (e.g. Xencelabs Driver Hub, Wacom Desktop Center).
 * Captures the real device -> host input-report stream: no SIP disable,
 * no dtrace, no vendor cooperation required.
 *
 * Build:
 *   clang -framework IOKit -framework CoreFoundation tools/hid_input_capture.c \
 *         -o /tmp/hid_input_capture
 *
 * Run:
 *   /tmp/hid_input_capture <vid-hex> [pid-hex]
 *   e.g. /tmp/hid_input_capture 28bd 0914
 *
 * If pid is omitted, matches every product under that vendor ID and prints
 * which VID/PID matched so you can narrow it down on a second run. Also
 * dumps the raw HID report descriptor for each matched device once, before
 * streaming reports. Ctrl-C to stop.
 */

#include <IOKit/hid/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint8_t report_buf[512];

static void dump_descriptor(IOHIDDeviceRef device)
{
    CFTypeRef prop = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    if (!prop || CFGetTypeID(prop) != CFDataGetTypeID()) {
        printf("[descriptor] unavailable\n");
        return;
    }
    CFDataRef data = (CFDataRef)prop;
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    printf("[descriptor] %ld bytes:", (long)len);
    for (CFIndex i = 0; i < len; i++) printf(" %02x", bytes[i]);
    printf("\n");
    fflush(stdout);
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static double last_report_ms = -1;

static void report_cb(void *ctx, IOReturn result, void *sender,
                      IOHIDReportType type, uint32_t report_id,
                      uint8_t *report, CFIndex length)
{
    const char *type_name =
        type == kIOHIDReportTypeInput ? "in" :
        type == kIOHIDReportTypeOutput ? "out" :
        type == kIOHIDReportTypeFeature ? "feat" : "?";
    double t = now_ms();
    double gap = last_report_ms < 0 ? 0.0 : t - last_report_ms;
    last_report_ms = t;
    printf("[t=%.3f dt=%6.2f] [%s id=0x%02x len=%2zd]", t, gap, type_name, report_id, (size_t)length);
    for (CFIndex i = 0; i < length; i++) printf(" %02x", report[i]);
    printf("\n");
    fflush(stdout);
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
    dump_descriptor(device);
    fflush(stdout);

    IOHIDDeviceRegisterInputReportCallback(
        device, report_buf, (CFIndex)sizeof(report_buf), report_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess)
        printf("[warn] IOHIDDeviceOpen returned 0x%x for %s\n", r, name);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <vid-hex> [pid-hex]\n", argv[0]);
        return 1;
    }
    int vid = (int)strtol(argv[1], NULL, 16);
    int pid = argc >= 3 ? (int)strtol(argv[2], NULL, 16) : -1;

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef n_vid = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), n_vid);
    if (pid >= 0) {
        CFNumberRef n_pid = CFNumberCreate(NULL, kCFNumberIntType, &pid);
        CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), n_pid);
    }

    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, device_matched, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen failed: 0x%x\n", r);
        return 1;
    }

    if (pid >= 0)
        printf("Listening on VID=0x%04x PID=0x%04x — use the device now. Ctrl-C to stop.\n", vid, pid);
    else
        printf("Listening on VID=0x%04x (all PIDs) — use the device now. Ctrl-C to stop.\n", vid);
    CFRunLoopRun();
    return 0;
}
