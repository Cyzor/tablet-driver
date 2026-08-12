#!/usr/sbin/dtrace -s
/*
 * wacom_capture.d — capture SetReport/GetReport traffic during live use.
 *
 * Companion to wacom_init.d: that script captures the driver's init sequence
 * on device connect; this one is meant to stay attached afterward and catch
 * reports triggered by interacting with the device (e.g. pressing a
 * ring-mode button), without the timestamp/lifecycle bookkeeping wacom_init.d
 * adds for the connect sequence.
 *
 * Requires SIP disabled (pid$target provider). Superseded for most read-only
 * capture needs by tools/hid_input_capture.c and tools/hid_descriptor_dump.c,
 * which need no SIP disable — keep this for cases that need to see outbound
 * SetReport/GetReport traffic a specific driver process is sending, not just
 * inbound reports.
 *
 * Usage:
 *   sudo dtrace -s tools/wacom_capture.d -p $(pgrep WacomTabletDriver)
 *   Then trigger the button/action you want to observe.
 */

#pragma D option quiet
#pragma D option switchrate=10hz

BEGIN { printf("=== wacom_capture running — trigger ring-mode button now ===\n"); }

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
