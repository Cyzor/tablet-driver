2026-07-07

# Xencelabs Quick Keys Technical Spec Sheet

## Overview

The Xencelabs Quick Keys is a programmable shortcut remote with eight physical shortcut keys, five shortcut groups, a central OLED display, a rotary dial with a center button, and support for both wired USB-C and wireless dongle operation. The official product and quick-start materials describe up to 40 shortcut keys per application plus up to 4 dial functions, while the device logs show two additional logical inputs for the set/OLED button and the center dial button, bringing the practical control surface to 10 distinct button identifiers plus dial rotation.

The logs and HID captures show that the Quick Keys operates as a HID-based device using report ID 0x02 for both host-to-device feature reports and device-to-host input reports. In XencelabsAgent, the remote is handled as a per-device configurable “Remote” object keyed by device identifiers such as `Maa6782b935f4`, while wired and dongle-associated device identities also appear as `M3d3033343034` and `M4fc2cc17abca` in the same control path.

## Product characteristics

| Attribute | Value |
|---|---|
| Product name | Xencelabs Quick Keys / Quick Keys Remote  |
| Model | K02-A  |
| Primary function | Programmable shortcut remote for creative and productivity applications  |
| Connectivity | USB-C wired or wireless via bundled USB dongle  |
| Shortcut keys | 8 physical keys, 5 groups, up to 40 shortcuts per application  |
| Dial functions | Up to 4 per application  |
| Display | OLED text display for shortcut labels  |
| LED ring | 8 color options around the dial  |
| Charging time | About 1.5 hours  |
| Battery life | Up to 50–53 hours, depending on source and use case  |
| Dimensions | 157.6 x 62.5 x 12 mm  |
| Weight | 142 g  |
| Security slot | Kensington Nano slot  |
| Supported OS | Windows, macOS, Linux  |

## Physical controls

Official documentation identifies the dial, dial mode button, set button, eight shortcut keys, OLED display, power slide switch, connection indicator, charging indicator, USB-C port, and Kensington slot as the main physical features. The logs confirm that the driver distinguishes regular shortcut buttons from two meta-controls: `Remote id` 9 is the set/OLED function button and `Remote id` 10 is the center dial mode button.

### Button map derived from logs

| Logical ID | KeyIndex | Interpreted control | Evidence |
|---|---:|---|---|
| 1–8 | 0–7 | Eight main shortcut buttons | XencelabsAgent logs each as `Remote id down/up` with a matching `KeyIndex` and bound function name such as Undo, Redo, Copy, Paste, Shift, Command, Option, Space  |
| 9 | 8 | Set/OLED button | Pressing it triggers `ChangeOLEDFunctions` and OLED/page-related behavior in the agent logs  |
| 10 | 9 | Center dial mode button | Pressing it triggers `ChangeRemoteLRFunctions to N` and cycles `iCurRingIndex` values  |
| Dial rotation | n/a | Rotary encoder input | Agent logs report `RingID: 0 Dir: 1/-1`, while raw USB captures show changing `f0` and `f2` input reports during dial use  |

## Functional model

The Quick Keys firmware and driver present the device as a layered control surface rather than a simple keyboard. In practice, the control model has four distinct layers.

- **Shortcut layer:** eight physical buttons mapped to per-application functions, usually key sequences or modifiers.
- **Group/page layer:** the set button changes OLED-labeled shortcut groups, with official documentation stating up to five groups per application.
- **Dial mode layer:** the center dial button cycles up to four dial modes per application.
- **Dial motion layer:** clockwise and counter-clockwise dial movement emits directional events interpreted by the driver as mode-specific commands such as zoom, scrub, or size change.

## Device identities and pairing model

The logs show three important identifier forms used by the Xencelabs stack: wired or tablet-like IDs such as `M3d3033343034`, dongle-side IDs such as `M4fc2cc17abca`, and remote IDs such as `Maa6782b935f4`. These IDs appear both in XencelabsAgent logs and inside HID feature-report payloads, especially opcode `b4 10`, where ASCII strings beginning with `M3d303` and `M4fc2c` are written to the device.

The pairing trace shows that the official driver performs host-driven association through 64-byte HID feature reports using opcodes such as `b1`, `b4`, and `b8`, combining device IDs, a repeated GUID-like token `aa 67 82 b9 35 f4`, profile metadata, and UTF-16 labels. Xencelabs support documentation separately confirms that pairing to a new dongle is initiated from the Settings application and that a dongle can pair with up to two devices, which matches the behavior seen in the logs.

## HID transport and report structure

### Transport summary

The raw captures show the USB-connected Quick Keys at VID 0x28bd and PID 0x5202. The wireless path appears through a Xencelabs dongle at PID 0x5203, while related pen display hardware appears at PID 0x520d in mixed captures.

The Quick Keys uses report ID 0x02 as its main control channel. In the available logs, this report ID carries both host-to-device feature reports and device-to-host status or event reports.

### Host-to-device opcodes observed

| Opcode | Likely role | Evidence |
|---|---|---|
| `b0` | Session or control command, possibly state/query framing | Sent during startup and paired-dongle sessions before or between other initialization traffic  |
| `b1` | Label and metadata transfer for buttons/functions | Carries UTF-16 strings such as Shift, Command, Option, and localized labels  |
| `b4` | Configuration, identity, pairing, and mode setup | Used with subcommands like `01 01`, `08`, `10`, and `40`; `b4 10` embeds ASCII device IDs  |
| `b5` | State/control toggles, likely mode commit or reset behavior | Seen in repeated startup sequences as `00 f0`, `00 10 f0`, and `00 05 02`  |
| `b8` | Initialization or handshake marker | Sent as `02 b8 01 00 ...` in pairing and startup traces  |

### Device-to-host opcodes observed

| Opcode | Length | Likely role | Evidence |
|---|---:|---|---|
| `f0` | 10 bytes | Main button and mode event/status report | Third byte changes as single-bit masks for different button presses; later bytes hold small persistent mode values  |
| `f2` | 10 bytes | Dial position, selection, or higher-level dial event report | Appears at the end of dial-related capture as `02 f2 01 59 01 ...` and `02 f2 01 5c 01 ...`  |
| `f8` | 32 bytes | Richer status/identity report on dongle/display path | Contains repeated identifier bytes and other nonzero state fields in native captures  |

## HID descriptors and composite behavior

The dongle-side HID descriptors show that Xencelabs uses a composite HID approach rather than a single plain keyboard endpoint. Captured descriptors include keyboard-style usages, pointer/mouse-related usages, and vendor-defined feature report channels, all under multiple report IDs including 0x02, 0x06, 0x07, and 0x09.

This composite design explains why the official driver can both update OLED labels and inject standard keyboard shortcuts from the same hardware family. It also explains why stale states can manifest as “stuck modifiers”: the device maintains internal state across feature-report and keyboard-emulation paths unless initialization fully clears them.

## Driver-side logical model

XencelabsAgent treats the Quick Keys as a configurable “Remote” with XML-backed settings. The logs show the agent loading a remote named `Clicky`, locating XML config by device MAC-like ID, and then parsing button assignments through `ParseCustomFunction` records such as `*#Undo`, `*#Redo`, `Command`, and `Option`.

Each parsed function contains a compact encoding string such as `16777250:55+90:6` or `32:49`, which the agent converts into platform key events. The subsequent `m_key down` and `m_key up` lines show that these mappings resolve into macOS keycodes, confirming that the device itself is not only sending plain keyboard characters; instead, the Xencelabs software interprets remote events and generates OS-level shortcut events from stored config data.

## Derived button and shortcut behavior

The logs provide a partial default or test mapping for the first button page. That page includes the following bindings.

| Remote id | KeyIndex | Label/function | Encoded data |
|---|---:|---|---|
| 1 | 0 | Undo | `16777250:55+90:6`  |
| 2 | 1 | Redo | `16777250:55+89:16`  |
| 3 | 2 | Copy | `16777250:55+67:8`  |
| 4 | 3 | Paste | `16777250:55+86:9`  |
| 5 | 4 | Shift | `16777248:56`  |
| 6 | 5 | Command | `16777250:55`  |
| 7 | 6 | Option | `16777251:58`  |
| 8 | 7 | Space | `32:49`  |

These mappings also support the interpretation that a “stuck Command” problem can come from retained remote state or incomplete reset, because the software explicitly models Command as a distinct button-function with press and release transitions.

## Dial, ring, and OLED behavior

Official documentation says the dial supports up to four modes per application and the LED ring supports eight colors. The logs refine that into a concrete runtime model.

- Pressing the center dial button, logged as `Remote id down: 10`, cycles ring profiles through `ChangeRemoteLRFunctions to 1..4`.
- Each profile exposes at least four runtime attributes: `iCurRingIndex`, `nColorID`, `nBrightID`, and `nDialSensitivity`.
- Pressing the set/OLED button, logged as `Remote id down: 9`, triggers `ChangeOLEDFunctions`, which is consistent with switching displayed shortcut groups.
- Dial rotation produces directional events such as `RingID: 0 Dir: 1` and `RingID: 0 Dir: -1`, aligning with the raw `f0` and `f2` input reports seen in USB captures.

### Derived ring profile example

| Center-button press result | Ring index | Color ID | Brightness ID | Dial sensitivity |
|---|---:|---:|---:|---:|
| `ChangeRemoteLRFunctions to 2` | 2 | 7 | 2 | 3  |
| `ChangeRemoteLRFunctions to 3` | 3 | 5 | 2 | 3  |
| `ChangeRemoteLRFunctions to 4` | 4 | 4 | 2 | 3  |
| `ChangeRemoteLRFunctions to 1` | 1 | 7 | 1 | 1  |

The evidence supports a ring-profile table internal to either the driver config, the device, or both. The color and brightness values appear to be enumerated IDs rather than raw RGB or PWM values.

## Connection and power behavior

Xencelabs documentation states that the connection indicator blinks blue when searching, stays solid blue on successful wireless connection, and shows a breathing blue state when connected by USB cable. The charging indicator is documented as solid green when full, breathing green when charging, and solid amber when charge is low.

The logs also expose software-readable battery and OLED state values: `Battery get Value: 99 0` and `OLED get Value: 3 0`. Sleep behavior is configurable in the settings panel according to official documentation, and the agent logs repeatedly reference sleep-function handling while processing OLED and ring events.

The repeated log line `Can not Find Dongle Device` should not be treated as a physical absence in this capture. The same log segment shows the dongle present and active through `ReceiveUsbMsg` events, dongle VID/PID path enumeration, and successful remote event handling, so that message is best interpreted as a misleading internal lookup failure for a specific control path rather than an actual disconnect.

## Wireless behavior

The Quick Keys can operate over USB or the bundled wireless receiver, and the same dongle can serve both a Quick Keys and a Xencelabs tablet. Xencelabs support further states that a single dongle can pair with up to two devices and that pairing to a new receiver is initiated from the Settings application.

The pairing traces show that first-time or explicit pairing uses larger 64-byte feature reports carrying device identifiers, labels, and a shared token block. Once already paired, startup over the dongle uses a shorter initialization sequence with repeated `b4 01 01`, `b5` commands, label refresh traffic, and state refresh rather than the full 64-byte association exchange.

## Storage and configuration model

The available evidence points to a split storage model.

- Device-side nonvolatile state stores pairing or identity information sufficient for wired and wireless startup continuity.
- Driver-side XML configuration stores per-device remote mappings and display/function metadata keyed by MacAddr-like strings.
- Exported user profile files are documented by Xencelabs, but the low-level pairing and ID material observed in HID traces is not publicly documented in the same detail.

## Reset and initialization implications

The startup logs and HID traces suggest that clean initialization matters because the Quick Keys can retain logical state across sessions. Repeated `b4 01 01` and `b5` sequences during startup, along with subsequent label refreshes and mode-setting commands, appear to form the core reset-and-commit sequence used by the official driver.

That interpretation matches the observed failure mode where the device appears connected but behaves as if an old modifier or old connection state is still active. From a reverse-engineering standpoint, any custom driver that aims to replace the native stack should replicate not only the obvious button and OLED commands, but also the startup sequence that normalizes mode, dial profile, and modifier state.

## Reverse-engineered summary

| Category | Derived specification |
|---|---|
| Device class | Programmable HID shortcut remote with composite USB/dongle transport  |
| Primary report ID | 0x02 for control and event traffic  |
| Main input opcodes | `f0`, `f2`, and richer `f8` status on some paths  |
| Main output opcodes | `b0`, `b1`, `b4`, `b5`, `b8`  |
| Main buttons | 8 shortcut buttons + set/OLED button + center dial button  |
| Dial modes | Up to 4, each with index, color, brightness, and sensitivity attributes  |
| Shortcut groups | Up to 5 per application  |
| Display system | OLED label display driven by driver-written text and function metadata  |
| Pairing model | Host-driven wired pairing to dongle using HID feature reports with persistent identifiers  |
| Config key | Per-device MacAddr-like IDs such as `Maa6782b935f4`  |

## Confidence notes

The physical characteristics, supported modes, and battery/connectivity claims are strongly supported by official Xencelabs material. The HID opcode semantics, runtime identities, ring-profile structure, and driver/XML model are derived from the supplied traces and are therefore best treated as reverse-engineered behavior rather than vendor-documented API guarantees.

## Addendum 2026-07-07: `b4`/`b1` sub-opcodes and dongle addressing, confirmed via dtrace on `XencelabsDriver`

A follow-up capture (`sudo dtrace -s tools/hid_setreport_capture.d -p <XencelabsDriver PID> -o <file>`, triggered by a puck power-cycle + dongle reseat) resolved several items this doc left generic:

- **`b4` sub-opcodes are more specific than "configuration, identity, pairing, and mode setup":**
  - `b4 01 01 00 00 R G B 00 <addr>` — dial LED color, literal RGB (see `XencelabsControl.dialColorPayload`).
  - `b4 04 01 01 <n>` — dial sensitivity, `n` = 1–5 (`XencelabsControl.dialSensitivityPayload`). MockTab was missing this write entirely until 2026-07-07 — the native driver always pairs it with a color write.
  - `b4 08` and `b4 10` — zero-payload except the address field, sent once per full resync (order: `b1 01` reset → `b4 08` → `b4 10` → `b1 0a` → color/sensitivity/labels). Semantics still unconfirmed — no ASCII/text content to reverse from. Replicated best-effort in MockTab.
- **`b1 06 01` is the dial-mode/function label** (distinct from the per-key label field `b1 00`) — carries UTF-16 text like `"Zoomen"`, `"Satz A"`. Matches `XencelabsControl.TextField.modeName`.
- **`b1 0a`** — a previously uncatalogued field number, sent zero-length (clearing) once per resync alongside `b4 08`/`b4 10`. Unconfirmed semantics.
- **The address field (bytes 10–15) is not optional over the dongle.** This doc's opcode tables didn't flag it, but it's the actual reason MockTab's OLED/dial-LED writes were silently dropped when relayed through the wireless dongle (PID `0x5203`) even though they worked fine over direct USB: an all-zero address gives the dongle nothing to route the write to. Every `b4`/`b1` write the native driver sends over the dongle carries the puck's 6-byte identity (the same one broadcast in every report's trailer — see the dongle-relay memory note). Fixed in `WacomKnownDevice.swift` by threading `xencelabsDongleIdentity` through every `XencelabsControl` call site.
- Confirmed **`XencelabsAgent.app` never touches HID directly** — a separate dtrace pass targeting it (triggered the same reconnect sequence) showed zero `SetReport`/`GetReport`/`GetReportWithCallback` calls; its `OLED get Value`/`Battery get Value` logging is sourced via IPC from `XencelabsDriver`, not the device. `XencelabsDriver` is the only process worth tracing for protocol work.

Living implementation: `TabletKit/Sources/TabletKit/XencelabsControl.swift` (payload builders), `MockTab/Driver/WacomKnownDevice.swift` (call sites, relink, resync sequencing).
