# Wacom wireless links and battery reporting

How each wireless Wacom tablet connects, and where its battery level
appears. Byte layouts for the pen data itself are on the protocol pages.
Confidence labels: **observed** · **kernel** · **unverified**.

## Transports

| Tablet | Link | Pen data | Confidence |
| --- | --- | --- | --- |
| Intuos5, Intuos Pro gen 1, some Bamboos | ACK-40401 USB dongle (PID `0x0084`), proprietary 2.4 GHz | Same reports as USB, relayed by the dongle | observed (PTH-850) |
| Intuos4 Wireless (PTK-540WL) | Bluetooth Classic | 2–3 packed 10-byte frames | kernel |
| Intuos Pro gen 2 (PTH-x60) | Bluetooth Classic | Packed frames, report `0x80` | observed |
| Intuos (CTL-4100WL/6100WL) | Bluetooth | Packed frames, report `0x81` | observed |
| Intuos Pro gen 3 (PTK-x70) | Bluetooth LE | Report `0x1A` | observed |
| ExpressKey Remote | Own USB receiver (PID `0x0331`) | Report `0x11` | observed (ring mode) |

The PTH-x60 also advertises a Bluetooth LE identity, which serves Wacom's
paper-notes mode, not tablet input. (kernel)

A tablet reachable over both its cable and a dongle or Bluetooth shows up
as two devices with different product IDs. Pick one rather than merging
their streams. (observed, PTH-850 with the ACK-40401)

## Battery

| Tablet | Where | Encoding | Confidence |
| --- | --- | --- | --- |
| Intuos Pro gen 2 (Bluetooth) | Report `0x80` (361-byte form), `[284]` | Bit 7 charging, bits 0–6 percent | observed |
| Intuos CTL-x100WL (Bluetooth) | Report `0x81`, `[45]` | Bit 7 charging, bits 0–6 percent | observed |
| Intuos Pro gen 3 (Bluetooth LE) | Report `0x1B`, `[1]`, once per second | Bit 7 charging, bits 0–6 percent | observed |
| ExpressKey Remote | Report `0x11`, `[7]` | Bit 7 charging, bits 0–6 percent | kernel |
| ACK-40401 dongle | Report `0x80`, `[5]` | Bits 0–5 × 100 / 31; bit 7 charging | kernel |
| Intuos4 Wireless | Last byte of reports `0x03`/`0x04` | Bits 0–2 index `1, 15, 30, 45, 60, 70, 85, 100`; bit 3 charging; bit 4 external power | kernel |

On the gen 3, raw values with bit 7 set (`0xCC`, `0xE4`) only appear while
charging, and the remaining bits never exceed 100. That is what settles the
split. (observed)

## ACK-40401 dongle status, report `0x80`

32 bytes. `[1]` bit 0 set means a tablet is linked. While linked, `[5]`
carries the battery level (above) and `[6]`–`[7]` the linked tablet's
product ID, big-endian. When the link drops, the kernel forgets the tablet
and its battery. (kernel)

TabletKit's gen 2 decoder instead reads whole values of `[1]` (`0x02`
active, `0x05` lost, `0x06` low battery). The source for those values is
unknown and they conflict with the kernel's bit 0, so treat them as
unverified.

## Unverified

- ACK-40401 status report: no capture; everything above is from the kernel.
- Intuos4 Wireless and the Graphire Bluetooth: kernel only.

## Tests

These TabletKit tests check the layouts above, many with frames from real captures:

- [`BLEReportDecodingTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/BLEReportDecodingTests.swift)
- [`IntuosV2BTDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV2BTDecoderTests.swift)
- [`IntuosV3DecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/IntuosV3DecoderTests.swift)
- [`ExpressKeyRemoteDecoderTests`](https://github.com/Cyzor/TabletKit/blob/main/Tests/TabletKitTests/ExpressKeyRemoteDecoderTests.swift)
