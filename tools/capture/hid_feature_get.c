// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// GET_REPORTs one or more feature report IDs from a HID device and prints
// the bytes returned. Companion to hid_init_probe.c (which only SETs);
// built to check whether the PTK-870's opaque feature reports 0x37/0x38/0x39
// carry per-pen identity that Wacom's own driver reads on connect instead
// of waiting on the BLE input-report tool-announcement frame. No SIP or
// dtrace needed.
//
// Build:  clang -framework IOKit -framework CoreFoundation tools/capture/hid_feature_get.c -o hid_feature_get
// Usage:  hid_feature_get <vid-hex> <pid-hex> <report-id-hex> [report-id-hex ...]
//         Re-issues all GETs every 2 seconds so you can swap pens between
//         reads and diff the output. Ctrl-C to stop.

#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static uint8_t reportIDs[32];
static int reportIDCount = 0;

static void doGets(IOHIDDeviceRef dev) {
    for (int i = 0; i < reportIDCount; i++) {
        uint8_t buf[256] = {0};
        CFIndex len = sizeof buf;
        IOReturn r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature,
                                          reportIDs[i], buf, &len);
        if (r != kIOReturnSuccess) {
            printf("[get 0x%02x] FAILED (0x%x)\n", reportIDs[i], r);
            continue;
        }
        printf("[get 0x%02x len=%ld]", reportIDs[i], (long)len);
        for (CFIndex j = 0; j < len; j++) printf(" %02x", buf[j]);
        printf("\n");
    }
    fflush(stdout);
}

static void timerCallback(CFRunLoopTimerRef timer, void *info) {
    doGets((IOHIDDeviceRef)info);
}

static void matchCallback(void *context, IOReturn result, void *sender,
                          IOHIDDeviceRef dev) {
    CFStringRef name = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
    char nameBuf[128] = "?";
    if (name) CFStringGetCString(name, nameBuf, sizeof nameBuf, kCFStringEncodingUTF8);
    long vid = 0, pid = 0;
    CFNumberRef nvid = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey));
    CFNumberRef npid = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey));
    if (nvid) CFNumberGetValue(nvid, kCFNumberLongType, &vid);
    if (npid) CFNumberGetValue(npid, kCFNumberLongType, &pid);
    printf("[matched] %s  vid=0x%04lx pid=0x%04lx\n", nameBuf, vid, pid);
    doGets(dev);

    CFRunLoopTimerContext ctx = {0, dev, NULL, NULL, NULL};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
        NULL, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0, timerCallback, &ctx);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <vid-hex> <pid-hex> <report-id-hex> [report-id-hex ...]\n", argv[0]);
        return 1;
    }
    long vid = strtol(argv[1], NULL, 16), pid = strtol(argv[2], NULL, 16);
    reportIDCount = argc - 3;
    if (reportIDCount > 32) reportIDCount = 32;
    for (int i = 0; i < reportIDCount; i++)
        reportIDs[i] = (uint8_t)strtol(argv[3 + i], NULL, 16);

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberLongType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberLongType, &pid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), v);
    CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), p);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCallback, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) fprintf(stderr, "IOHIDManagerOpen: 0x%x\n", r);
    printf("GETting feature reports from VID=0x%04lx PID=0x%04lx every 2s. Ctrl-C to stop.\n", vid, pid);
    fflush(stdout);
    CFRunLoopRun();
    return 0;
}
