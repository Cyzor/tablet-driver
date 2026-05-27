# TabletKit Changelog

Changes to the `TabletKit` Swift package (the decoder layer published from `Package.swift`).
The MockTab app itself follows the version in `MockTab/Info.plist` and uses its own release notes
under [`release-notes/`](release-notes/).

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package is intended to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it ships past 1.0.  Pre-1.0, any minor bump may break source compatibility.

## [0.1.0] — Unreleased

First public API surface.  Pulled out of the MockTab app so the decoder layer
can be consumed independently.

### Added

- `TabletReportDecoder` protocol — vendor-neutral entry point that turns one HID
  input report into a `[DecodeResult]`.  Replaces the internal-only `WacomDecoder`
  name; `typealias WacomDecoder = TabletReportDecoder` is kept temporarily for
  source compatibility inside the MockTab repo and will be removed before 1.0.
- Public surface for the supporting value types: `DecodeResult`, `TabletPoint`,
  `ToolIdentity`, `AuxButtons`, `TouchContact`, `WirelessStatus`, `DigitizerSpec`,
  `DecoderState`.
- `WacomDeviceRegistry` exposed to the package target with:
  - `spec(forProductID:productString:)` overload for USB-string disambiguation
    (prepares for vendors like Huion that ship many models behind one PID).
  - `activeWidthMM` / `activeHeightMM` fields on `WacomDeviceSpec` and a derived
    `lpi: (x:, y:)?` accessor.  Hand-measured for the six `.verified` entries
    (PTZ-631W, PTH-851, PTH-660, PTH-860 USB + BT, DTK-2400) and bulk-backfilled
    from libwacom `.tablet` files for 78 additional entries — 84 of 135 entries
    now carry physical dimensions.  An LPI-consistency guard rejected 26
    libwacom rows that disagreed with our `maxX`/`maxY` ratios (notably
    libwacom's wrong Movink 13 dimensions).
  - `InitStep` enum replacing the previous `featureInit` / `featureInit2` /
    `featureInit2Delay` triple with an ordered `initSteps: [InitStep]` array.
    Cases: `.featureReport`, `.outputReport`, `.delay`, `.stringDescriptor` —
    the latter two reserved for future vendor-init shapes (Xencelabs / Huion).
  - 4 entries promoted `.experimental` → `.crossReferenced` after auditing
    against `linuxwacom/wacom-hid-descriptors`: Graphire (`0x0010`), Intuos3
    6×8 (`0x00B1`), Cintiq Pro 27 (`0x03C0`), Cintiq Pro 22 (`0x03D0`).
  - 12 recognition-only entries added for newer Wacom devices that appear in
    real linuxwacom sysinfo dumps but were previously absent: Cintiq Pro 16
    (`0x0350`/`0x0354`), Cintiq Pro 17 (`0x03C4`), Cintiq Companion 2
    (`0x0325`/`0x0326`), One Pen Display 13 (`0x03CB`), DTH134 (`0x03EC`),
    DTC121 (`0x03CF`/`0x03ED`/`0x4900`), Movink 13 alt PID (`0x03F2`),
    Intuos BT M (`0x0379`).  Marked `.experimental`; pen decode unverified.
- `VendorDeviceProfile` + `VendorDeviceRegistry` — vendor-neutral recognition
  table for non-Wacom tablets.  154 profiles bulk-imported from OpenTabletDriver
  configs for Huion, Xencelabs, and XP-Pen.  No decoder dispatch attached; the
  app can name these devices but doesn't decode their reports yet.  Lookup
  returns `[Profile]` (not `Profile?`) because Huion's product line packs
  dozens of distinct devices behind a single PID, discriminated only by USB
  string descriptors.
- `CaptureLogParser` (in the test target) — parses the in-app HID capture log
  format *and* the upstream `hid-recorder` text format
  (https://github.com/hidutils/hid-recorder) into `[CaptureRecord]`.  Lets a
  user-submitted log from any tablet bug report drop into a regression test
  in minutes: parse, replay through the relevant decoder, assert on the
  `[DecodeResult]` stream.
- SwiftPM `library` product named `TabletKit`.
- Per-file MPL-2.0 SPDX headers on every file compiled into the TabletKit target.
- `LICENSES/MPL-2.0.txt`.

### Changed

- SwiftPM target renamed `MockTabDecoders` → `TabletKit`.  Downstream code
  imports `TabletKit`.  Test target renamed to `TabletKitTests`; on-disk path
  stays `Tests/MockTabDecodersTests/` for now.
- `WacomDeviceSpec`: three init-related fields (`featureInit`, `featureInit2`,
  `featureInit2Delay`) replaced by a single `initSteps: [InitStep]`.  Existing
  Intuos3 PTZ two-stage sequences migrated 1:1 as
  `[.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])]`.
  Behaviour-preserving for every device currently supported.

### Notes

- The MockTab app remains GPL-3.0-or-later; this package is MPL-2.0.  See
  `README.md` for the dual-license rationale.
- No git tag is published yet — pin by branch or commit if you depend on this.
