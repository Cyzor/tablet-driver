// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
//
// SETs one feature report on a HID device, reading it before and after.
// Companion to hid_feature_get.c. Writes once, to the first interface that
// answers a GET for the same report ID. No SIP or dtrace needed.
//
// Build:  clang -framework IOKit -framework CoreFoundation tools/capture/hid_feature_set.c -o hid_feature_set
// Usage:  hid_feature_set <vid-hex> <pid-hex> <byte-hex> [byte-hex ...]
//         The first byte is the report ID. The tool exits after the write.

#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t payload[256];
static CFIndex payloadLength = 0;
static int writes = 0;

static IOReturn get(IOHIDDeviceRef dev, const char *label) {
    uint8_t buf[256] = {0};
    CFIndex len = sizeof buf;
    IOReturn r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, payload[0], buf, &len);
    if (r != kIOReturnSuccess) return r;
    printf("[%s 0x%02x len=%ld]", label, payload[0], (long)len);
    for (CFIndex i = 0; i < len; i++) printf(" %02x", buf[i]);
    printf("\n");
    return r;
}

static void matchCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    // Write once: the Wacom receiver answers on every interface.
    if (writes > 0 || get(dev, "before") != kIOReturnSuccess) return;
    IOReturn r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, payload[0], payload, payloadLength);
    printf("[set 0x%02x len=%ld] %s (0x%x)\n", payload[0], (long)payloadLength,
           r == kIOReturnSuccess ? "ok" : "FAILED", r);
    get(dev, "after");
    writes++;
    fflush(stdout);
}

static void stop(CFRunLoopTimerRef timer, void *info) { CFRunLoopStop(CFRunLoopGetCurrent()); }

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <vid-hex> <pid-hex> <byte-hex> [byte-hex ...]\n", argv[0]);
        return 2;
    }
    long vid = strtol(argv[1], NULL, 16), pid = strtol(argv[2], NULL, 16);
    for (int i = 3; i < argc && payloadLength < (CFIndex)sizeof payload; i++)
        payload[payloadLength++] = (uint8_t)strtol(argv[i], NULL, 16);

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef nvid = CFNumberCreate(NULL, kCFNumberLongType, &vid);
    CFNumberRef npid = CFNumberCreate(NULL, kCFNumberLongType, &pid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), nvid);
    CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), npid);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCallback, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen failed (0x%x); the terminal may need Input Monitoring\n", r);
        return 1;
    }
    // Matching callbacks arrive right away; give them a moment, then quit.
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 2, 0, 0, 0, stop, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    if (writes == 0) printf("No interface answered report 0x%02x; nothing written.\n", payload[0]);
    return writes == 0;
}
