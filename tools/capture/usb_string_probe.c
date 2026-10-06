// usb_string_probe.c — can an app read a USB string descriptor from a tablet
// that a HID driver (and MockTab) already has open?
//
// Uses the IOUSBLib device plugin and sends a
// standard GET_DESCRIPTOR(STRING) control request WITHOUT opening the device,
// so nothing about the HID side changes.
//
// Build: clang -framework IOKit -framework CoreFoundation tools/capture/usb_string_probe.c \
//          -o /tmp/usb_string_probe
// Run:   /tmp/usb_string_probe <vid-hex> <pid-hex> <index> [index...]
//        e.g. /tmp/usb_string_probe 28bd 520d 0 2 100
//
// Tried 2026-10-01 with MockTab running: Intuos5 and Xencelabs Pen Display
// kept working throughout. Unknown indices stall harmlessly (0xe000404f).
// Some UC-Logic tablets switch modes when certain strings are read (Huion:
// 200), so read unusual indices deliberately.

#include <stdio.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static void dumpString(IOUSBDeviceInterface **dev, int index) {
    UInt8 buf[255] = {0};
    IOUSBDevRequest req = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice),
        .bRequest = kUSBRqGetDescriptor,
        .wValue = (kUSBStringDesc << 8) | index,
        .wIndex = index == 0 ? 0 : 0x0409,
        .wLength = sizeof(buf),
        .pData = buf,
    };
    IOReturn kr = (*dev)->DeviceRequest(dev, &req);
    printf("  string %3d: result 0x%08x, %u bytes:", index, kr, (unsigned)req.wLenDone);
    for (UInt32 i = 0; i < req.wLenDone; i++) printf(" %02x", buf[i]);
    if (kr == kIOReturnSuccess && index != 0 && req.wLenDone > 2) {
        printf("  \"");
        for (UInt32 i = 2; i + 1 < req.wLenDone; i += 2)
            putchar(buf[i] >= 0x20 && buf[i] < 0x7F && buf[i + 1] == 0 ? buf[i] : '.');
        printf("\"");
    }
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <vid-hex> <pid-hex> <index> [index...]\n", argv[0]);
        return 1;
    }
    int vid = (int)strtol(argv[1], NULL, 16), pid = (int)strtol(argv[2], NULL, 16);

    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), p);

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) {
        fprintf(stderr, "no matching service\n");
        return 1;
    }
    io_service_t service;
    int found = 0;
    while ((service = IOIteratorNext(iter))) {
        found++;
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score;
        IOReturn kr = IOCreatePlugInInterfaceForService(
            service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (kr != kIOReturnSuccess || !plugin) {
            printf("device %d: plugin failed 0x%08x\n", found, kr);
            continue;
        }
        IOUSBDeviceInterface **dev = NULL;
        HRESULT hr = (*plugin)->QueryInterface(
            plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
        (*plugin)->Release(plugin);
        if (hr || !dev) {
            printf("device %d: interface failed\n", found);
            continue;
        }
        printf("device %d (%04x:%04x), not opened:\n", found, vid, pid);
        for (int a = 3; a < argc; a++) dumpString(dev, atoi(argv[a]));
        (*dev)->Release(dev);
    }
    IOObjectRelease(iter);
    if (!found) printf("no device %04x:%04x\n", vid, pid);
    return 0;
}
