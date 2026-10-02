#!/usr/sbin/dtrace -s
/*
 * hid_traffic_capture.d — capture SetReport/GetReport traffic during live use.
 *
 * Companion to hid_connect_capture.d: that script captures the driver's init sequence
 * on device connect; this one is meant to stay attached afterward and catch
 * reports triggered by interacting with the device (e.g. pressing a
 * button), without the timestamp/lifecycle bookkeeping hid_connect_capture.d
 * adds for the connect sequence.
 *
 * Requires SIP disabled (pid$target provider). Superseded for most read-only
 * capture needs by tools/capture/hid_input_capture.c and tools/capture/hid_descriptor_dump.c,
 * which need no SIP disable — keep this for cases that need to see outbound
 * SetReport/GetReport traffic a specific driver process is sending, not just
 * inbound reports.
 *
 * Usage:
 *   sudo dtrace -s tools/capture/hid_traffic_capture.d -p <driver-pid>
 *   Then trigger the button/action you want to observe.
 */

#pragma D option quiet
#pragma D option switchrate=10hz

BEGIN { printf("=== hid_traffic_capture running — trigger the action now ===\n"); }

pid$target:IOKit:IOHIDDeviceSetReport:entry
{
        this->len = arg4 > 64 ? 64 : arg4;
        printf("\n[SetReport] type=%d id=0x%02x len=%d\n", arg1, arg2, arg4);
        tracemem(copyin(arg3, this->len), 64, this->len);
}

pid$target:IOKit:IOHIDDeviceSetReportWithCallback:entry
{
        this->len = arg4 > 64 ? 64 : arg4;
        printf("\n[SetReportCB] type=%d id=0x%02x len=%d\n", arg1, arg2, arg4);
        tracemem(copyin(arg3, this->len), 64, this->len);
}

pid$target:IOKit:IOHIDDeviceGetReport:entry
{
        printf("[GetReport] type=%d id=0x%02x\n", arg1, arg2);
}
