# Measurement Methods

The protocol pages label most claims **observed**. This page explains what
that involves, so you can repeat a measurement or provide a new one.

## Capturing Reports

`tools/capture/hid_input_capture.c` opens a tablet's HID interfaces and logs
every input report with a timestamp. It needs no special permissions. MockTab's
own capture tools record the same reports along with the device's
descriptor, and leave out serial numbers.

A capture is only as good as its notes. Before recording, write down what
you're about to do: "three slow clockwise turns of the left dial", "tip down
at each corner". Without that, a log of bytes can't settle anything.

## Edges and Grooves

To find a surface's real limits, slide the pen slowly off each edge and
along the molded grooves past it, then read the extremes from the capture.
Comparing those samples with ones taken well inside the edge shows which
status bits tell them apart.

## Dials and Rings

Turn slowly through one full rotation, starting and stopping at a mark, and
count the steps. Do it in both directions, on each dial.

## Tilt Direction

Ranges come from stop-to-stop sweeps: lean the pen as far as it goes, in
each direction. Direction is harder. Reading it from the event stream
proves only that a number changed. Instead, draw with a flat, angled brush
in a painting app (Rebelle works well) and check that the stroke follows the
pen. If it doesn't, the sign or the axis is wrong.

## Pressure

Press and lift many times at different speeds, and check that pressure
rises smoothly from first contact, with no jump or dead zone.

## Sharing What You Find

Open an issue with the capture and your notes. Remove serial numbers first,
and mention anything else in the file you'd rather keep private. These notes publish only what a
capture teaches, not the capture itself, unless you say otherwise.
