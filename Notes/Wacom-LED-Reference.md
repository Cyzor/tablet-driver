2026-04-19

Wacom LED Notes


## 1. Central LED control path

`wacom_led_control()` is the dispatcher for all LED-related behavior. It composes one HID feature report whose format depends on the tablet type. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

```c
static int wacom_led_control(struct wacom *wacom)
{
	unsigned char *buf;
	int retval;
	unsigned char report_id = WAC_CMD_LED_CONTROL;
	int buf_size = 9;

	if (!wacom->led.groups)
		return -ENOTSUPP;

	if (wacom->wacom_wac.features.type == REMOTE)
		return -ENOTSUPP;

	if (wacom->wacom_wac.pid) { /* wireless connected */
		report_id = WAC_CMD_WL_LED_CONTROL;
		buf_size = 13;
	}
	else if (wacom->wacom_wac.features.type == INTUOSP2_BT) {
		report_id = WAC_CMD_WL_INTUOSP2;
		buf_size = 51;
	}

	buf = kzalloc(buf_size, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
```

Model differentiation happens immediately after the allocation:

```c
	if (wacom->wacom_wac.features.type == HID_GENERIC) {
		buf[0] = WAC_CMD_LED_CONTROL_GENERIC;
		buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = wacom->led.llv;
		buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5) = wacom->led.groups[0].select & 0x03;

	} else if ((wacom->wacom_wac.features.type >= INTUOS5S &&
	    wacom->wacom_wac.features.type <= INTUOSPL)) {
		/* Touch Ring and crop mark LED luminance may take on
		 * one of four values:
		 *    0 = Low; 1 = Medium; 2 = High; 3 = Off
		 */
		int ring_led = wacom->led.groups[0].select & 0x03;
		int ring_lum = (((wacom->led.llv & 0x60) >> 5) - 1) & 0x03;
		int crop_lum = 0;
		unsigned char led_bits =
			(crop_lum << 4) | (ring_lum << 2) | (ring_led);

		buf[0] = report_id;
		if (wacom->wacom_wac.pid) {
			wacom_get_report(wacom->hdev, HID_FEATURE_REPORT,
					 buf, buf_size, WAC_CMD_RETRIES);
			buf[0] = report_id;
			buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific) = led_bits;
		} else
			buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = led_bits;
	}
	else if (wacom->wacom_wac.features.type == INTUOSP2_BT) {
		buf[0] = report_id;
		buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific) = 100; // Power Connection LED (ORANGE)
		buf [davidrevoy](https://www.davidrevoy.com/article70/set-the-led-display-of-the-wacom-intuos4-tablet-on-ubuntu-linux) = 100; // BT Connection LED (BLUE)
		buf [reddit](https://www.reddit.com/r/linuxmint/comments/1g9ni1b/i_am_so_frustrated_over_my_wacom_tablet_not/) = 100; // Paper Mode (RED?)
		buf [bbs.archlinux](https://bbs.archlinux.org/viewtopic.php?id=159088) = 100; // Paper Mode (GREEN?)
		buf [github](https://github.com/torvalds/linux/blob/master/drivers/input/tablet/wacom_serial4.c) = 100; // Paper Mode (BLUE?)
		buf [reddit](https://www.reddit.com/r/wacom/comments/1hle2zj/revive_your_old_wacom_tablets_on_macos_with/) = wacom->led.llv;
		buf [github](https://github.com/torvalds/linux/blob/master/drivers/leds/leds-aw2013.c) = wacom->led.groups[0].select & 0x03;
	}
	else {
		int led = wacom->led.groups[0].select | 0x4;

		if (wacom->wacom_wac.features.type == WACOM_21UX2 ||
		    wacom->wacom_wac.features.type == WACOM_24HD)
			led |= (wacom->led.groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).select << 4) | 0x40;

		buf[0] = report_id;
		buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = led;
		buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5) = wacom->led.llv;
		buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c) = wacom->led.hlv;
		buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific) = wacom->led.img_lum;
	}

	retval = wacom_set_report(wacom->hdev, HID_FEATURE_REPORT,
				  buf, buf_size, WAC_CMD_RETRIES);
	kfree(buf);
	return retval;
}
```

### Summary of report layouts

| Device category                         | report_id                            | Key bytes and meaning                                     |
|----------------------------------------|--------------------------------------|-----------------------------------------------------------|
| HID_GENERIC                            | `WAC_CMD_LED_CONTROL_GENERIC`        | `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)=llv`, `buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5)=select & 0x03`                     |
| Intuos5/Pro (INTUOS5S..INTUOSPL)       | `report_id` (`WAC_CMD_LED_CONTROL` or WL variant) | `led_bits` packed into `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)` or `buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)`              |
| Intuos Pro 2 BT (INTUOSP2_BT)          | `WAC_CMD_WL_INTUOSP2`                | `buf[4..8]=100`, `buf [reddit](https://www.reddit.com/r/wacom/comments/1hle2zj/revive_your_old_wacom_tablets_on_macos_with/)=llv`, `buf [github](https://github.com/torvalds/linux/blob/master/drivers/leds/leds-aw2013.c)=select & 0x03`   |
| Cintiq 21UX2 / 24HD and similar        | `WAC_CMD_LED_CONTROL` or wireless ID | `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)=combined led`, `buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5)=llv`, `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c)=hlv`, `buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)=img_lum` |

All paths end in one HID feature report write; the difference is how the driver encodes `select`, low/high luminance, and button-image brightness for each family. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

***

## 2. HID_GENERIC devices

For devices with `features.type == HID_GENERIC`, LED control is very simple: [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

```c
if (wacom->wacom_wac.features.type == HID_GENERIC) {
	buf[0] = WAC_CMD_LED_CONTROL_GENERIC;
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = wacom->led.llv;
	buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5) = wacom->led.groups[0].select & 0x03;
}
```

### Byte-level behavior

- `buf[0]` – command ID (generic LED control).
- `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)` – low-level luminance (`llv`), masked elsewhere to 7 bits.
- `buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5)` – `select` for group 0, truncated to 2 bits.

For a HID_GENERIC device, if user space updates `status0_luminance` and `status_led0_select`, the kernel will:

1. Store the new luminance into `wacom->led.llv`.
2. Store the new selection (0–3) into `wacom->led.groups[0].select`.
3. Call `wacom_led_control()`, which writes this 3-byte payload.

This makes HID_GENERIC a good reference case for minimal LED support.

***

## 3. Intuos5 / Intuos Pro (INTUOS5S..INTUOSPL)

The driver treats Intuos5 / Pro as having a combined “ring LED” and “crop mark LED” state packed into a single nibble field. [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5)

```c
} else if ((wacom->wacom_wac.features.type >= INTUOS5S &&
    wacom->wacom_wac.features.type <= INTUOSPL)) {
	/*
	 * Touch Ring and crop mark LED luminance may take on
	 * one of four values:
	 *    0 = Low; 1 = Medium; 2 = High; 3 = Off
	 */
	int ring_led = wacom->led.groups[0].select & 0x03;
	int ring_lum = (((wacom->led.llv & 0x60) >> 5) - 1) & 0x03;
	int crop_lum = 0;
	unsigned char led_bits =
		(crop_lum << 4) | (ring_lum << 2) | (ring_led);

	buf[0] = report_id;
	if (wacom->wacom_wac.pid) {
		wacom_get_report(wacom->hdev, HID_FEATURE_REPORT,
				 buf, buf_size, WAC_CMD_RETRIES);
		buf[0] = report_id;
		buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific) = led_bits;
	} else
		buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = led_bits;
}
```

### Decoding `led_bits`

`led_bits` encodes three 2-bit values:

- Bits 0–1: `ring_led` – which ring LED quadrant or mode is active (0–3).
- Bits 2–3: `ring_lum` – ring luminance encoded as:
  - `ring_lum = (((llv & 0x60) >> 5) - 1) & 0x03`
  - This maps specific `llv` bits (5–6) into 2-bit brightness levels (0–3).
- Bits 4–5: `crop_lum` – crop-mark LED luminance (currently hard-coded 0).

The code comment also defines the 2-bit brightness semantics:

```c
/* 0 = Low; 1 = Medium; 2 = High; 3 = Off */
```

### Wired vs wireless Intuos Pro

The function uses two different bytes depending on whether the tablet is in wireless/pid mode:

- Wired (`!pid`): 
  - `buf[0] = report_id;`
  - `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = led_bits;`
- Wireless (`pid != 0`):
  - Driver first fetches existing feature report:
    - `wacom_get_report(..., buf, buf_size, ...)`
  - Then sets:
    - `buf[0] = report_id;`
    - `buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific) = led_bits;`

So for wireless Intuos Pro, LED control overlays just one byte (` [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)`) in a broader feature report, while for wired devices, the driver sends a shorter report with the LED bits in ` [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)`.

***

## 4. Intuos Pro 2 Bluetooth (INTUOSP2_BT)

`INTUOSP2_BT` has the most distinctive layout, with several dedicated LED channels and a separate logical-level luminance (`llv`). [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

```c
else if (wacom->wacom_wac.features.type == INTUOSP2_BT) {
	buf[0] = report_id;
	buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific) = 100; // Power Connection LED (ORANGE)
	buf [davidrevoy](https://www.davidrevoy.com/article70/set-the-led-display-of-the-wacom-intuos4-tablet-on-ubuntu-linux) = 100; // BT Connection LED (BLUE)
	buf [reddit](https://www.reddit.com/r/linuxmint/comments/1g9ni1b/i_am_so_frustrated_over_my_wacom_tablet_not/) = 100; // Paper Mode (RED?)
	buf [bbs.archlinux](https://bbs.archlinux.org/viewtopic.php?id=159088) = 100; // Paper Mode (GREEN?)
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/input/tablet/wacom_serial4.c) = 100; // Paper Mode (BLUE?)
	buf [reddit](https://www.reddit.com/r/wacom/comments/1hle2zj/revive_your_old_wacom_tablets_on_macos_with/) = wacom->led.llv;
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/leds/leds-aw2013.c) = wacom->led.groups[0].select & 0x03;
}
```

### Byte semantics (Intuos Pro 2 BT)

Within the `WAC_CMD_WL_INTUOSP2` feature report:

- `buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)` – power-connection LED brightness (orange channel), hard-coded to 100.
- `buf [davidrevoy](https://www.davidrevoy.com/article70/set-the-led-display-of-the-wacom-intuos4-tablet-on-ubuntu-linux)` – Bluetooth connection LED brightness (blue channel), also 100.
- `buf [reddit](https://www.reddit.com/r/linuxmint/comments/1g9ni1b/i_am_so_frustrated_over_my_wacom_tablet_not/)` – paper-mode red.
- `buf [bbs.archlinux](https://bbs.archlinux.org/viewtopic.php?id=159088)` – paper-mode green.
- `buf [github](https://github.com/torvalds/linux/blob/master/drivers/input/tablet/wacom_serial4.c)` – paper-mode blue.
- `buf [reddit](https://www.reddit.com/r/wacom/comments/1hle2zj/revive_your_old_wacom_tablets_on_macos_with/)` – general low-level luminance (`llv`).
- `buf [github](https://github.com/torvalds/linux/blob/master/drivers/leds/leds-aw2013.c)` – group 0 select (0–3).

The driver currently always writes “100” for the individual LEDs, so practical variation for this family is via `llv` and `select`. If you wanted fine-grained LED control for this model in user space, you would have to bypass `wacom_led_control()` or extend it to treat `buf[4..8]` as user-settable.

***

## 5. Cintiq 21UX2 / 24HD / 27QHD-style devices

The “catch-all” `else` clause is used for several display-tablet families, with a special case for 21UX2 and 24HD that have a second LED group. [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5)

```c
else {
	int led = wacom->led.groups[0].select | 0x4;

	if (wacom->wacom_wac.features.type == WACOM_21UX2 ||
	    wacom->wacom_wac.features.type == WACOM_24HD)
		led |= (wacom->led.groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).select << 4) | 0x40;

	buf[0] = report_id;
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = led;
	buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5) = wacom->led.llv;
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c) = wacom->led.hlv;
	buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific) = wacom->led.img_lum;
}
```

### Byte-level breakdown

- `buf[0]` – LED control report ID (wired or wireless variant).
- `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)` – `led` control field.
  - Common bit 2: `| 0x4` – base enable or “LED present” flag.
  - Bits 0–1: bottom bits of `groups[0].select`.
  - 21UX2 / 24HD:
    - Bits 4–7: `groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).select` plus `0x40` – enable flag for second LED group and its selection.
- `buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5)` – `llv` (low-level luminance).
- `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c)` – `hlv` (high-level luminance).
- `buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)` – `img_lum` (button image/OLED brightness).

This is the main path that drives:

- Status LED group 0.
- Status LED group 1 (for 21UX2/24HD).
- Per-button OLED / image brightness (via `img_lum`).

In other words, for a 24HD-class device:

- Basic “which side LED bank is active” is encoded in `groups[0].select` and `groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).select` and packed into `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)`.
- Overall brightness and any “high level” brightness/state are in `llv/hlv`.
- OLED/label intensity is controlled by `img_lum` in `buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)`.

***

## 6. Button images and OLEDs

The driver uploads button images as four chunks via `wacom_led_putimage()`. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

```c
static int wacom_led_putimage(struct wacom *wacom, int button_id, u8 xfer_id,
		const unsigned len, const void *img)
{
	unsigned char *buf;
	int i, retval;
	const unsigned chunk_len = len / 4; /* 4 chunks are needed to be sent */

	buf = kzalloc(chunk_len + 3 , GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	/* Send 'start' command */
	buf[0] = WAC_CMD_ICON_START;
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = 1;
	retval = wacom_set_report(wacom->hdev, HID_FEATURE_REPORT,
				  buf, 2, WAC_CMD_RETRIES);
	if (retval < 0)
		goto out;

	buf[0] = xfer_id;
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = button_id & 0x07;
	for (i = 0; i < 4; i++) {
		buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5) = i;
		memcpy(buf + 3, img + i * chunk_len, chunk_len);

		retval = wacom_set_report(wacom->hdev, HID_FEATURE_REPORT,
					  buf, chunk_len + 3, WAC_CMD_RETRIES);
		if (retval < 0)
			break;
	}

	/* Send 'stop' */
	buf[0] = WAC_CMD_ICON_START;
	buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = 0;
	wacom_set_report(wacom->hdev, HID_FEATURE_REPORT,
			 buf, 2, WAC_CMD_RETRIES);

out:
	kfree(buf);
	return retval;
}
```

### Protocol semantics

- Start command:
  - `buf[0] = WAC_CMD_ICON_START;`
  - `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = 1;` – start.
- For each of 4 chunks:
  - `buf[0] = xfer_id;` – command/report for icon data transfer.
  - `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = button_id & 0x07;` – lower 3 bits select button 0–7.
  - `buf [git.zx2c4](https://git.zx2c4.com/linux-rng/diff/?id=396e6e49c58bb23d1814d3c240c736c9f01523c5) = i;` – chunk index (0..3).
  - `buf[3..]` – `chunk_len` bytes of image data, contiguous slices of `img`.
- Stop command:
  - `buf[0] = WAC_CMD_ICON_START;`
  - `buf [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c) = 0;` – stop.

The driver does not hard-code pixel format here; the host must know from the device-specific HID descriptor or documentation how to interpret the image bytes. `img_lum` in `wacom_led_control()` then controls brightness of all these button images collectively.

***

## 7. Luminance, per-LED replication, and sysfs

Luminance is written through a generic helper that updates all `wacom->led` instances, then calls `wacom_led_control()`. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

```c
static ssize_t wacom_luminance_store(struct wacom *wacom, u8 *dest,
				     const char *buf, size_t count)
{
	unsigned int value;
	int err;

	err = kstrtouint(buf, 10, &value);
	if (err)
		return err;

	mutex_lock(&wacom->lock);

	*dest = value & 0x7f;
	for (unsigned int i = 0; i < wacom->led.count; i++) {
		struct wacom_group_leds *group = &wacom->led.groups[i];

		for (unsigned int j = 0; j < group->count; j++) {
			if (dest == &wacom->led.llv)
				group->leds[j].llv = *dest;
			else if (dest == &wacom->led.hlv)
				group->leds[j].hlv = *dest;
		}
	}

	err = wacom_led_control(wacom);

	mutex_unlock(&wacom->lock);

	return err < 0 ? err : count;
}
```

This function is then turned into sysfs attributes via a macro:

```c
#define DEVICE_LUMINANCE_ATTR(name, field)				 \
static ssize_t wacom_##name##_luminance_store(struct device *dev,	 \
					      struct device_attribute *attr, \
					      const char *buf, size_t count) \
{									 \
	struct wacom *wacom = dev_get_drvdata(dev);			 \
	return wacom_luminance_store(wacom, &wacom->led.field, buf, count);\
}									 \
static ssize_t wacom_##name##_luminance_show(struct device *dev,	 \
					     struct device_attribute *attr, \
					     char *buf)			 \
{									 \
	struct wacom *wacom = dev_get_drvdata(dev);			 \
	return sysfs_emit(buf, "%u\n", wacom->led.field);		 \
}									 \
static DEVICE_ATTR(name##_luminance, DEV_ATTR_RW_PERM,			 \
		   wacom_##name##_luminance_show,			 \
		   wacom_##name##_luminance_store)

DEVICE_LUMINANCE_ATTR(buttons, img_lum);
```

This generates sysfs entries such as:

- `buttons_luminance` → `wacom->led.img_lum`.
- (Elsewhere) `status0_luminance`, `status1_luminance` → `llv`/`hlv` fields.

So writing to `/sys/class/.../buttons_luminance` on a 24HD-class device sets `img_lum`, which the next `wacom_led_control()` call encodes into `buf [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)`.

***

## 8. LED selection via sysfs

Selection is controlled by `wacom_led_select_store()` and per-group wrappers. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

```c
static ssize_t wacom_led_select_store(struct device *dev, int set_id,
				      const char *buf, size_t count)
{
	struct wacom *wacom = dev_get_drvdata(dev);
	unsigned int id;
	int err;

	err = kstrtouint(buf, 10, &id);
	if (err)
		return err;

	if (id > 0x3)
		return -EINVAL;

	mutex_lock(&wacom->lock);

	wacom->led.groups[set_id].select = id & 0x3;
	err = wacom_led_control(wacom);

	mutex_unlock(&wacom->lock);

	return err < 0 ? err : count;
}
```

Macro to define group-specific attributes:

```c
#define DEVICE_LED_SELECT_ATTR(SET_ID)					\
static ssize_t wacom_led##SET_ID##_select_store(struct device *dev,	\
						struct device_attribute *attr, \
						const char *buf, size_t count)\
{									\
	return wacom_led_select_store(dev, SET_ID, buf, count);		\
}									\
static ssize_t wacom_led##SET_ID##_select_show(struct device *dev,	\
					       struct device_attribute *attr,\
					       char *buf)		\
{									\
	struct wacom *wacom = dev_get_drvdata(dev);			\
	return sysfs_emit(buf, "%u\n",					\
			 wacom->led.groups[SET_ID].select);		\
}									\
static DEVICE_ATTR(status_led##SET_ID##_select, DEV_ATTR_RW_PERM,	\
		    wacom_led##SET_ID##_select_show,			\
		    wacom_led##SET_ID##_select_store)
```

Then in the attribute list:

```c
DEVICE_LED_SELECT_ATTR(0);
DEVICE_LED_SELECT_ATTR(1);
```

These produce:

- `/sys/.../status_led0_select`
- `/sys/.../status_led1_select`

Writing 0–3 selects which status LED (within that group) is active. For families that pack multiple group bits (21UX2/24HD), `groups[0].select` and `groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).select` are both folded into the HID packet.

***

## 9. Model matrix and feature grouping

The actual model mapping (`features.type`) lives in `wacom_wac.c`, but some LED-related hints appear in patch commentary and model descriptions. In general: [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c)

- Intuos4 / 5 / Pro medium/large:
  - Have ring LEDs and sometimes crop marks.
  - Use the `INTUOS5S..INTUOSPL` path.
- 24HD / 27QHD / 21UX2:
  - Have two status-LED banks and OLED/button displays.
  - Use the “else” path with `llv`, `hlv`, and `img_lum`.
- Generic HID Wacom devices:
  - Use the simple `HID_GENERIC` 3-byte control.

For serious reverse engineering or reimplementation (e.g., in OpenTabletDriver), the simplest approach is to mirror this model matrix:

1. Map USB VID/PID to `features.type` equivalent.
2. For each type, implement one of:
   - HID_GENERIC encoding.
   - Intuos5-style `led_bits` packing.
   - INTUOSP2_BT layout.
   - 24HD/21UX2 layout with `llv/hlv/img_lum`.

OpenTabletDriver’s public docs only expose part of the LED story—for example, CTL‑x100 “PC vs Android mode” is indicated by LED brightness, and users can press outer ExpressKeys until LEDs change to toggle modes. The low-level packet formats OTD uses will need to reproduce the same byte layouts as shown above to get full parity with the kernel behavior. [opentabletdriver](https://opentabletdriver.net/Wiki/FAQ/ModelSpecific)


---


## Core finding

In current Linux kernel source, `wacom_led_control(struct wacom *wacom)` builds a HID output report using `WAC_CMD_LED_CONTROL`, then switches behavior by device type to populate different bytes for different Wacom models and LED capabilities. The code shows at least four classes of LED behavior: generic status selection, Intuos-family ring/crop-mark brightness, Cintiq 24HD / 27QHD style status LEDs, and button-image/OLED brightness via `img_lum`. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

## What `wacom_led_control()` does

The function starts by allocating a report buffer, setting `report_id = WAC_CMD_LED_CONTROL`, and then filling device-specific fields before sending the report to the device. The grep-visible logic shows the main data fields the kernel cares about: `groups[0].select`, `groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).select`, per-group luminance, and `img_lum`, which strongly indicates that “LED behavior” in the driver covers both simple indicator LEDs and richer button-image displays. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

## Select vs luminance

The kernel separates **selection** from **brightness**. The `status_ledN_select` sysfs stores write `wacom->led.groups[set_id].select = id & 0x3` and then call `wacom_led_control()`, which means the selected LED state is represented as a small mode/index field rather than a raw brightness value. Separate `*_luminance` handlers update stored brightness bytes and then call the same control path, so changing which LED is active and changing how bright it is are distinct operations in the kernel API. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

## Sysfs interface

The source exposes sysfs attributes such as `status_led0_select`, `status_led1_select`, `status0_luminance`, `status1_luminance`, and `buttons_luminance`, which confirms that at least some Wacom LED behavior is intentionally user-space controllable through standard Linux device attributes rather than only through private ioctls or X11 tools. The presence of `wacom_button_image_store()` also indicates that some devices support uploading or selecting button-display imagery, not just turning LEDs on or off. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

## Intuos-family behavior

The kernel source comments document that “Touch Ring and crop mark LED luminance may take on one of four values: 0 = Low; 1 = Medium; 2 = High; 3 = Off,” which is one of the clearest direct statements of intended LED semantics in the driver. That comment matters because it shows that at least on some models the LED subsystem is not treated as a linear brightness range but as an enumerated mode set, which explains why user-space code that assumes ordinary LED-class brightness scaling can mis-handle Wacom hardware. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

## Multi-group LEDs

The code references both `groups[0]` and `groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)`, and in one path it combines selections with bit packing like `(wacom->led.groups [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).select << 4) | 0x40`, which suggests that some tablets expose two independent LED groups in one outbound command packet  [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c). That aligns with devices that have multiple banks of ExpressKey displays or dual status indicators, where the driver must encode several selections into one HID report  [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c).

## Button image and OLEDs

The source writes `buf [kernel](https://www.kernel.org/doc/html/v5.6/media/kapi/rc-core.html) = wacom->led.img_lum` in one LED-control path, and it defines `DEVICE_LUMINANCE_ATTR(buttons, img_lum)` plus `wacom_button_image_store()`, which strongly ties `img_lum` to brightness control for button images or OLED-labeled ExpressKeys rather than generic chassis LEDs. This is important for Intuos4/5 and similar professional tablets because the “LED problem” users talk about often includes the tiny label displays next to buttons, not only simple indicator lamps. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

## Likely implications for reverse engineering

The Linux source suggests three separate reverse-engineering targets: the HID report layout used by `wacom_led_control()`, the sysfs contract for selection/brightness/image upload, and the per-model feature matrix that decides which fields are meaningful on which tablets. Any OpenTabletDriver work that wants parity with Linux would likely need to map tablet models to the same categories the kernel already uses, because the driver clearly does not treat LED support as uniform across Wacom devices. [github](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

---

## Live-capture addenda (macOS Wacom driver 6.3.46-2, confirmed 2026-05-17)

> **Note on this document:** The byte indices throughout sections 1–8 above are corrupted
> (hyperlinks replaced the `buf[N]` subscripts during creation). The structural descriptions
> are accurate; use the confirmed byte tables below for authoritative values.

Captures were taken via dtrace `IOHIDDeviceSetReport` probes with SIP disabled on macOS 15.7.7.

### Cintiq 24HD / DTK-2400 — report 0x20 (WAC_CMD_LED_CONTROL), 9 bytes

Matches the Linux "else / WACOM_24HD" path in `wacom_led_control()`.

```
buf[0] = 0x20
buf[1] = 0x44 | (rightRingSlot & 0x03) | ((leftRingSlot & 0x03) << 4)
          bit2 (0x04)  = right ring enable
          bit6 (0x40)  = left  ring enable
          bits[1:0]    = right ring LED slot (0–2)
          bits[5:4]    = left  ring LED slot (0–2)
buf[2..8] = 0x00
```

**Discrepancy vs Linux source:** Linux writes `buf[2]=llv` and `buf[3]=hlv`; the official
macOS driver sends zeros for all bytes after buf[1]. Device functions correctly with zeros.

Sent to the primary digitizer device. On DTK-2400, the companion PID 0x0056 does not
enumerate on the bus — primary device only.

### PTH-850 / Intuos5 L — report 0x20 (WAC_CMD_LED_CONTROL), 9 bytes

Falls in the Linux "INTUOS5S..INTUOSPL" branch.

```
buf[0] = 0x20
buf[1] = (llv & 0x1f) | ((slot & 0x07) << 5)
          bits[4:0] = llv luminance (observed: 0x14 = 20)
          bits[7:5] = ring LED slot (0–3)
buf[2] = hlv & 0x1f   (observed: 0x01)
buf[3..8] = 0x00
```

**Discrepancy vs Linux source:** Linux packs `led_bits = (crop_lum<<4)|(ring_lum<<2)|ring_led`
into a single byte using a multi-field encoding. The official macOS driver uses a simpler direct
encoding: raw llv in the low bits and slot index in the high bits of buf[1]. Both control the
same ring LED; the firmware appears to accept either format.

### PTH-660 / Intuos Pro M (USB) — reports 0x31 + 0x32

**Not present in the Linux `wacom_led_control()` source at all.** The INTUOSP2 family uses
a different USB LED mechanism in the official macOS driver that bypasses report 0x20 entirely.

Two feature reports are sent as a pair every time the slot changes (including at init):

```
Report 0x31 (6 bytes): [0x31, 0x46, 0x46, 0x46, 0x46, 0x46]
  — brightness for all ring LED channels; 0x46 = 70 (max observed value)

Report 0x32 (3 bytes): [0x32, 0x46, slot]
  — selects active ring LED slot (0–3); second byte 0x46 is a fixed preamble
```

Both sent to the **primary device**. An additional init-only report precedes the pair:

```
Report 0x34 (5 bytes): [0x34, 0x00, 0x01, 0x00, 0x00]
  — purpose unknown; sent once on DeviceOpen before first 0x31/0x32 pair
```

### PTH-660 / Intuos Pro M (Bluetooth) — report 0x82 (WAC_CMD_WL_INTUOSP2), 51 bytes

Matches the Linux `INTUOSP2_BT` path with corrections:

```
buf[0]    = 0x82
buf[1]    = 0x02   ← fixed; Linux source leaves this 0x00
buf[2..3] = 0x00
buf[4..9] = 0x46   ← all six brightness channels set to the same value (70)
             Linux source writes buf[4..8]=100 and buf[9]=llv separately;
             macOS driver uses the same 0x46 for all six.
buf[10]   = slot   ← ring LED slot (0–3)
buf[11..] = 0x00   ← device's GetReport response fills buf[11..18] with serial,
                      but write path clears them (official driver does the same)
```

Sent on BT connect (3× at init) and on every ring mode button press.
