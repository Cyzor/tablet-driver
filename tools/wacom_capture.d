#!/usr/sbin/dtrace -s
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
