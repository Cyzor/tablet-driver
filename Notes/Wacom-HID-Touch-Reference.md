2026-03-31

## Touch Input Reference

### Device Support Matrix

| Device | Touch Type | Multi-touch | Report ID | Notes |
|---|---|---|---|---|
| Intuos3 PTZ-631W | Touch strips | No | 0x0C | Resistive strip sensors, not capacitive |
| Intuos3 PTZ-631W WS | Touch strips | No | 0x0C | Dual strips |
| Cintiq 24HD Touch DTH-2400 | Capacitive | No (single) | 0x10 | Single-touch only |
| Cintiq 22HD Touch DTH-2200 | Capacitive | No (single) | 0x10 | Single-touch only |
| Cintiq Pro 27 DTH-271 | Capacitive | Yes (10-point) | 0x10 | Full multi-touch |
| Movink 13 DTH-135 | Capacitive | Yes (10-point) | 0x10 | Full multi-touch |
| Cintiq 16 DTH-1320 | Capacitive | Yes (10-point) | 0x10 | Full multi-touch |

### Touch Report Byte Map (Capacitive Multi-touch)

```
10  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

| Byte | Field | Formula |
|---|---|---|
| `d[0]` | Report ID | 0x10 for touch |
| `d[1]` | Contact count | Number of active touch points |
| `d[2]` | Contact 1 - X low | `LE16(d[2]:d[3])` |
| `d[3]` | Contact 1 - X high | — |
| `d[4]` | Contact 1 - Y low | `LE16(d[4]:d[5])` |
| `d[5]` | Contact 1 - Y high | — |
| `d[6]` | Contact 1 - ID | Touch point identifier (0–9) |
| `d[7]` | Contact 2 - X low | If contact count > 1 |
| ... | ... | Continues for additional contacts |

### Single-touch Devices (Cintiq 24HD Touch, 22HD Touch)

Simplified 8-byte format:

```
10  d1  d2  d3  d4  d5  d6  d7
```

| Byte | Field | Formula |
|---|---|---|
| `d[0]` | Report ID | 0x10 |
| `d[1]` | Touch flags | Bit 0: in contact, bit 1: in range |
| `d[2]:d[3]` | X position | LE16 |
| `d[4]:d[5]` | Y position | LE16 |
| `d[6]` | Contact ID | Always 0 for single-touch |
| `d[7]` | Reserved | — |

### Touch Strip Devices (Intuos3 WS)

Uses pad report ID 0x0C (same as touch strips on intuos3):

| Field | Formula |
|---|---|
| Strip 1 (left) | `((d[1] & 0x1F) << 8) | d[2]` — 13-bit |
| Strip 2 (right) | `((d[3] & 0x1F) << 8) | d[4]` — 13-bit |
| Touch active | Value > 0 indicates finger contact |
| Strip value 0 | Finger lifted |

---

## Enabling and Disabling Touch

### Driver-Level Controls (Linux)

**Module parameters:**

```
# Disable touch input entirely
echo 0 > /sys/bus/usb/devices/.../touch_enabled

# Invert touch axes (for rotated displays)
echo 1 > /sys/bus/usb/devices/.../invert_touch

# Disable touch while pen is in proximity (prevents accidental touches)
echo 1 > /sys/bus/usb/devices/.../touch_arbitration
```

**Runtime control via userspace:**

```c
// ioctl to disable touch
ioctl(fd, WACOM_DEVICETOUCH, 0);  // disable
ioctl(fd, WACOM_DEVICETOUCH, 1);  // enable
```

### HID Feature Reports

Some devices support touch enable/disable via HID feature report:

| Report ID | Direction | Data | Function |
|---|---|---|---|
| 0x0A | OUT | `[0x00, 0x00, 0x00, 0x01, ...]` | Enable touch |
| 0x0A | OUT | `[0x00, 0x00, 0x00, 0x00, ...]` | Disable touch |

The exact encoding varies by device generation.

### Platform Controls

**Windows:** Wacom Tablet Properties → Touch → Enable/disable
**macOS:** System Preferences → Wacom Tablet → Touch → Enable/disable
**Linux (GUI):** libinput, gnome-settings-daemon, KDE input policies

---

## Touch Proximity and Arbitration

### Pen vs. Touch Conflict Resolution

Wacom devices use **touch arbitration** — when the pen is in proximity, touch input is suppressed to prevent palm rejection failures.

**Arbitration logic:**

```
if (pen_proximity == true) {
    suppress_all_touch_events
} else {
    pass_touch_events_to_userspace
}
```

**Touch arbitration timeout:**
If touch arbitration is enabled, the driver holds touch suppressed for 50–100 ms after pen exit proximity to prevent spurious touch events during rapid tool switching.

### Multi-touch Gesture Handling

The Linux driver reports raw touch coordinates to the input subsystem. Gesture recognition is delegated to userspace:

| Gesture | Userspace handling |
|---|---|
| Single-finger tap | BTN_TOUCH, ABS_X/Y |
| Single-finger drag | BTN_TOUCH, ABS_X/Y with motion |
| Two-finger scroll | ABS_MT_POSITION_X/Y + pointer emulation |
| Pinch zoom | ABS_MT_DISTANCE + scale emulation |
| Three-finger swipe | Custom gesture handling via libinput |

**Multi-touch protocol (MT Protocol):**

Wacom devices use the Linux multi-touch protocol (Protocol B):

```c
// Slot-based multi-touch
ABS_MT_SLOT          // Current slot (0–9)
ABS_MT_TRACKING_ID   // Unique per-contact identifier
ABS_MT_POSITION_X    // X coordinate
ABS_MT_POSITION_Y    // Y coordinate
ABS_MT_TOUCH_MAJOR   // Contact area (optional)
```

---

## Known Touch Quirks

| Device | Issue |
|---|---|
| Cintiq 24HD Touch | Single-touch only; no pinch zoom |
| Cintiq 22HD Touch | Single-touch only; no pinch zoom |
| Intuos Pro gen2 | Touch ring only, no capacitive touch |
| Intuos5 | No touch capability at all |
| All devices | Touch arbitration may cause 50ms latency on rapid tool switch |

---

## HID Descriptor Touch Usage

Touch capability is advertised in the HID descriptor via Digitizer Usage Page:

```
Usage Page (Digitizer)        05 0D
Usage (Touch Screen)          09 04
Collection (Application)      A1 01
    Usage (Tip Switch)        09 42
    Usage (Barrel Switch)     09 44
    Usage (Touch)             09 47
    Usage (Axis Selector)     09 57
    ...
End Collection               C0
```

For multi-touch (Protocol B):

```
Usage (Touch Screen)          09 04
Usage (Contact Count)         09 55
Usage (Contact Index)         09 56
```