/*
 * hid_descriptor_dump.c — dump a device's parsed HID report descriptor.
 *
 * Mirrors MockTab/Driver/HIDDescriptorReader.swift's element walk (usage
 * page / usage / size / count per field, grouped by report ID + direction),
 * so we can see exactly what the app's descriptor-driven logic would see,
 * without building the app. Read-only: does not open the device, so it's
 * safe to run alongside a vendor driver that already has it open.
 *
 * Build:
 *   clang -framework IOKit -framework CoreFoundation tools/hid_descriptor_dump.c \
 *         -o /tmp/hid_descriptor_dump
 *
 * Run:
 *   /tmp/hid_descriptor_dump <vid-hex> [pid-hex]
 *   e.g. /tmp/hid_descriptor_dump 056a       (all Wacom devices)
 *   e.g. /tmp/hid_descriptor_dump 28bd 0914  (one Xencelabs device)
 */

#include <IOKit/hid/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>

static const char *dir_name(IOHIDElementType t)
{
    switch (t) {
    case kIOHIDElementTypeInput_Misc:
    case kIOHIDElementTypeInput_Button:
    case kIOHIDElementTypeInput_Axis:
    case kIOHIDElementTypeInput_ScanCodes:
        return "input";
    case kIOHIDElementTypeOutput:
        return "output";
    case kIOHIDElementTypeFeature:
        return "feature";
    default:
        return NULL;
    }
}

static const char *friendly(uint32_t page, uint32_t usage)
{
    if (page == 0x01 && usage == 0x30) return "X";
    if (page == 0x01 && usage == 0x31) return "Y";
    if (page == 0x01 && usage == 0x38) return "Wheel";
    if (page == 0x0D && usage == 0x30) return "TipPressure";
    if (page == 0x0D && usage == 0x31) return "BarrelPressure";
    if (page == 0x0D && usage == 0x32) return "InRange";
    if (page == 0x0D && usage == 0x33) return "Touch";
    if (page == 0x0D && usage == 0x3B) return "BatteryStrength";
    if (page == 0x0D && usage == 0x3D) return "XTilt";
    if (page == 0x0D && usage == 0x3E) return "YTilt";
    if (page == 0x0D && usage == 0x42) return "TipSwitch";
    if (page == 0x0D && usage == 0x44) return "BarrelSwitch";
    if (page == 0x0D && usage == 0x45) return "Eraser";
    if (page == 0x0D && usage == 0x5B) return "TransducerSerialNumber";
    if (page == 0x0D && usage == 0x77) return "Twist";
    if (page == 0x09) return "Button(n)";
    if (page >= 0xFF00) return "(vendor-defined page)";
    return NULL;
}

static void dump_device(IOHIDDeviceRef device)
{
    char name[256] = "(unknown)";
    CFStringRef prop = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (prop) CFStringGetCString(prop, name, sizeof(name), kCFStringEncodingUTF8);

    long vid = 0, pid = 0;
    CFNumberRef nvid = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    CFNumberRef npid = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    if (nvid) CFNumberGetValue(nvid, kCFNumberLongType, &vid);
    if (npid) CFNumberGetValue(npid, kCFNumberLongType, &pid);

    printf("\n=== %s  vid=0x%04lx pid=0x%04lx ===\n", name, vid, pid);

    CFTypeRef descProp = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    if (descProp && CFGetTypeID(descProp) == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength((CFDataRef)descProp);
        printf("raw descriptor: %ld bytes\n", (long)len);
    } else {
        printf("raw descriptor: unavailable\n");
    }

    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, 0);
    if (!elements) {
        printf("(no elements exposed)\n");
        return;
    }

    CFIndex count = CFArrayGetCount(elements);
    int standardPageSeen = 0;
    int vendorPageSeen = 0;

    for (CFIndex i = 0; i < count; i++) {
        IOHIDElementRef elem = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        const char *dir = dir_name(IOHIDElementGetType(elem));
        if (!dir) continue;

        uint32_t reportID = IOHIDElementGetReportID(elem);
        uint32_t page = IOHIDElementGetUsagePage(elem);
        uint32_t usage = IOHIDElementGetUsage(elem);
        uint32_t size = IOHIDElementGetReportSize(elem);
        uint32_t cnt = IOHIDElementGetReportCount(elem);
        CFIndex lmin = IOHIDElementGetLogicalMin(elem);
        CFIndex lmax = IOHIDElementGetLogicalMax(elem);

        if (page >= 0xFF00) vendorPageSeen = 1;
        else standardPageSeen = 1;

        const char *label = friendly(page, usage);
        printf("  %s:0x%02x  page=0x%04x usage=0x%02x  %ux%u bits  [%ld..%ld]%s%s\n",
               dir, reportID, page, usage, size, cnt, (long)lmin, (long)lmax,
               label ? "  " : "", label ? label : "");
    }
    CFRelease(elements);

    printf("--- summary: %s%s%s ---\n",
           standardPageSeen ? "has standard HID usage pages" : "",
           (standardPageSeen && vendorPageSeen) ? " + " : "",
           vendorPageSeen ? "has vendor-defined (0xFFxx) pages" : (standardPageSeen ? "" : "no elements"));
}

static void device_matched(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device)
{
    dump_device(device);
    fflush(stdout);
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

    /* Matched devices already connected fire almost immediately; give the
     * run loop a moment to deliver them, then exit (no streaming needed). */
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false);
    return 0;
}
