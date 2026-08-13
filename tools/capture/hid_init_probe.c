// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// Sends a vendor tablet-mode init to a HID device, then logs every input
// report it emits — for probing whether a mute device (e.g. the Xencelabs
// Quick Keys over direct USB) wakes up after the known init handshake.
// Companion to hid_input_capture.c; no SIP or dtrace needed.
//
// Build:  clang -framework IOKit -framework CoreFoundation tools/capture/hid_init_probe.c -o hid_init_probe
// Usage:  hid_init_probe <vid-hex> <pid-hex> [init-byte-hex ...]
//         Default init payload if none given: 02 b0 04 (report ID 2),
//         zero-padded to the device's MaxOutputReportSize.

#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static uint8_t reportBuf[256];

static void inputCallback(void *context, IOReturn result, void *sender,
                          IOHIDReportType type, uint32_t reportID,
                          uint8_t *report, CFIndex length) {
    printf("[in id=0x%02x len=%ld]", reportID, (long)length);
    for (CFIndex i = 0; i < length; i++) printf(" %02x", report[i]);
    printf("\n");
    fflush(stdout);
}

static int32_t intProp(IOHIDDeviceRef dev, CFStringRef key) {
    int32_t v = 0;
    CFNumberRef n = IOHIDDeviceGetProperty(dev, key);
    if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &v);
    return v;
}

static void matchCallback(void *context, IOReturn result, void *sender,
                          IOHIDDeviceRef dev) {
    uint8_t *init = ((uint8_t **)context)[0];
    long initLen = *(long *)(((void **)context)[1]);

    CFStringRef name = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
    char nameBuf[128] = "?";
    if (name) CFStringGetCString(name, nameBuf, sizeof nameBuf, kCFStringEncodingUTF8);
    int32_t maxOut = intProp(dev, CFSTR(kIOHIDMaxOutputReportSizeKey));
    printf("[matched] %s — MaxOutputReportSize=%d\n", nameBuf, maxOut);

    IOHIDDeviceRegisterInputReportCallback(dev, reportBuf, sizeof reportBuf,
                                           inputCallback, NULL);

    // Zero-pad to the declared output size: this firmware family silently
    // ignores short writes (returns success, does nothing).
    long len = maxOut > 0 && maxOut <= 256 ? maxOut : initLen;
    uint8_t payload[256] = {0};
    for (long i = 0; i < initLen && i < len; i++) payload[i] = init[i];
    IOReturn r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, payload[0],
                                      payload, len);
    printf("[init] sent %ld bytes (report ID 0x%02x): %s\n", len, payload[0],
           r == kIOReturnSuccess ? "kIOReturnSuccess" : "FAILED");
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <vid-hex> <pid-hex> [init-byte-hex ...]\n", argv[0]);
        return 1;
    }
    long vid = strtol(argv[1], NULL, 16), pid = strtol(argv[2], NULL, 16);

    static uint8_t init[64] = {0x02, 0xB0, 0x04};
    static long initLen = 3;
    if (argc > 3) {
        initLen = argc - 3;
        for (int i = 0; i < initLen && i < 64; i++)
            init[i] = (uint8_t)strtol(argv[3 + i], NULL, 16);
    }
    static void *ctx[2];
    ctx[0] = init;
    ctx[1] = &initLen;

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberLongType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberLongType, &pid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), v);
    CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), p);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCallback, ctx);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    // Non-exclusive: coexists with any driver that also holds the device.
    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) fprintf(stderr, "IOHIDManagerOpen: 0x%x\n", r);
    printf("Probing VID=0x%04lx PID=0x%04lx — use the device now. Ctrl-C to stop.\n", vid, pid);
    fflush(stdout);
    CFRunLoopRun();
    return 0;
}
