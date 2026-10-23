#!/usr/sbin/dtrace -s
#pragma D option quiet
#pragma D option switchrate=10hz
#pragma D option zdefs

/*
 * Times MockTab's tablet control writes, and how long its main thread waits
 * when a tablet disconnects or the app quits. Reads no process memory, so it
 * runs with SIP enabled; hid_setreport_capture.d shows the bytes but needs
 * SIP off.
 *
 * Usage: sudo dtrace -s tools/capture/hid_write_timing.d -p <MockTab pid>
 *
 * Times are milliseconds since the script started. "main waited" lines are
 * main-thread dispatch syncs over 1 ms. The script learns which thread is
 * main from its first main-queue drain, so wiggle the pointer over a MockTab
 * window first.
 * The close and stop lines appear only where dtrace lists TabletKit's Swift
 * symbols by their mangled names; the main-thread waits cover the same calls.
 */

BEGIN
{
        start = timestamp;
        printf("=== hid_write_timing running; Ctrl-C to stop ===\n");
}

pid$target:libdispatch.dylib:_dispatch_main_queue_callback_4CF:entry
/maintid == 0/
{
        maintid = tid;
        printf("%6d ms  main thread is tid %d\n", (timestamp - start) / 1000000, tid);
}

pid$target:IOKit:IOHIDDeviceSetReport:entry,
pid$target:IOKit:IOHIDDeviceGetReport:entry
{
        self->io = timestamp;
        self->id = arg2;
}

pid$target:IOKit:IOHIDDeviceSetReport:return,
pid$target:IOKit:IOHIDDeviceGetReport:return
/self->io/
{
        this->us = (timestamp - self->io) / 1000;
        printf("%6d ms  %s id=0x%02x ret=0x%x  %d.%03d ms  tid %d%s\n",
            (self->io - start) / 1000000, probefunc == "IOHIDDeviceSetReport" ? "SetReport" : "GetReport",
            self->id, arg1, this->us / 1000, this->us % 1000, tid, tid == maintid ? " (main)" : "");
        self->io = 0;
}

pid$target::*TabletKit0A9TransportC5closeyyF:entry,
pid$target::*TabletKit0A6OutputC4stopyyF:entry,
pid$target::*TabletKit0A10ConnectionC5closeyyF:entry
{
        self->call[probefunc] = timestamp;
}

pid$target::*TabletKit0A9TransportC5closeyyF:return,
pid$target::*TabletKit0A6OutputC4stopyyF:return,
pid$target::*TabletKit0A10ConnectionC5closeyyF:return
/self->call[probefunc]/
{
        this->us = (timestamp - self->call[probefunc]) / 1000;
        printf("%6d ms  %s  %d.%03d ms  tid %d%s\n",
            (self->call[probefunc] - start) / 1000000,
            strstr(probefunc, "TransportC5close") != NULL ? "transport close" :
            strstr(probefunc, "OutputC4stop") != NULL ? "  output stop" : "  connection close",
            this->us / 1000, this->us % 1000, tid, tid == maintid ? " (main)" : "");
        self->call[probefunc] = 0;
}

pid$target:libdispatch.dylib:__DISPATCH_WAIT_FOR_QUEUE__:entry
/tid == maintid/
{
        self->wait = timestamp;
}

pid$target:libdispatch.dylib:__DISPATCH_WAIT_FOR_QUEUE__:return
/self->wait && timestamp - self->wait > 1000000/
{
        this->us = (timestamp - self->wait) / 1000;
        printf("%6d ms  main waited %d.%03d ms on a queue\n",
            (self->wait - start) / 1000000, this->us / 1000, this->us % 1000);
}

pid$target:libdispatch.dylib:__DISPATCH_WAIT_FOR_QUEUE__:return
/self->wait/
{
        self->wait = 0;
}
