#!/usr/sbin/dtrace -s
#pragma D option quiet
#pragma D option switchrate=10hz

/*
 * Traces IOHIDDeviceSetReport / SetReportWithCallback / GetReport calls made
 * by a target process. Vendor-agnostic — point -p/-c at any driver process
 * (Wacom Desktop Center, Xencelabs's driver, etc.) to see exactly what it
 * sends to the tablet at enumeration and during use. Requires SIP disabled;
 * dtrace's pid$target provider is blocked otherwise.
 *
 * Usage: sudo dtrace -s tools/hid_setreport_capture.d -p <pid>
 *    or: sudo dtrace -s tools/hid_setreport_capture.d -c '<path-to-driver-binary>'
 */

BEGIN { printf("=== hid_setreport_capture running — trigger the device action now ===\n"); }

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

/*
 * IOHIDDeviceGetReport(device, type, reportID, report, pReportLength):
 * the response bytes land in the caller's buffer (arg3) only after the call
 * returns, and the actual byte count is written through pReportLength (arg4).
 * Save both pointers at entry, dump the filled buffer at return.
 */
pid$target:IOKit:IOHIDDeviceGetReport:entry
{
        self->grbuf = arg3;
        self->grplen = arg4;
        printf("\n[GetReport] type=%d id=0x%02x\n", arg1, arg2);
}

pid$target:IOKit:IOHIDDeviceGetReport:return
/self->grbuf/
{
        self->grlen = *(int64_t *)copyin(self->grplen, 8);
        self->grlen = self->grlen > 64 ? 64 : self->grlen;
        printf("[GetReport ret] ret=0x%x len=%d\n", arg1, self->grlen);
}

pid$target:IOKit:IOHIDDeviceGetReport:return
/self->grbuf && self->grlen > 0/
{
        tracemem(copyin(self->grbuf, self->grlen), 64, self->grlen);
}

pid$target:IOKit:IOHIDDeviceGetReport:return
/self->grbuf/
{
        self->grbuf = 0;
        self->grplen = 0;
        self->grlen = 0;
}
