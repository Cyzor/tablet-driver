2026-03-28

# Wacom HID Reference: All Registry Parser Families

## Device Index

All 64 devices from the registry grouped by parser:

| PID | Name | Parser | maxX | maxY | MaxPres | Btns | Ring | Strips | Eraser |
|---|---|---|---|---|---|---|---|---|---|
| 0x0003 | PenPartner | graphire | 5040 | 3780 | 255 | 0 | — | — | — |
| 0x0004 | Graphire | graphire | 10206 | 7422 | 511 | 2 | — | — | ✓ |
| 0x0010 | Graphire 2 (4×5) | graphire | 10206 | 7422 | 511 | 2 | — | — | ✓ |
| 0x0011 | Graphire 2 (5×7) | graphire | 13918 | 10206 | 511 | 2 | — | — | ✓ |
| 0x0013 | Graphire 3 (4×5) | graphire | 10208 | 7424 | 511 | 2 | — | — | ✓ |
| 0x0014 | Graphire 3 (6×8) | graphire | 16704 | 12064 | 511 | 2 | — | — | ✓ |
| 0x0015 | Graphire 4 (4×5) | graphire | 10208 | 7424 | 511 | 2 | — | — | ✓ |
| 0x0016 | Graphire 4 (6×8) | graphire | 16704 | 12064 | 511 | 2 | — | — | ✓ |
| 0x0017 | Bamboo Fun MTE-450 | graphire | 14760 | 9225 | 511 | 4 | — | — | ✓ |
| 0x0060 | Volito | graphire | 5104 | 3712 | 511 | 0 | — | — | — |
| 0x0061 | PenStation | graphire | 3540 | 2468 | 511 | 0 | — | — | — |
| 0x0062 | Volito 2 | graphire | 5104 | 3712 | 511 | 0 | — | — | — |
| 0x0065 | Bamboo One CTF-430 | graphire | 14760 | 9225 | 511 | 0 | — | — | ✓ |
| 0x003F | Cintiq 21UX DTZ-2100 ¹ | graphire | 87200 | 65600 | 1023 | 0 | — | — | ✓ |
| 0x0020–0x0024 | Intuos 1 (4×5 … 12×18) | intuosV1 | varies | varies | 1023 | 0 | — | — | ✓ |
| 0x0041–0x0045 | Intuos 2 (4×5 … 12×18) | intuosV1 | varies | varies | 1023 | 0 | — | — | ✓ |
| 0x00B0 | Intuos3 PTZ-431 | intuos3 | 25400 | 20320 | 1023 | 4 | — | — | ✓ |
| 0x00B1 | Intuos3 PTZ-631 | intuos3 | 40640 | 30480 | 1023 | 8 | — | — | ✓ |
| 0x00B2 | Intuos3 PTZ-930 | intuos3 | 60960 | 45720 | 1023 | 8 | — | — | ✓ |
| 0x00B3 | Intuos3 PTZ-1231 | intuos3 | 60960 | 60960 | 1023 | 8 | — | — | ✓ |
| 0x00B4 | Intuos3 PTZ-1231W | intuos3 | 97536 | 60960 | 1023 | 8 | — | — | ✓ |
| 0x00B5 | Intuos3 WS PTZ-631W ✓ | intuos3 | 54204 | 31750 | 2046 | 8 | — | dual | ✓ |
| 0x00B7 | Intuos3 PTZ-431W | intuos3 | 31496 | 19685 | 1023 | 4 | — | — | ✓ |
| 0x00B8–0x00BC | Intuos4 (S/M/L/XL/WL) | intuosV1 | varies | varies | 2047 | 8 | ✓ | — | ✓ |
| 0x0026–0x0028 | Intuos5 (S/M/L) | intuosV1 | varies | varies | 2047 | 8 | ✓ | — | ✓ |
| 0x0314–0x0317 | Intuos Pro gen1 (S/M/L) | intuosV1 | varies | varies | 2047 | 8 | ✓ | — | ✓ |
| 0x0352/0x0357/0x0358 | Intuos Pro gen2 (S/M/L) ✓ | intuosV2 | varies | varies | 8191 | 8 | ✓ | — | ✓ |
| 0x00C0 | Cintiq 20WSX | intuosV1 | 86680 | 54180 | 1023 | 4 | — | — | ✓ |
| 0x00C4/0x0304 | Cintiq 13HD DTK-1300 | intuosV1 | ~59k | ~34k | 2047 | 0–8 | — | — | ✓ |
| 0x00C6 | Cintiq 12WX | intuosV1 | 53020 | 33440 | 1023 | 8 | — | — | ✓ |
| 0x00CC | Cintiq 21UX DTZ-2100 ² | intuosV1 | 87200 | 65600 | 1023 | 8 | — | — | ✓ |
| 0x00F4 | Cintiq 24HD DTK-2400 ✓ | intuosV1 | 104480 | 65600 | 2047 | 8 | dual | — | ✓ |
| 0x00F8 | Cintiq 24HD Touch DTH-2400 | intuosV1 | 104480 | 65600 | 2047 | 8 | dual | — | ✓ |
| 0x00FA/0x00F9 | Cintiq 22HD DTK-2200 | intuosV1 | ~95k | ~54k | 2047 | 8–20 | ✓ | — | ✓ |
| 0x00FB | Cintiq 21UX 2 DTZ-2100B | intuosV1 | 87200 | 65600 | 1023 | 8 | — | — | ✓ |
| 0x034F/0x0390/0x03AE | Cintiq 16/DTH-1320 | intuosV2 | varies | varies | 8191 | 0 | — | — | ✓ |
| 0x03A6 | DTC-133 | intuosV2 | 29434 | 16556 | 4095 | 0 | — | — | ✓ |
| 0x03C0 | Cintiq Pro 27 DTH-271 | intuosV2 | 120032 | 67868 | 8191 | 4 | — | — | ✓ |
| 0x03F0 | Movink 13 DTH-135 | intuosV2 | 59552 | 33848 | 8191 | 0 | — | — | ✓ |

> ¹ PID 0x003F uses the **PL protocol** (`wacom_pl_irq`), not graphire — the registry's `graphire` classification is a routing shortcut. See PL decode below.
> ² PID 0x00CC uses the CINTIQ kernel type, which requires the **RDY bit** (`d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x40`) to process data — the only IntuosV1 device in the registry with this gate.

***

## Parser Family 1 — `graphire`

**Kernel function:** `wacom_graphire_irq()` · **Report ID:** `0x01` · **Length:** 8 bytes

### Pen Report Byte Map

```
01  d1  d2  d3  d4  d5  d6  d7
```

| Byte | Field | Formula |
|---|---|---|
| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` | Status byte | see table below |
| `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html):d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384)` | **X position** | `LE16(d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html):d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384))` — little-endian |
| `d[4]:d[5]` | **Y position** | `LE16(d[4]:d[5])` — little-endian |
| `d[6]` | Pressure low 8 bits | see formula |
| `d[7]` | Pressure high bits + pad | `(d[7] & 0x03) << 8` |

### Status Byte `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)`

| Bits | Field | Values |
|---|---|---|
| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x80` | **Proximity** | `1` = in range |
| `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) >> 5) & 0x03` | **Tool type** | `0`=Pen, `1`=Eraser, `2`=Mouse+wheel, `3`=Mouse |
| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x04` | **BTN_STYLUS2** (barrel 2) | — |
| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x02` | **BTN_STYLUS** (barrel 1) | — |
| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x01` | **BTN_TOUCH** | tip contact |

### Pressure

```
pressure = d[6] | ((d[7] & 0x03) << 8)   // 10-bit, 0–1023 (Graphire 1–4, MTE-450)
```

No tilt on any graphire device. No rotation.

### Pad Buttons (inline in `d[7]`)

Graphire has **no separate pad report ID**. Buttons are encoded in the tail of the pen report:

| Sub-type | Model | Button bits in `d[7]` |
|---|---|---|
| `WACOM_G4` | Graphire 4 (0x0015/0x0016) | `d[7]&0x40`=BTN_BACK, `d[7]&0x80`=BTN_FORWARD; `REL_WHEEL = ((d[7]&0x18)>>3) - ((d[7]&0x20)>>3)` |
| `WACOM_MO` | Bamboo Fun MTE-450 (0x0017) | `d[7]&0x08`=BTN_BACK, `d[7]&0x20`=BTN_LEFT, `d[7]&0x10`=BTN_FORWARD, `d[7]&0x40`=BTN_RIGHT; `ABS_WHEEL = d[8] & 0x7F` ⚠ requires 9-byte read |
| All others | Graphire 1–3, Volito, Bamboo One | No pad report |

***

### PenPartner Special Case (0x0003)

**Kernel function:** `wacom_penpartner_irq()` — entirely different byte layout despite sharing the `graphire` parser bucket:

```
01  d1  d2  d3  d4  d5  d6  d7     (case 1)
02  d1  d2  d3  d4  d5  d6  d7     (case 2)
```

| Field | Formula |
|---|---|
| **X** | `LE16(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt):d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html))` |
| **Y** | `LE16(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384):d[4])` |
| **Proximity** | `d[5] & 0x80` |
| **Tool** | `d[5] & 0x20` ? Eraser : Pen |
| **Pressure** | `(int8_t)d[6] + 127` → range 0–254 (8-bit unsigned output) |
| **BTN_TOUCH** | `(int8_t)d[6] > -127` |
| **BTN_STYLUS** | `d[5] & 0x40` |

***

### PL Protocol Special Case (0x003F — Cintiq 21UX DTZ-2100 original)

**Kernel function:** `wacom_pl_irq()` — completely distinct from graphire:

```
01  d1  d2  d3  d4  d5  d6  d7
```

| Field | Formula |
|---|---|
| **Proximity** | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x40` |
| **Eraser detect** | `(d[0] & 0x10) \|\| (d[4] & 0x20)` |
| **X** | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) \| (d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) << 7) \| ((d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x03) << 14)` — 17-bit |
| **Y** | `d[6] \| (d[5] << 7) \| ((d[4] & 0x03) << 14)` — 17-bit |
| **Pressure (9-bit)** | `(int8_t)((d[7] << 1) \| ((d[4] >> 2) & 1)) + 128` |
| **BTN_TOUCH** | `d[4] & 0x08` |
| **BTN_STYLUS** | `d[4] & 0x10` |
| **BTN_STYLUS2** (pen only) | `d[4] & 0x20` |

***

## Parser Family 2 — `intuos3`

**Kernel function:** `wacom_intuos_irq()` with type `INTUOS3S/INTUOS3/INTUOS3L` · **Pen Report ID:** `0x02` · **Length:** 10 bytes

The wire format is structurally identical to `intuosV1` but with **two key behavioral differences**:

1. **Bit 6 (`0x40`) of `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` is a data-proximity indicator** for streaming packets — set when the pen is in active near-surface proximity, clear when hovering far from the surface (but still within detectable range). The `intuosV1` CINTIQ type uses the same bit as a hard gate (drop packet if clear); `intuos3` uses it informatively only.
2. **Pad aux reports use IDs `0x03` and `0x0C`** (not `0x11`).
3. **Two-stage feature init**: send `[0x02, 0x02]` immediately on open, then `[0x04, 0x00]` after 150 ms.

### Pen Report — Same decode as intuosV1

See the full `intuosV1` pen decode below. All formulas (X, Y, pressure, tilt, rotation, enter/exit prox, tool serial) are identical.

### Observable `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` Status Byte States (intuos3)

| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` | Pattern check | Meaning |
|---|---|---|
| `0xC0`–`0xCF` | `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0xFC) == 0xC0` | **Enter prox** — serial/tool-ID packet |
| `0x20` or `0x21` | `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0xFE) == 0x20` | **In range** (hover exit sequence) |
| `0x80` | `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0xFE) == 0x80` | **Exit prox** |
| `0xE0`–`0xFF` | none of the above + `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)&0x40` | **Data packet, pen near-surface** |
| `0xA0`–`0xBF` | none of the above + `!(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)&0x40)` | **Data packet, pen far hover** |

### Pad Report `0x0C` — 10 bytes (confirmed on PTZ-631W) [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)

```
0C  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

| Field | Bytes | Formula |
|---|---|---|
| **Left touch strip** (strip1) | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt):d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` | `((d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x1F) << 8) \| d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` — 13-bit, `0` = finger off |
| **Right touch strip** (strip2) | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384):d[4]` | `((d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) & 0x1F) << 8) \| d[4]` — 13-bit, `0` = finger off |
| **ExpressKeys 0–3** | `d[5]` | bits 3–0 |
| **ExpressKeys 4–7** | `d[6]` | bits 3–0 |
| **ExpressKey 8** | `d[5]` bit 4 | additional key |
| **ExpressKey 9** | `d[6]` bit 4 | additional key |

Combined button mask: `buttons = ((d[6]&0x10)<<5) | ((d[5]&0x10)<<4) | ((d[6]&0x0F)<<4) | (d[5]&0x0F)`

All-zero packet `0C 00 00 00 00 00 00 00 00 00` = finger lifted from strip / all buttons released.

PTZ-431 and PTZ-431W have only 4 keys (bits 3–0 of `d[5]` only; `d[6]` unused).
Non-WS models have no touch strips (`d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt):d[4]` always 0).

***

## Parser Family 3 — `intuosV1`

**Kernel function:** `wacom_intuos_irq()` · **Pen Report ID:** `0x02` · **Length:** 10 bytes

This is the most complex family due to multiple pad-layout sub-types spanning Intuos 1 through Cintiq 24HD.

### Pen Report Byte Map

```
02  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

### Enter / Exit Proximity Packets

| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` pattern | Event | Notes |
|---|---|---|
| `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0xFC) == 0xC0` | **Enter prox** | Tool serial + ID embedded |
| `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0xFE) == 0x20` | **In range** | Hover confirmation / exit preamble |
| `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0xFE) == 0x80` | **Exit prox** | All state cleared |

**Enter-prox serial decode:**
```
serial  = ((d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) & 0x0F) << 28) | (d[4] << 20) | (d[5] << 12) | (d[6] << 4) | (d[7] >> 4)
tool_id = (d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) << 4) | (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) >> 4) | ((d[7] & 0x0F) << 16) | ((d[8] & 0xF0) << 8)
ABS_MISC = (tool_id & ~0xFFF) << 4 | (tool_id & 0xFFF)   // wacom_intuos_id_mangle()
```

### Tool Type from `tool_id`

| `tool_id` | Tool |
|---|---|
| `0x812`, `0x801`, `0x12802`, `0x012` | BTN_TOOL_PENCIL (inking pen) |
| `0x832`, `0x032` | BTN_TOOL_BRUSH (stroke pen) |
| `0x007`, `0x09c`, `0x094`, `0x017`, `0x806` | BTN_TOOL_MOUSE |
| `0x096`, `0x097`, `0x006` | BTN_TOOL_LENS (lens cursor) |
| `0xd12`, `0x912`, `0x112`, `0x913`, `0x902`, `0x10902` | BTN_TOOL_AIRBRUSH |
| `0x885`, `0x804`, `0x10804`, `0x204` | BTN_TOOL_PEN + **rotation** (Art Pen / Marker Pen) |
| `tool_id & 0x0008` set | BTN_TOOL_RUBBER (eraser) |
| default | BTN_TOOL_PEN |

### Data Packet — General Pen (`type = (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)>>1) & 0x0F`, cases `0x00`–`0x03`)

| Field | Formula | Notes |
|---|---|---|
| **X** | `(BE16(d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html):d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384)) << 1) \| ((d[9] >> 1) & 1)` | 17-bit; Intuos 1/2: `>> 1` after |
| **Y** | `(BE16(d[4]:d[5]) << 1) \| (d[9] & 1)` | 17-bit; Intuos 1/2: `>> 1` after |
| **Distance** | `d[9] >> 2` | hover height; Intuos 1/2: `>> 1` |
| **Pressure** | `(d[6] << 3) \| ((d[7] & 0xC0) >> 5) \| (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 1)` | 10-bit raw; `>> 1` if `maxPressure < 2047` |
| **Tilt X** | `(((d[7] << 1) & 0x7E) \| (d[8] >> 7)) - 64` | signed ±63 |
| **Tilt Y** | `(d[8] & 0x7F) - 64` | signed ±63 |
| **BTN_STYLUS** | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x02` | barrel button 1 |
| **BTN_STYLUS2** | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x04` | barrel button 2 |
| **BTN_TOUCH** | `pressure > 10` | after formula |

> **CINTIQ type gate** (PID 0x00CC only): if `!(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x40)`, drop the entire packet. All other `intuosV1` devices — including WACOM_24HD — process data unconditionally.

### Rotation Packet (`type 0x05` — Art Pen / Intuos3 Marker Pen)

```
t = (d[6] << 3) | ((d[7] >> 5) & 7)
ABS_Z = (d[7] & 0x20) ? ((t > 900) ? ((t-1)/2 - 1350) : ((t-1)/2 + 450)) : (450 - t/2)
// Range ±900 in 0.5° steps
```
Only generated by Art Pen (0x10804), Marker Pen (0x885/0x804), and Art Pen 2 (0x204).

### Airbrush Wheel Packet (`type 0x0A`)

```
ABS_WHEEL = (d[6] << 2) | ((d[7] >> 6) & 3)    // 10-bit fingerwheel
ABS_TILT_X and ABS_TILT_Y — same formula as general packet
```

### Intuos4 Mouse Packet (`type 0x06`)

| Field | Formula |
|---|---|
| BTN_LEFT | `d[6] & 0x01` |
| BTN_MIDDLE | `d[6] & 0x02` |
| BTN_RIGHT | `d[6] & 0x04` |
| BTN_SIDE | `d[6] & 0x08` |
| BTN_EXTRA | `d[6] & 0x10` |
| REL_WHEEL | `((d[7]&0x80)>>7) - ((d[7]&0x40)>>6)` |
| Tilt X/Y | same general formula |

### Intuos 2D Mouse Packet (`type 0x08`)

| Field | Formula |
|---|---|
| BTN_LEFT | `d[8] & 0x04` |
| BTN_MIDDLE | `d[8] & 0x08` |
| BTN_RIGHT | `d[8] & 0x10` |
| REL_WHEEL | `(d[8]&0x01) - ((d[8]&0x02)>>1)` |
| BTN_SIDE *(Intuos3 only)* | `d[8] & 0x40` |
| BTN_EXTRA *(Intuos3 only)* | `d[8] & 0x20` |

***

### Pad Reports — Sub-type Matrix

All pad reports are dispatched through `wacom_intuos_pad()`. The pad report ID differs by generation:

| Generation | Pad Report ID |
|---|---|
| Intuos 1/2 (0x002x, 0x004x) | `0x02` (inline with pen, via data) |
| Intuos3 | `0x0C` (see intuos3 section) |
| Intuos4 (PTK-xxx) | `0x12` |
| Intuos5 / Intuos Pro gen1 | `0x11` |
| Cintiq displays (24HD, 22HD, 21UX2, etc.) | `0x11` |

### Pad Button Decode by Sub-type

**Intuos4 (`INTUOS4S`–`INTUOS4L`, 0x00B8–0x00BB)**
```
buttons = (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) << 1) | (d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) & 0x01)    // 9 bits
ring1   = d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)                             // touch ring position (0x80 = active; pos = val & 0x7F)
```
ABS_WHEEL reports `(ring1 & 0x80) ? (ring1 & 0x7F) : 0`.

**Intuos5 / Intuos Pro gen1 (`INTUOS5S`–`INTUOSPL`, 0x0026–0x0317)**
```
buttons = (d[4] << 1) | (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) & 0x01)    // 9 bits; d[5] = capacitive sensor data (informational)
ring1   = d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)                             // touch ring; bit 7 = active, bits 6–0 = position
```

**Cintiq 13HD (`WACOM_13HD`, 0x00C4/0x0304)**
```
buttons = (d[4] << 1) | (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) & 0x01)
// No ring; 0 keys on 0x00C4, 8 keys on 0x0304
```

**Cintiq 24HD (`WACOM_24HD`, 0x00F4, 0x00F8)**
```
buttons = (d[8] << 8) | d[6]             // 16 express keys (8 per side)
ring1   = d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)                            // left touch ring
ring2   = d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)                            // right touch ring
// Touch strip emulated by 3 macro keys:
keys = ((d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) & 0x1C) ? 1<<2 : 0) | ((d[4] & 0xE0) ? 1<<1 : 0) | ((d[4] & 0x07) ? 1<<0 : 0)
// → keyboard shortcut (d[4]&0xE0), info (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384)&0x1C), wrench/mute (d[4]&0x07)
```

ABS_WHEEL (left ring): `(ring1 & 0x80) ? (ring1 & 0x7F) : 0`
ABS_THROTTLE (right ring): `(ring2 & 0x80) ? (ring2 & 0x7F) : 0`

**Cintiq 22HD (`WACOM_22HD`, 0x00FA/0x00F9)**
```
buttons = (d[8] << 10) | ((d[7] & 0x01) << 9) | (d[6] << 1) | (d[5] & 0x01)   // 18 bits
ring1   = d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)
keys    = d[9] & 0x07    // 3 function keys: info (bit 0), wrench (bit 1), bit 2
```

**Cintiq 21UX 2 (`WACOM_21UX2`, 0x00FB)**
```
buttons = (d[8] << 10) | ((d[7] & 0x01) << 9) | (d[6] << 1) | (d[5] & 0x01)   // 18 bits
// No ring
```

**Standard Cintiq / Intuos 1–2 fallback**
```
buttons = ((d[6]&0x10)<<5) | ((d[5]&0x10)<<4) | ((d[6]&0x0F)<<4) | (d[5]&0x0F)
strip1  = ((d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x1F) << 8) | d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)
strip2  = ((d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) & 0x1F) << 8) | d[4]
```

***

## Parser Family 4 — `intuosV2`

**Devices:** Intuos Pro gen2 (PTH-460/660/860), Cintiq 16, DTH-1320, DTC-133, Cintiq Pro 27, Movink 13

**Pen Report ID:** `0x10` · **Length:** 192 bytes · **Coordinates:** LE24 (little-endian 24-bit) · **Pressure:** 13-bit (0–8191)

The gen2 devices abandon the 10-byte legacy format for a HID-descriptor-driven layout. The 192-byte buffer is the USB HID input report declared in the descriptor; most bytes beyond byte 12 are padding. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

### Pen Report Byte Map

```
10  d1  d2  d3  d4  d5  d6  d7  d8  d9  d10  d11  [d12..d191 = 0x00]
```

| Field | Bytes | Formula |
|---|---|---|
| **X position** | `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html):d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384):d[4]` | `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) \| (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) << 8) \| (d[4] << 16)` — LE24 |
| **Y position** | `d[5]:d[6]:d[7]` | `d[5] \| (d[6] << 8) \| (d[7] << 16)` — LE24 |
| **Pressure** | `d[8]:d[9]` | `d[8] \| ((d[9] & 0x1F) << 8)` — 13-bit LE |
| **Tilt X** | `d[10]` | signed int8 (±127 → maps to ±63 in normalized output) |
| **Tilt Y** | `d[11]` | signed int8 |
| **BTN_TOUCH** | — | pressure > threshold |
| **BTN_STYLUS** | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x02` |
| **BTN_STYLUS2** | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` | `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt) & 0x04` |

### Status Byte `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` States

| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/e0ab6dc0-857f-43c4-a5eb-25b6378285ae/mocktab_capture_20260327_205151.txt)` | State |
|---|---|
| `0xC0` (+ tool ID bytes) | Enter prox |
| `0x20` / `0x21` | Hover (in range, not touching) |
| `0x25` | Hover + BTN_STYLUS2 |
| `0x60` | Tip touching |
| `0x61` | Tip + BTN_STYLUS |
| `0x65` | Tip + BTN_STYLUS2 |
| `0x28` | Eraser hover |
| `0x68` | Eraser touching |
| `0x80` | Exit prox |

### BLE / HOGP Variant

PTH-460/660/860 also operate over Bluetooth (BLE HOGP). Report IDs differ:

| Report ID | Content |
|---|---|
| `0x01` | Pen data (same field layout as USB `0x10`) |
| `0x03` | Pad / button / ring data |

### Pad Report — Intuos Pro gen2

```
03  d1  d2  d3  d4  ...
buttons = (d[4] << 1) | (d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt?AWSAccessKeyId=ASIA2F3EMEYE6EZH5TXL&Signature=UrFd389MAo4Sl3xCIAioOJsQXmI%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEC4aCXVzLWVhc3QtMSJHMEUCIQDbRwPAEaWPhqYK7EjZh9yEwE7gmBjWdyAH77M%2Bl21AQQIgBwmNya5VGp1Uamr%2BsACbuAF7N748kR9mUzYwjHI2YiAq%2FAQI9%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FARABGgw2OTk3NTMzMDk3MDUiDPSzYah%2BXYdpB51A4CrQBKiK%2FhH8%2Fy3IJ38G1jfxEFcAyl35mLUtP6Uu8s69eVi5%2FU0R6FIz1qkQxQDWNhUSfNSVw16Y2ldGTC9DHm205EV1lXliUP1exPQim90O82FPyHKQUEMr4y62tggmCX%2BPOeFpfu4et6NIgrLRc%2BjLkSCNwfw18ZouMeWJCBbduZLMxeQADEiZ747y6G%2FnvlUVHjHUZex4V9CUpiR8BOe0rXwQ%2BtqM1Aj2fm9RH%2F5O6j4Ptazpp3rfe7pc7ECT9DK%2Boo7XdjoOPMHhDhMLzMplIjzILBOhgkJEIgFiUwcmk9fC6%2Fh0MfLaWbKtzYdDyp8OHHY4qeNclf6lkMOx89DbtH5B1wKv5DAyVOEalZ70PXn9mVEF%2FKCtiwOoYx%2BsE8MmynVIt7M6ErRw8hinrCEeV8DQaCgw8wTR0WmIlKQoCDoZPRbzXKGkIPEkc%2Bw1ypaoWXyk2BZQEQbjeYPv3KPF74Vvxqai1JXPuCGaiFwocUBg1ZzlSzCF%2BcNPhSCFgmiJcszQxlng%2BcF%2BjugFH2dBFV32zqula7yc1CkFDRZrT4YzTKWhG6N0zrtjZ9cAGBrCHJG1Q9MO22rFRCxW9H4KhZUqoLSf%2BaCwbtT%2B3y4DMzqegeJ2adO1OColS0pE%2FcBYE7a3eORo%2BVNm5%2FbsylSJbopmLnforgsyhyKK01qzPE2ARO2WgXqI5i3d%2FyCUHulDeDQ6ez6DfbjAxdCUiaZ0Xexl8saynbmBfGCOIelVKlExBxTzebgV0YJq6fDHf2F4yzZUFQuKynFI1ELSg9kgeWww77efzgY6mAF0Uir2dnH1om%2Bh17ON3yTmJfdDCk%2BuR8b2xXkitskwO3Au4tYQfqmcjJo6CW5lHbahfHKEu24c9sCDSapZoRGGGoXUwpXtPimvOSjOAKlfZ8rAoTTMsQerm%2BfhWwGywShk5XY4mbTUaqWkdJEAML2u9nEz34icU55%2B%2BVL0VRM58Ul%2BvFQ26zP6Z7ftWHW3JhoLCf7JkNxJBw%3D%3D&Expires=1774706384) & 0x01)
ring1   = d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)     // bit 7 = active, bits 6–0 = position (0–71)
```

***

## `bamboo` Parser — Full HID Decode

**Kernel function:** `wacom_bpt_irq()` dispatching to `wacom_bpt_pen()` · **Report ID:** `0x10` · **Length:** 10 bytes

The Bamboo line uses Report ID `0x10` (same as intuosV2) but with a **completely different, shorter** layout and no tool-serial negotiation. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

### Pen / Eraser Report — `wacom_bpt2_pen()`

```
10  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

| Byte(s) | Field | Formula |
|---|---|---|
| `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204)` | Status byte | see table |
| `d [opentabletdriver](https://opentabletdriver.net/Wiki/Documentation/ConfigurationGuide):d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` | **X position** | `BE16(d [opentabletdriver](https://opentabletdriver.net/Wiki/Documentation/ConfigurationGuide):d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html))` |
| `d [reddit](https://www.reddit.com/r/wacom/comments/1pf2gah/guide_how_to_make_legacy_wacom_tablets_work_on/):d [reddit](https://www.reddit.com/r/wacom/comments/l2kffs/wacom_bamboo_pen_doesnt_move_the_cursor_but_my/)` | **Y position** | `BE16(d [reddit](https://www.reddit.com/r/wacom/comments/1pf2gah/guide_how_to_make_legacy_wacom_tablets_work_on/):d [reddit](https://www.reddit.com/r/wacom/comments/l2kffs/wacom_bamboo_pen_doesnt_move_the_cursor_but_my/))` |
| `d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt):d [github](https://github.com/linuxwacom/wacom-hid-descriptors)` | **Pressure** | `(d [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt) << 3) \| (d [github](https://github.com/linuxwacom/wacom-hid-descriptors) >> 5)` — 11-bit for 2047-max devices; `>> 1` if maxPressure ≤ 1023 |
| `d [github](https://github.com/linuxwacom/wacom-hid-descriptors)` | **Tilt X** | `(d [github](https://github.com/linuxwacom/wacom-hid-descriptors) & 0x0F) - 8` — 4-bit signed (CTH-480/490 only) |
| `d [reddit](https://www.reddit.com/r/AskElectronics/comments/1qke9d/need_usb_hid_report_descriptor_and_report_format/)` | **Tilt Y** | `(d [reddit](https://www.reddit.com/r/AskElectronics/comments/1qke9d/need_usb_hid_report_descriptor_and_report_format/) >> 4) - 8` — 4-bit signed (CTH-480/490 only) |

### Status Byte `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204)`

| Bit | Field |
|---|---|
| `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204) & 0x80` | **Proximity** (in range) |
| `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204) & 0x20` | **Proximity confirm** (alternate bit on some models) |
| `(d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204) >> 3) & 0x03` | **Tool type**: `0`=Pen, `1`=Eraser, `2`=Mouse |
| `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204) & 0x02` | **BTN_STYLUS** (barrel button 1) |
| `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204) & 0x04` | **BTN_STYLUS2** (barrel button 2) |
| `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204) & 0x01` | **BTN_TOUCH** (tip contact) |

No tool-serial or tool-ID mechanism — eraser is identified via the type bits in `d [github](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204)` alone, not from a prior enter-prox packet. This means **no `ABS_MISC` tool-ID reporting** on Bamboo.

### Tilt Availability

Tilt (`ABS_TILT_X`, `ABS_TILT_Y`) only appears on CTH-480 and CTH-490 (the later "Intuos Pen & Touch" rebrand). All earlier CTH-460/470 and all CTL pen-only models report tilt as 0. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

### Pad Report — `wacom_bpt_pad()`

The Bamboo pad is inline with the pen report (no separate pad Report ID):

```
10  d1  ...  d7  d8  d9
```

| Field | Formula | Models |
|---|---|---|
| **BTN_0** | `d [github](https://github.com/linuxwacom/wacom-hid-descriptors) & 0x08` | CTH-460/470/480/490 |
| **BTN_1** | `d [github](https://github.com/linuxwacom/wacom-hid-descriptors) & 0x20` | CTH-460/470/480/490 |
| **BTN_2** | `d [github](https://github.com/linuxwacom/wacom-hid-descriptors) & 0x10` | CTH-460/470/480/490 |
| **BTN_3** | `d [github](https://github.com/linuxwacom/wacom-hid-descriptors) & 0x40` | CTH-460/470/480/490 |
| **BTN_0** | `d [github](https://github.com/linuxwacom/wacom-hid-descriptors) & 0x01` | CTL-460/470 (pen-only, 2 keys) |
| **BTN_1** | `d [github](https://github.com/linuxwacom/wacom-hid-descriptors) & 0x02` | CTL-460/470 (pen-only, 2 keys) |

Pad proximity (the `ABS_MISC = PAD_DEVICE_ID` signal) fires when any button bit in `d [github](https://github.com/linuxwacom/wacom-hid-descriptors)` is non-zero; it clears on all-zero.

### Touch — `wacom_bpt3_touch()`

CTH models with touch (CTH-460/470/480/490) generate a **separate 20-byte multitouch report** on a second USB interface (Report ID `0x02`). This is not a pen-tablet HID report — it uses HID multitouch descriptors with up to 16 contact points. It is entirely separate from the pen interface and requires a distinct decoder. The pen interface report length stays 10 bytes regardless. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

### CTT-460 (Touch-Only)

PID `0x00D0` has **no pen interface at all** — only the 20-byte multitouch touch interface. `maxPressure = 0` in your registry correctly signals this. There is nothing to decode on the pen path. [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/16788129/3db156af-7cbe-421d-99b9-2d57494eaaa1/WacomDeviceRegistry.txt)
***

## Feature Init Summary

| Parser | featureInit | featureInit2 | Delay |
|---|---|---|---|
| graphire | none | — | — |
| intuos3 | `[0x02, 0x02]` | `[0x04, 0x00]` | 150 ms |
| intuosV1 (most) | `[0x02, 0x02]` | — | — |
| intuosV1 Cintiq displays | `[0x02, 0x02]` + `seizeUSB` | — | — |
| intuosV2 PTH-660/860 | none + `seizeUSB` | — | — |
| intuosV2 newer Cintiqs | `[0x02, 0x02]` | — | — |
| bamboo | none | — | — |