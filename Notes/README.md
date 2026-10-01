# Tablet protocol notes

What MockTab has learned about how drawing tablets talk to a computer, and
how macOS expects a driver to talk to apps. The pages favor what has been
seen on real hardware; formats known only from the Linux driver get a
pointer to its source rather than a copy.

Each claim carries one of three labels:

- **observed**: seen on hardware, in the device's own HID descriptor, or
  in the traffic the vendor's driver sends;
- **kernel**: from the Linux driver (`drivers/hid/wacom_wac.c`,
  `wacom_sys.c`) only;
- **unverified**: neither, kept because it's the best lead available.

TabletKit, the decoder library in `TabletKit/`, implements these
formats; its decoder for each is named on the page.

## Wacom pen protocols

| Page | Tablets |
| --- | --- |
| [Intuos Pro gen 3](Wacom-Intuos-Pro-Gen3-Protocol.md) | PTK-470/670/870 (2025), USB and Bluetooth LE; Movink 13 |
| [Intuos Pro gen 2](Wacom-Intuos-Pro-Gen2-Protocol.md) | PTH-460/660/860, CTL-4100/6100, and many pen displays; USB and Bluetooth |
| [Intuos 10-byte format](Wacom-Intuos-10-Byte-Protocol.md) | Intuos 1–5, Intuos Pro gen 1, Intuos3, CTL/CTH-x90 and x72 |
| [Consumer tablets](Wacom-Consumer-Tablet-Protocols.md) | Graphire, Bamboo, Intuos 2013; the shared touch and key container |
| [Pen displays](Wacom-Pen-Display-Protocols.md) | Cintiq, DTU, PL; Cintiq touch; ExpressKey Remote |

## Across Wacom tablets

| Page | Covers |
| --- | --- |
| [Switching into full-data mode](Wacom-Mode-Switching.md) | The feature report every tablet needs, and where to send it |
| [Pen tool codes](Wacom-Pen-Tool-Codes.md) | Codes seen on hardware; eraser, Art Pen and rotation rules |
| [Wireless and battery](Wacom-Wireless-and-Battery.md) | Transports by model; battery encodings; the ACK-40401 dongle |
| [LEDs and OLEDs](Wacom-LED-and-OLED-Control.md) | Ring LEDs, ruled-out reports, Intuos4 key displays |

## Other

| Page | Covers |
| --- | --- |
| [Xencelabs](Xencelabs-Protocol.md) | Pen Tablet, Pen Display, Quick Keys: input and host writes |
| [macOS tablet event synthesis](macOS-Tablet-Event-Synthesis.md) | Proximity, pen, click and scroll fields that apps check |
| [Project description](Project-Description.md) | MockTab's own architecture notes |

Corrections are welcome as issues, ideally with a capture.
