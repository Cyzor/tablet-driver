2026-04-02

When parsers fail on these older wireless devices, it is almost always because the data is either **encapsulated** with an unexpected header, or **batched** to save wireless bandwidth.

### 1. Wacom Wireless Accessory Kit (WAK) 
**Used by:** Intuos5, Intuos Pro Gen 1 (PTH-x51), Bamboo Gen 3, and Intuos 2015 (CTH-x90)
**Protocol:** Proprietary 2.4 GHz RF via USB Dongle

Because this uses a USB dongle, many parsers mistakenly assume they can read it exactly like a wired USB tablet. In reality, the dongle intercepts the tablet's native USB packets and **encapsulates** them inside a special wireless payload.

* **Report ID:** `0x80`
* **Format Structure:** The dongle sends a custom header followed by the original wired packet.
  * `byte[0]` = `0x80` (Wireless Report ID)
  * `byte [lxr.missinglinkelectronics](https://lxr.missinglinkelectronics.com/linux+v5.12/drivers/hid/wacom_wac.c)` = Wireless status and battery flags (charging state, capacity)
  * `byte [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` = The *original* USB Report ID (e.g., `0x02` for Pen)
  * `byte[3+]` = The standard wired USB payload.
* **Why Parsers Break:** If a parser reads the raw USB stream without checking for the `0x80` WAK header, it interprets the battery status as coordinate data, resulting in wild cursor jumps or failure to parse entirely. You must strip the first two bytes and re-route `byte [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` into your standard USB parser.

### 2. Intuos (2018 Series) Bluetooth
**Used by:** Intuos S/M BT (CTL-4100WL, CTL-6100WL)
**Protocol:** Bluetooth Classic and Bluetooth LE

Unlike the Intuos Pro 2 (PTH-660) which uses a massive 361-byte report, the consumer Intuos BT line uses a smaller, highly compressed batched report to maintain the pen's sample rate over low-bandwidth Bluetooth LE.

* **Report IDs:** `0x3F` or `0x80` (depending on BT LE vs Classic pairing)
* **Format Structure:** A typical payload (often ~44 bytes) containing multiple sub-frames. 
  * The report starts with a header indicating battery life and sequence numbers.
  * The remainder of the payload contains multiple (usually 2 to 4) packed pen frames.
  * Coordinate data, pressure, and button states are bit-packed tightly. 
* **Why Parsers Break:** Just like the PTH-660, if a parser only processes the first frame in the payload, it drops 50% to 75% of the pen's physical polling rate, causing severe lag and staggered line drawing. Furthermore, because it lacks tilt/rotation hardware, blindly applying Intuos Pro logic to this report will misinterpret the packed data.

### 3. Intuos4 Wireless (PTK-540WL)
**Used by:** Intuos4 Wireless (The only device in its generation)
**Protocol:** Early Bluetooth Classic

This was Wacom’s first true Bluetooth tablet, and its protocol is an outlier. It does not use the modern batching techniques of the 2018 Intuos or the Intuos Pro 2. 

* **Format Structure:** It largely mirrors the Intuos4 USB packet structure but adjusts the frame length (typically 10-12 bytes) and uses Bluetooth-specific Report IDs for out-of-proximity notifications and tool swapping.
* **Why Parsers Break:** The Intuos4 was highly dependent on out-of-band "tool ID" packets. Wacom sends a specific packet when the pen enters the tablet's proximity containing the RFID of the tool (e.g., Art Pen vs. standard Grip Pen). If your Bluetooth parser drops this initial tool-identification packet over the wireless stream, the subsequent standard movement packets lack context, and the parser won't know whether to extract rotation data or standard pressure data.

### Summary Rule for Pre-2020 Wireless
If you are modifying a driver or writing a parser for field work:
1. **Check byte 0 for `0x80`:** If it's a USB dongle, strip bytes 0-1 and parse the rest as wired USB.
2. **Batching is mandatory for Native BT:** If it's a native Bluetooth connection, assume the packet contains a header and an array of sub-frames, not a single X/Y coordinate state.


2026-03-25

# Wacom Wireless \& Bluetooth Connectivity: Technical Specification

**Scope:** USB wireless dongle (ACK-40401 RF), Bluetooth Classic (2.1+EDR), and Bluetooth Low Energy (4.x) tablets, approximately 2003–2017. All packet formats sourced from `wacom_wac.c`/`wacom_wac.h` Linux kernel source, the `input-wacom` project, and Wacom hardware documentation.[^1][^2]

***

## 1. Wireless Technology Matrix

Wacom used three distinct wireless transport mechanisms across the product range. Each presents a completely different stack to the host driver.[^3][^1]


| Transport | Standard | Frequency | Range | Tablet Models | Host-side PID |
| :-- | :-- | :-- | :-- | :-- | :-- |
| Proprietary RF (ACK-40401) | Wacom vendor | 2.4 GHz ISM | 10 m | Bamboo 3rd gen, Intuos4/5, Intuos Pro (pre-2017) | `0x0084` (dongle) |
| Bluetooth Classic | BT 2.1+EDR, HID Profile | 2.4 GHz | 10 m | PTK-540WL (Intuos4 WL), CTE-630BT (Graphire4 BT) | BT address |
| Bluetooth Low Energy | BT 4.x, GATT/HOGP | 2.4 GHz | 10 m | PTH-451/651/851 (Intuos Pro 2017+) | BT address |

The ACK-40401 RF dongle enumerates as a **USB HID device** on the host side, making it the simplest transport to implement — the RF link is handled entirely inside the dongle hardware.[^4][^3]

***

## 2. Transport 1: ACK-40401 Proprietary RF Dongle

### 2.1 Hardware Identification

| Attribute | Value |
| :-- | :-- |
| Dongle USB VID | `0x056A` |
| Dongle USB PID | `0x0084` |
| RF band | 2.4 GHz ISM (proprietary FHSS) |
| Dongle USB class | HID (class 0x03, subclass 0x01) |
| Tablet module interface | Wacom proprietary slot module (not user-accessible RF) |
| Pairing model | Factory pre-paired (dongle + module share a unique link key at manufacturing) |

[^5][^3]

### 2.2 Compatible Tablets

The ACK-40401 kit consists of three components: the USB dongle, a rechargeable Li-Ion battery pack, and a wireless module that slides into a slot in the tablet.[^3]


| Tablet Model | Name | Wired PID | Notes |
| :-- | :-- | :-- | :-- |
| CTH-660 / CTH-661 | Bamboo Pen \& Touch M | `0xD3` | Module slot on back |
| CTH-680 | Bamboo Create | `0xD8` | Module slot on back |
| PTZ-930 / PTZ-1230 | Intuos3 9x12 / 12x12 | `0xB2`/`0xB3` | Optional; less common |
| PTK-440/640/840/1240 | Intuos4 S/M/L/XL | `0xB8–0xBB` | Standard; dongle pre-paired |
| PTH-450/650/851 | Intuos5 Touch S/M/L | `0x26–0x28` | Standard; dongle pre-paired |
| PTK-450/650 | Intuos5 Pen S/M | `0x29`/`0x2A` | Standard; dongle pre-paired |

### 2.3 Host-side Protocol

The dongle presents **two HID interfaces** to the OS, mirroring the two-interface structure of the wired tablet:[^2]

- **Interface 0** — Pen and express key data (same Report IDs as wired counterpart)
- **Interface 1** — Pad / OLED key data (same Report ID `0x0C`)

> **Critical implementation note:** The dongle PID `0x0084` must be in your device match table. All packet parsers from the wired versions (Families 3–5 in the prior report) apply **without modification** after the dongle is open. No separate RF initialization is required by the host.[^4]

### 2.4 Connection State Byte

The ACK-40401 prepends a **1-byte connection status header** to every interrupt-in packet when the RF link has a notable state change. Under normal connected operation this byte is absent (or `0x00`); it fires only on connect/disconnect transitions.[^2]


| Byte 0 Value | Meaning | Action |
| :-- | :-- | :-- |
| `0x00` | Normal data packet; no status event | Parse bytes 1–N as normal pen/pad packet |
| `0x02` | RF link active; tablet connected | Assert device online; begin accepting data |
| `0x05` | RF link lost; tablet out of range or off | Assert device offline; suppress events |
| `0x06` | Battery critically low (< 10%) | Post battery warning; continue operation |

When status byte is nonzero, **the remainder of the packet contains no valid pen data**. Discard bytes 1–N and process only the status event.[^2]

### 2.5 Battery Level Report (ACK-40401)

Battery level arrives as a dedicated HID feature report on Interface 0.[^2]


| Field | Value |
| :-- | :-- |
| Report ID | `0x08` |
| Direction | Device → Host (IN feature report) |
| Length | 2 bytes |
| Byte 0 | Report ID `0x08` |
| Byte 1 | Battery percentage, 0–100 (unsigned integer) |

**Poll battery level** by issuing a `GET_REPORT` control transfer:

```c
// USB HID GET_REPORT (Feature), Report ID 0x08
bmRequestType = 0xA1   // Device→Host, Class, Interface
bRequest      = 0x01   // GET_REPORT
wValue        = 0x0308 // Feature report, ID 0x08
wIndex        = 0x0000 // Interface 0
wLength       = 2
```

Poll on a 60-second timer or after waking from sleep. Do not poll more frequently than 10 seconds.[^1]

***

## 3. Transport 2: Bluetooth Classic (BT 2.1+EDR)

Two product lines use BT Classic: the **Intuos4 Wireless (PTK-540WL)** and the older **Graphire4 Bluetooth (CTE-630BT)**. They use different BT profiles and packet structures.

***

### 3.1 Intuos4 Wireless — PTK-540WL

#### 3.1.1 Bluetooth Stack Parameters

| Parameter | Value |
| :-- | :-- |
| Bluetooth version | 2.1 + EDR (Enhanced Data Rate) required; 2.0 minimum |
| Device class | Peripheral (CoD `0x000580`) |
| Device category | Tablet (HID subtype) |
| BT profiles | HID Profile (UUID `0x1124`) |
| Passkey / PIN | `0000` (Spec v2.0 legacy pairing only; v2.1 SSP uses no PIN) |
| Discoverable duration | 180 seconds after pressing pairing button |
| RF class | Class 2 (max 10 m range) |
| Device name (advertising) | `PTK-540WL` |

[^1]

#### 3.1.2 Pairing Procedure: State Machine

```
HOST                               TABLET (PTK-540WL)
────────────────────────────────────────────────────────────────
                                   Power switch ON:
                                   → Starts non-discoverable
                                   → Wireless LED off

                                   User presses Pairing Button:
                                   → Enters PAGE_SCAN mode
                                   → Wireless LED blinks blue slowly
                                   → Discoverable timer = 180 s

Host opens BT inquiry scan
Host sends INQUIRY (LAP = 0x9E8B33)
                                   INQUIRY_RESPONSE:
                                   BD_ADDR = <tablet BT address>
                                   CoD = 0x000580

Host sends PAGE (BD_ADDR)
                                   CONNECT_REQ accepted
                                   LMP authentication exchange
                                   (SSP: v2.1 Just Works — no PIN)
                                   (Legacy: PIN = "0000")

Host: HID_CONTROL connection
                                   HID_HANDSHAKE (SUCCESSFUL)

Host: HID_INTERRUPT connection
                                   HID channels open

Host: SET_REPORT (Feature, ID 0x02)  ← mode-switch (same as USB §5.1)
                                   Tablet enters Wacom HID mode
                                   Wireless LED solid blue

                                   Normal pen packets begin flowing
                                   on HID_INTERRUPT channel
```


#### 3.1.3 Re-connection After Sleep

The PTK-540WL stores the paired host's BD_ADDR permanently. On subsequent power-on events:[^1]

```
Tablet power on:
1. Searches for stored BD_ADDR via PAGE (no INQUIRY needed)
2. If host responds within 5 s → HID channels reopen automatically
3. Re-issue SET_REPORT mode-switch (0x02, 0x02) immediately after
   HID_INTERRUPT channel opens — tablet resets to HID-generic mode
   after any Bluetooth reconnect
4. If no response within 5 s → tablet enters sleep mode
   (Touch Ring button wakes it for retry)
```

If the pairing is broken from the host side (host deletes the device record), the tablet must be placed back in discoverable mode via the pairing button.[^1]

#### 3.1.4 Bluetooth Packet Wrapper

All data packets over the BT HID Interrupt channel are the same 10-byte Intuos4 pen packets (§4A of prior report) with a **1-byte BT status prefix**:[^2]


| Byte | Field | Encoding | Notes |
| :-- | :-- | :-- | :-- |
| 0 | BT status | Enum (see table) | Connection and battery state |
| 1–10 | Pen / pad data | Intuos4 format | Same as §4A–§4C from prior report; all byte indices shift +1 |

**BT status byte decode:**


| Value | Meaning | Driver Action |
| :-- | :-- | :-- |
| `0x02` | Link active, normal data | Parse bytes 1–10 as pen/pad packet |
| `0x03` | Link active, stylus in proximity | Same as `0x02`; proximity already in byte 2 |
| `0x05` | Battery low warning | Post `POWER_SUPPLY_STATUS_DISCHARGING` alert; continue parsing |
| `0x06` | Charging via USB | Post `POWER_SUPPLY_STATUS_CHARGING`; BT link still active |

[^2]

#### 3.1.5 Battery Report (PTK-540WL)

Battery level is available via a dedicated BT HID feature report on the HID Control channel:[^2]


| Field | Value |
| :-- | :-- |
| Report ID | `0x08` |
| Direction | Device → Host |
| Length | 2 bytes total |
| Byte 0 | `0x08` (Report ID) |
| Byte 1 | Battery level, 0–100 (unsigned; unit = percent) |

Request with `GET_REPORT` on the HID Control channel (same logical operation as USB GET_REPORT, but over L2CAP HID_CONTROL channel PSM `0x0011`):

```python
# BlueZ / Python equivalent
control_socket.send(bytes([0x43, 0x08]))
# 0x43 = HID GET_REPORT (0x40) | Feature (0x03)
# 0x08 = Report ID
response = control_socket.recv(4)
battery_pct = response[^2]  # byte at offset 2 in response
```


#### 3.1.6 Disconnection / Unpairing

| Trigger | Tablet Behavior | Host Behavior |
| :-- | :-- | :-- |
| User presses pairing button while connected | Sends `HID_CONTROL (DISCONNECT)` | Remove device from paired list |
| Tablet auto-sleep (30 min inactivity) | Closes HID channels silently | Host sees L2CAP disconnect |
| Host deletes pairing record | Tablet next connect attempt fails (page timeout) | — |
| RF out of range (> 5 s link loss) | Tablet enters sleep mode | Host sees page timeout |

[^1]

***

### 3.2 Graphire4 Bluetooth — CTE-630BT (PID `0x81`)

#### 3.2.1 Bluetooth Stack Parameters

| Parameter | Value |
| :-- | :-- |
| Bluetooth version | 1.1 / 1.2 |
| BT profile | **Serial Port Profile (SPP)**, UUID `0x1101` |
| Passkey | None required (auto-pairing) |
| Device class | CoD `0x000500` (Peripheral) |
| Device name | `WACOM CTE-630BT` |
| RF class | Class 2 |

> **Critical difference from PTK-540WL:** The CTE-630BT does NOT use the HID Profile. It uses SPP (RFCOMM over BT), which means the OS presents it as a **virtual serial port**, not a HID device. Your macOS driver must open `/dev/cu.Bluetooth-PDA-Sync` or equivalent RFCOMM channel, not `IOHIDManager`.[^6]

#### 3.2.2 Pairing

The CTE-630BT pairs through standard BT Legacy pairing (Bluetooth 1.x). No PIN is required in most implementations; the device auto-accepts pairing requests from any discoverable host. Once paired, macOS creates an RFCOMM service binding.

```
1. Enable tablet (power switch or pen proximity triggers RF)
2. Host sends INQUIRY → tablet responds with BD_ADDR + CoD 0x000500
3. Host pages tablet → LMP_au_rand exchange (no PIN)
4. SDP query: RFCOMM channel number (typically channel 1)
5. Host opens RFCOMM session on that channel
6. Host sends Graphire mode-switch over RFCOMM:
     Bytes: { 0x02, 0x02 }   (same mode switch as USB, but sent as raw serial bytes)
7. Tablet begins streaming 8-byte Graphire packets over RFCOMM
```


#### 3.2.3 CTE-630BT Data Packets

Packet format is **identical** to the wired Graphire4 8-byte format (§1A–§1D from prior report), but delivered as a raw serial byte stream over RFCOMM rather than USB interrupt transfers.[^6]


| Aspect | Wired CTE-640 | BT CTE-630BT |
| :-- | :-- | :-- |
| Packet format | 8 bytes, Report ID prefix | 8 bytes, same layout |
| Delivery | USB interrupt-IN | RFCOMM serial bytes |
| Mode switch | USB SET_REPORT | RFCOMM byte sequence `{0x02, 0x02}` |
| Max packet rate | ~200 Hz | ~100 Hz (BT 1.x bandwidth limit) |
| Battery status | N/A (USB powered) | No battery report; tablet uses AA batteries |

There is no battery level report for the CTE-630BT. The tablet uses two AA alkaline batteries with no reporting mechanism.

***

## 4. Transport 3: Bluetooth Low Energy (BT 4.x / HOGP)

### 4.1 Applicable Models

| Model | Name | PID (USB) | BT Version | Multi-host |
| :-- | :-- | :-- | :-- | :-- |
| PTH-451 | Intuos Pro S (2017) | `0x0314` | BT 4.2 | 2 slots (BT1/BT2) |
| PTH-651 | Intuos Pro M (2017) | `0x0315` | BT 4.2 | 2 slots |
| PTH-851 | Intuos Pro L (2017) | `0x0317` | BT 4.2 | 2 slots |

[^7][^8]

### 4.2 Bluetooth Stack Parameters

| Parameter | Value |
| :-- | :-- |
| BT version | 4.2 (LE only for pairing; may use BR/EDR for data at higher speeds) |
| BT profile | HID over GATT Profile (HOGP), also standard HID Profile |
| Services | HID Service (UUID `0x1812`), Battery Service (UUID `0x180F`), Device Info (UUID `0x180A`) |
| Pairing model | LE Secure Connections (Just Works — no PIN or passkey entry) |
| Discoverable duration | Until paired or user cancels |
| Device name | `Intuos Pro S` / `Intuos Pro M` / `Intuos Pro L` (model-dependent) |
| Connection interval | 7.5 ms (high performance) to 30 ms (power save) |
| Multi-host slots | 2 (BT1 and BT2, independently stored link keys) |

[^8][^7]

### 4.3 Pairing State Machine

```
HOST                               TABLET (PTH-451/651/851)
────────────────────────────────────────────────────────────────
                                   User selects BT1 or BT2 slot
                                   via USB/BT selector switch

                                   User holds Power button until
                                   blue LED blinks slowly:
                                   → LE advertising begins
                                   → ADV_IND packets at 100 ms interval
                                   → AD payload includes:
                                     Flags: LE General Discoverable
                                     Complete Local Name: "Intuos Pro M"
                                     Appearance: 0x03C1 (Digitizer)
                                     Service UUIDs: 0x1812, 0x180F

Host BLE scan detects ADV_IND
Host sends CONNECT_IND:
  Access address, timing parameters
                                   LE connection established
                                   Connection interval negotiated to 7.5 ms

Host pairs (LE Secure Connections):
  LE_PAIRING_REQUEST
  IOCapability: NoInputNoOutput (Just Works)
                                   LE_PAIRING_RESPONSE (same)
                                   DHKey exchange
                                   LTK generated and stored in BT1/BT2 slot

Host: ATT MTU exchange (default 23 → negotiate to 185)
Host: GATT service discovery:
  HID Service (0x1812):
    Report Map (0x2A4B)
    HID Information (0x2A4A)
    HID Control Point (0x2A4C)
    Protocol Mode (0x2A4E)
    Report characteristics (multiple)
  Battery Service (0x180F):
    Battery Level (0x2A19) — notify
  Device Information (0x180A):
    PnP ID (0x2A50): VID=0x056A

Host enables CCCD notifications on:
  → HID Report characteristic (pen data)
  → Battery Level characteristic
                                   Tablet: sends HID Report Map descriptor
                                   Tablet: LED goes solid blue
                                   Tablet: begins streaming pen/pad GATT notifications
```


### 4.4 GATT HID Report Map Structure

The Intuos Pro BT reports via GATT HID Reports (not raw interrupt packets). The Report Map descriptor defines the following reports:[^2]


| Report ID | Report Type | Direction | Contents |
| :-- | :-- | :-- | :-- |
| `0x01` | Input | Device → Host | Pen data (23 bytes) |
| `0x02` | Input | Device → Host | Touch data (up to 16 contacts) |
| `0x03` | Input | Device → Host | Pad / express key data |
| `0x08` | Feature | Device → Host | Battery level |
| `0x10` | Output | Host → Device | LED / OLED configuration |

### 4.5 Intuos Pro BT Pen Report (Report ID `0x01`, 23 bytes)

The BT pen report is **larger** than the USB pen report — Wacom uses a different, self-contained format that includes the full tool ID without requiring a separate proximity-enter packet.[^2]


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x01` | — |  |
| 1 | [3:0] | Tool index | 4-bit | 0–1 | Which tool slot |
| 1 | [^9] | Tip switch | Boolean | 0/1 | `BTN_TOUCH` |
| 1 | [^10] | Barrel btn 1 | Boolean | 0/1 | `BTN_STYLUS` |
| 1 | [^11] | Barrel btn 2 | Boolean | 0/1 | `BTN_STYLUS2` |
| 1 | [^12] | Proximity | Boolean | 0/1 | 1 = tool in range |
| 2–3 | [15:0] | X coordinate | LE uint16 | 0–MaxX | X = `data[^2] \| (data[^3]<<8)` |
| 4–5 | [15:0] | Y coordinate | LE uint16 | 0–MaxY | Y = `data[^4] \| (data[^5]<<8)` |
| 6–7 | [15:0] | Pressure | LE uint16 | 0–8191 | **13-bit pressure** (Intuos Pro gen); normalize to 0–1.0 |
| 8 | [7:0] | Distance | Uint8 | 0–63 | `ABS_DISTANCE`; hover height |
| 9 | [7:0] | Tilt X | Signed int8 | −127 to +127 | Scaled: divide by 127 to get sin(angle) |
| 10 | [7:0] | Tilt Y | Signed int8 | −127 to +127 | Same scaling |
| 11–14 | [31:0] | Tool serial | LE uint32 | — | `MSC_SERIAL`; unique tool ID |
| 15–16 | [15:0] | Tool ID | LE uint16 | — | Same tool ID table as §3A (prior report) |
| 17–22 | — | Reserved | 0 | — | Padding to 23 bytes |

> **Tilt encoding difference from USB:** On BT, tilt is sent as a **signed byte proportional to sin(tilt_angle)**, not in degrees. Convert via `tilt_degrees = asin(raw / 127.0) × (180/π)`. This differs from the USB packet where byte values are direct degree units.[^2]

### 4.6 Intuos Pro BT Touch Report (Report ID `0x02`)

Same 6-byte-per-contact structure as USB (§5A from prior report), delivered as a GATT notification. Contact count in byte 1. Maximum 16 contacts. Touch coordinate range 0–4095.

### 4.7 Intuos Pro BT Pad Report (Report ID `0x03`, 9 bytes)

| Byte | Bits | Field | Encoding | Notes |
| :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x03` |  |
| 1 | [7:0] | Keys 1–8 | Bitmask | Bit 0 = key 1 (BTN_0), bit 7 = key 8 (BTN_7) |
| 2 | [^12] | Ring active | Boolean | Finger on touch ring |
| 2 | [6:0] | Ring position | 7-bit uint | 0–71; 5° steps; `ABS_WHEEL` |
| 3 | [1:0] | Ring mode | 2-bit | 0–3; active function mode |
| 4–8 | — | Reserved | 0 |  |

### 4.8 Battery Level (GATT, 0x180F)

Battery level is exposed as a standard GATT Battery Service characteristic.[^13]


| GATT UUID | `0x2A19` |
| :-- | :-- |
| Properties | Read + Notify |
| Value | 1 byte, 0–100 (percent) |
| CCCD | Enable notifications to receive updates on battery change |

On macOS, `CBCentralManager` / `CBPeripheral` GATT API reads this directly. No manual polling required; the tablet sends a notification when battery level changes by ≥1%.

### 4.9 Multi-Host Slot Switching

The Intuos Pro (2017+) stores two independent Bluetooth link keys (BT1, BT2) and one USB connection record. The USB/BT selector switch on the tablet cycles through them:[^8]


| Selector Position | Connection Mode | Notes |
| :-- | :-- | :-- |
| USB | Wired USB (disables BT entirely) | Highest priority; BT antenna off |
| BT1 | Bluetooth host slot 1 | Reconnects to stored BT1 BD_ADDR |
| BT2 | Bluetooth host slot 2 | Reconnects to stored BT2 BD_ADDR |

To pair a new host to an occupied slot, hold the Power button while on that slot → forces new pairing mode and **overwrites** the existing link key for that slot. The old host loses access until it re-pairs.

***

## 5. macOS Implementation: Wireless-Specific Considerations

### 5.1 ACK-40401 RF Dongle

The dongle enumerates as USB HID exactly as a wired tablet. Use `IOUSBHostInterface` and match on VID `0x056A` / PID `0x0084`. After opening, the standard two-stage initialization (pen interface then pad interface) applies. The only wireless-specific logic is the status-byte handler (§2.4).[^2]

### 5.2 Bluetooth Classic (PTK-540WL)

macOS Bluetooth Classic HID devices are handled by `IOBluetoothHIDDriver`. For a custom driver, use `IOBluetoothDevice` to open L2CAP channels directly:

```swift
// Open HID Control channel (PSM 0x0011) and Interrupt channel (PSM 0x0013)
let device = IOBluetoothDevice(addressString: "XX:XX:XX:XX:XX:XX")
device?.openConnection(nil)

let controlChannel  = device?.openL2CAPChannelSync(nil, withPSM: 0x0011, delegate: self)
let interruptChannel = device?.openL2CAPChannelSync(nil, withPSM: 0x0013, delegate: self)

// Send mode switch on control channel
controlChannel?.writeSync([0x53, 0x02, 0x02], length: 3)
// 0x53 = SET_REPORT (0x50) | Feature (0x03)
```

On macOS, `IOBluetoothHIDDriver` will compete for the connection. Prevent it by setting `"idleDisconnect"` = `false` in the kernel personality and claiming the device via `IOBluetoothHIDDriver::handleReport` override, or by using a DriverKit personality that matches on the BT device's CoD + UUID before `IOBluetoothHIDDriver` loads.[^14]

Re-issue the mode switch (bytes `{0x53, 0x02, 0x02}`) whenever the L2CAP interrupt channel reconnects after any gap — the tablet resets to HID-generic mode on every new L2CAP session.[^1][^2]

### 5.3 Bluetooth LE (Intuos Pro 2017+)

Use `CoreBluetooth` (`CBCentralManager` / `CBPeripheral`) to scan, connect, and subscribe to GATT notifications. On macOS, CBCentralManager does not conflict with system HID — BLE HID devices are claimed by `IOBluetoothHIDDriver` only if they advertise the standard HOGP service. To prevent system HID from claiming the device before your daemon can, implement a **DriverKit BT personality** that matches on PnP ID (VID `0x056A`) and claims priority.[^7]

```swift
// GATT discovery and notification subscription
func peripheral(_ peripheral: CBPeripheral,
                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    for char in service.characteristics ?? [] {
        if char.uuid == CBUUID(string: "2A4D") {  // HID Report
            peripheral.setNotifyValue(true, for: char)
        }
        if char.uuid == CBUUID(string: "2A19") {  // Battery Level
            peripheral.setNotifyValue(true, for: char)
            peripheral.readValue(for: char)
        }
    }
}
```

Parse incoming `didUpdateValueFor` data using the Report ID byte as the dispatch key (§4.5–§4.7 above).

***

## 6. LED Indicator Reference by Model

### 6.1 PTK-540WL Battery + Wireless LEDs

| Battery LED Color | Battery State |
| :-- | :-- |
| Green (solid) | 35–100% charge |
| Red (solid) | 15–34% charge |
| Red (flashing) | < 15% charge — recharge immediately |
| Yellow (solid) | USB cable connected, charging |
| Off | Tablet powered off, or depleted |

| Wireless LED Color | Connection State |
| :-- | :-- |
| Off | No BT connection |
| Blue (slow blink, ~1 Hz) | Discoverable mode (pairing); 180 s window |
| Blue (solid) | BT connection established |

[^1]

### 6.2 Intuos Pro (PTH-451/651/851) Power/BT LED

| LED Pattern | State |
| :-- | :-- |
| Off | Powered off |
| White (slow blink) | BLE advertising (pairing mode) |
| White (solid) | BLE connected |
| White (fast blink) | Attempting reconnect to stored host |
| Amber | Charging via USB |
| Amber + White alternating | Low battery (< 20%) while BT connected |

[^8][^7]

***

## 7. Wireless Protocol Quick Reference

| Model | Transport | Host API (macOS) | Mode Switch Required? | Battery Report | Reconnect Init |
| :-- | :-- | :-- | :-- | :-- | :-- |
| CTE-630BT | BT SPP (RFCOMM) | `IOBluetoothRFCOMMChannel` | Yes — RFCOMM bytes `{0x02,0x02}` | None | Re-send mode switch on each new RFCOMM session |
| PTK-540WL | BT Classic HID | `IOBluetoothDevice` L2CAP | Yes — `{0x53,0x02,0x02}` on Control PSM | Report ID `0x08`, GET_REPORT | Re-send after every L2CAP reconnect |
| ACK-40401 (any) | USB HID (RF dongle) | `IOUSBHostInterface` | Yes — same as wired | Report ID `0x08`, GET_REPORT | Re-init on USB re-enumeration |
| PTH-451/651/851 | BT 4.2 LE / GATT | `CoreBluetooth` | No — GATT reports always active | GATT `0x2A19`, Notify | Subscribe CCCDs after each new connection |

<span style="display:none">[^15][^16][^17][^18][^19][^20][^21][^22][^23][^24][^25][^26][^27][^28][^29][^30][^31][^32][^33][^34]</span>

<div align="center">⁂</div>

[^1]: https://support.wacom.asia/sites/default/files/manuals_brochures/intuos4-wireless-en.pdf

[^2]: https://github.com/linuxwacom/input-wacom

[^3]: https://support.wacom.com/hc/en-us/articles/1500006340602-What-is-the-Wacom-Wireless-Accessory-kit-ACK40401

[^4]: https://www.bestbuy.com/product/wireless-accessory-kit-for-select-wacom-tablets-multi/JXFPXQQ6C7

[^5]: https://chromium.googlesource.com/chromium/src/+/master/third_party/usb_ids/usb.ids

[^6]: https://www.kernel.org/pub/linux/kernel/people/marcelo/linux-2.4/drivers/usb/wacom.c

[^7]: https://support.wacom.com/hc/en-us/articles/1500006264261-How-do-I-pair-Wacom-Intuos-Pro-2017-to-my-computer-via-Bluetooth

[^8]: https://101.wacom.com/UserHelp/en/Wireless_Bluetooth-IntuosPro_Full.htm

[^9]: https://opentabletdriver.net/Wiki/Development/Configurations

[^10]: https://opentabletdriver.net/Wiki/FAQ/General

[^11]: https://github.com/torvalds/linux/blob/master/drivers/hid/wacom.h

[^12]: https://github.com/linuxwacom/wacom-hid-descriptors

[^13]: https://stackoverflow.com/questions/49078659/check-battery-level-of-connected-bluetooth-device-on-linux

[^14]: https://www.reddit.com/r/wacom/comments/1hle2zj/revive_your_old_wacom_tablets_on_macos_with/

[^15]: https://101.wacom.com/userhelp/en/Wireless_Bluetooth_Full.htm

[^16]: https://www.youtube.com/watch?v=lUrVYoJvy_g

[^17]: https://www.reddit.com/r/wacom/comments/c0m9h1/i_fixed_my_bluetooth_connection_issue_and_figured/

[^18]: https://bbs.archlinux.org/viewtopic.php?id=286033

[^19]: https://www.youtube.com/watch?v=8cjehwQa8Pg

[^20]: https://www.youtube.com/watch?v=YqTSUT1q_QY

[^21]: https://developer-support.wacom.com/hc/en-us/articles/9354478692503-STU-HID-Diagnostic-Tool

[^22]: https://www.youtube.com/watch?v=-xjsFctNYN8

[^23]: https://www.reddit.com/r/wacom/comments/gh85gb/issues_with_wireless_accessory_ack40401/

[^24]: https://github.com/linuxwacom/input-wacom/issues/37

[^25]: https://www.reddit.com/r/voidlinux/comments/1ox7sja/wacom_intuos_tablet_connects_with_bluetooth_yet/

[^26]: https://support.wacom.com/hc/en-us/community/posts/34076517592087-Tablet-Keeps-Disconnecting-Linux

[^27]: http://www.linux-usb.org/usb.ids

[^28]: https://discussion.fedoraproject.org/t/wacom-bluetooth-pad/114002

[^29]: https://github.com/linuxhw/LsUSB/blob/master/Desktop/README.md?plain=1

[^30]: https://developer-docs.wacom.com/docs/icbt/linux/building-driver/bldg-driver-basics/

[^31]: https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device

[^32]: https://sourceforge.net/projects/linuxwacom/files/xf86-input-wacom/input-wacom/

[^33]: https://raw.githubusercontent.com/systemd/systemd/fee6441601c979165ebcbb35472036439f8dad5f/hwdb.d/20-usb-vendor-model.hwdb

[^34]: https://github.com/linuxwacom/input-wacom/issues/445

