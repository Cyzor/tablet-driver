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
    `lpi: (x:, y:)?` accessor.  Backfilled for PTZ-631W, PTH-851, PTH-660,
    PTH-860 USB + BT, and DTK-2400.  Other entries return `nil` until verified
    against published Wacom specs.
- SwiftPM `library` product named `TabletKit`.
- Per-file MPL-2.0 SPDX headers on every file compiled into the TabletKit target.
- `LICENSES/MPL-2.0.txt`.

### Changed

- SwiftPM target renamed `MockTabDecoders` → `TabletKit`.  Downstream code
  imports `TabletKit`.  Test target renamed to `TabletKitTests`; on-disk path
  stays `Tests/MockTabDecodersTests/` for now.

### Notes

- The MockTab app remains GPL-3.0-or-later; this package is MPL-2.0.  See
  `README.md` for the dual-license rationale.
- No git tag is published yet — pin by branch or commit if you depend on this.
