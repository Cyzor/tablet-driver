#!/usr/sbin/dtrace -s
/*
 * wacom_init.d — capture full Wacom driver init sequence on device connect.
 *
 * Usage:
 *   sudo dtrace -s /tmp/wacom_init.d -p $(pgrep WacomTabletDriver) \
 *       > /tmp/wacom_init.log 2>&1
 *   Then unplug and replug the device USB cable.
 *   Wait ~5 s after replug, then Ctrl-C.
 *
 * Captures:
 *   DeviceOpen / DeviceClose  — device lifecycle markers
 *   SetReport                 — host → device (init, LED, feature writes)
 *   GetReport (entry+return)  — host polls device; response shown on return
 */

#pragma D option quiet
#pragma D option switchrate=10hz
#pragma D option bufsize=16m

BEGIN {
    printf("=== wacom_init — unplug then replug device now ===\n\n");
}

/* ── Device lifecycle ─────────────────────────────────────────────────── */

pid$target:IOKit:IOHIDDeviceOpen:entry
{
    printf("\n[%Y] *** DeviceOpen  dev=%p options=0x%x ***\n",
           walltimestamp, arg0, arg1);
}

pid$target:IOKit:IOHIDDeviceClose:entry
{
    printf("[%Y] *** DeviceClose dev=%p options=0x%x ***\n",
           walltimestamp, arg0, arg1);
}

/* ── SetReport: host → device ─────────────────────────────────────────── */

pid$target:IOKit:IOHIDDeviceSetReport:entry
{
    this->len = arg4 > 64 ? 64 : arg4;
    printf("\n[%Y] SetReport  dev=%p type=%d id=0x%02x len=%d\n",
           walltimestamp, arg0, arg1, arg2, arg4);
    tracemem(copyin(arg3, this->len), 64, this->len);
}

pid$target:IOKit:IOHIDDeviceSetReportWithCallback:entry
{
    this->len = arg4 > 64 ? 64 : arg4;
    printf("\n[%Y] SetReportCB dev=%p type=%d id=0x%02x len=%d\n",
           walltimestamp, arg0, arg1, arg2, arg4);
    tracemem(copyin(arg3, this->len), 64, this->len);
}

/* ── GetReport: capture call + response ───────────────────────────────── */

pid$target:IOKit:IOHIDDeviceGetReport:entry
{
    self->gr_dev  = arg0;
    self->gr_type = arg1;
    self->gr_id   = arg2;
    self->gr_buf  = arg3;
    printf("\n[%Y] GetReport  CALL dev=%p type=%d id=0x%02x\n",
           walltimestamp, arg0, arg1, arg2);
}

pid$target:IOKit:IOHIDDeviceGetReport:return
/self->gr_buf != 0/
{
    printf("[%Y] GetReport  RET  dev=%p type=%d id=0x%02x  ret=0x%08x\n",
           walltimestamp, self->gr_dev, self->gr_type, self->gr_id, arg1);
    tracemem(copyin(self->gr_buf, 64), 64, 64);
    self->gr_buf  = 0;
    self->gr_dev  = 0;
}
