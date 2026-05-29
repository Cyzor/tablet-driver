# TabletKit Changelog

This changelog covers the `TabletKit` Swift package (the decoder layer defined in `Package.swift`).
The MockTab app tracks its own version in `MockTab/Info.plist` and maintains separate release notes in `release-notes/`.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and will adopt [Semantic Versioning](https://semver.org/spec/v2.0.0.html) after 1.0. Before 1.0, minor versions may break source compatibility.

## [0.1.0] — 2026-05-28

Introduces the first public API. Extracted from the MockTab app so the decoder layer can stand alone.

### Added

- `TabletReportDecoder` protocol — vendor-neutral entry point that converts one HID input report into `[DecodeResult]`. Replaces the internal `WacomDecoder`; keeps `typealias WacomDecoder = TabletReportDecoder` temporarily for MockTab source compatibility (to be removed before 1.0).
- Public value types: `DecodeResult`, `TabletPoint`, `ToolIdentity`, `AuxButtons`, `TouchContact`, `WirelessStatus`, `DigitizerSpec`, `DecoderState`.
- `WacomDeviceRegistry`, now public in the package target, with:
  - `spec(forProductID:productString:)` overload for USB string disambiguation (prepares for vendors like Huion that reuse PIDs across models).
  - `activeWidthMM` / `activeHeightMM` on `WacomDeviceSpec` and derived `lpi: (x:, y:)?`. Hand-measured six `.verified` devices (PTZ-631W, PTH-851, PTH-660, PTH-860 USB + BT, DTK-2400); backfilled 78 entries from libwacom `.tablet` files; filled 22 more using Wacom's 2540 LPI consumer standard or direct spec sheets; filled 11 more (Graphire `0x0010`/`0x0011`/`0x0013`/`0x0015`, Volito `0x0060`/`0x0062`, PenStation2 `0x0061`, DTU-1031 `0x00FB`, Bamboo One `0x0069`, Bamboo Pad `0x0318`/`0x0319`) from libwacom data, falling back to `input-wacom` 4.18 features tables only where libwacom has no entry. The libwacom verification pass also corrected six previously-kernel-derived values where the family-wide resolution constants (`WACOM_VOLITO_RES`, `WACOM_INTUOS_RES`) proved approximate — the Volito 0x0060 height was off by 25%, DTU-1031 height by ~10%, the Graphire 4×5 family height by ~10%. Now 128 of 135 entries include physical dimensions (up from 6); the remaining 7 are four early Graphire/Bamboo variants whose PIDs collide between libwacom, kernel, and OTD, and three wireless receivers (no active area). An LPI consistency check rejected libwacom rows that conflicted with `maxX`/`maxY` ratios (including incorrect Movink 13 data), which we replaced with Wacom specs.
  - `InitStep` enum replaces `featureInit`, `featureInit2`, and `featureInit2Delay` with ordered `initSteps: [InitStep]`. Cases: `.featureReport`, `.outputReport`, `.delay`, `.stringDescriptor` (the latter two reserved for future vendor init flows such as Xencelabs and Huion).
  - Promoted 4 entries from `.experimental` to `.crossReferenced` after auditing against `linuxwacom/wacom-hid-descriptors`: Graphire (`0x0010`), Intuos3 6×8 (`0x00B1`), Cintiq Pro 27 (`0x03C0`), Cintiq Pro 22 (`0x03D0`).
  - Added 12 recognition-only entries from real linuxwacom sysinfo dumps: Cintiq Pro 16 (`0x0350`/`0x0354`), Cintiq Pro 17 (`0x03C4`), Cintiq Companion 2 (`0x0325`/`0x0326`), One Pen Display 13 (`0x03CB`), DTH134 (`0x03EC`), DTC121 (`0x03CF`/`0x03ED`/`0x4900`), Movink 13 alt PID (`0x03F2`), Intuos BT M (`0x0379`). Marked `.experimental`; pen decode remains unverified.
- `VendorDeviceProfile` and `VendorDeviceRegistry` — vendor-neutral recognition for non-Wacom tablets. Imported 154 profiles from OpenTabletDriver (Huion, Xencelabs, XP-Pen). No decoder dispatch yet; the app can identify but not decode these devices. Lookup returns `[Profile]` (not `Profile?`) because some vendors multiplex many models behind one PID and distinguish them via USB string descriptors.
- `TabletManager` expands IOHIDManager matching from Wacom (`0x056A`) to include Huion (`0x256C`), Xencelabs / XP-Pen (`0x28BD`), and UC-Logic (`0x5543`). The system looks up non-Wacom devices in `VendorDeviceRegistry`, logs them (`recognised Huion device — H1060P (…) — no decoder support yet`), and ignores them. Previously, the app did not detect these devices.
- `CaptureLogParser` (test target) parses both the in-app HID capture format and the upstream `hid-recorder` format (https://github.com/hidutils/hid-recorder) into `[CaptureRecord]`. This enables rapid regression tests: parse a user log, replay it through a decoder, and assert on `[DecodeResult]`.
- SwiftPM `library` product: `TabletKit`.
- Per-file MPL-2.0 SPDX headers for all files in the TabletKit target.
- `LICENSES/MPL-2.0.txt`.

### Changed

- Renamed SwiftPM target `MockTabDecoders` → `TabletKit`. Downstream code now imports `TabletKit`. Renamed test target to `TabletKitTests`; kept on-disk path `Tests/MockTabDecodersTests/` for now.
- Updated `WacomDeviceSpec`: replaced `featureInit`, `featureInit2`, and `featureInit2Delay` with `initSteps: [InitStep]`. Migrated existing Intuos3 PTZ sequences directly to `[.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])]`. Preserves behavior for all supported devices.

### Notes

- The MockTab app remains GPL-3.0-or-later; this package uses MPL-2.0. See `README.md` for the dual-license rationale.
