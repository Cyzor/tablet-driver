2026-08-03

## Wacom GD‑0608‑U — Original Intuos 6×8 (USB)

Supersedes an earlier draft of this file that was assembled from web research
without hardware or independent-source corroboration (disclaimed inline as
"pseudo-layout, not bit-exact") and contained at least one wrong field size
(pressure called "11-bit" against Wacom's own 1024-level/10-bit spec). This
version is built from two primary sources instead:

1. **Wacom's own Intuos (GD-series) User's Manual** — archived at
   `Notes/Scratch/Wacom-Intuos-GD-Series-UsersManual.pdf` (gitignored;
   copyrighted, kept local-only). Covers the GD-0405/0608/0912/1212/1218-U/A
   models directly by name.
2. **OpenTabletDriver**'s `GD-0608-U.json` and sibling GD-*/XD-* configs, plus
   `IntuosV1ReportParser.cs` / `IntuosV1TabletReport.cs` — an independently
   written, long-shipping open-source parser. Confirmed by direct fetch
   2026-08-03 (`gh api repos/OpenTabletDriver/OpenTabletDriver/contents/...`).

Both agree with each other and with a user-submitted MockTab capture
(`Notes/Scratch/Discovery-Data-Caputure/Wacom-Intuos-GD-0608-U-2026-08-03.json`)
on the two bugs this device shipped with in MockTab.

### Identity

| | |
| :-- | :-- |
| Model | GD‑0608‑U (USB); GD‑0608‑A (ADB, not applicable on modern Macs) |
| Marketing name | Intuos 6×8, first generation (1998–2002) |
| VID / PID | 0x056A / 0x0021 |
| Sibling PIDs, same active area | 0x0042, 0x0047 (Intuos 2 / XD-0608-U — same chassis, second generation) |

### Confirmed specifications (Wacom manual, technical specifications table)

| Parameter | Value |
| :-- | :-- |
| Active area | 203.2 × 162.4 mm (8.13 × 6.45 in) |
| Coordinate resolution | 100 lpmm (2540 lpi) |
| Pressure levels | 1024 (10-bit) |
| Tilt | ±60° |
| Proximity / max reading height | 6 mm |
| Max report rate | 200 points/sec |
| Connector | USB A |

### Coordinate encoding — confirmed against OpenTabletDriver

`IntuosV1TabletReport.cs`:

```csharp
Position.X = (report[3] | report[2] << 8) << 1 | ((report[9] >> 1) & 1);
Position.Y = (report[5] | report[4] << 8) << 1 | (report[9] & 1);
Tilt.X = (((report[7] << 1) & 0x7E) | (report[8] >> 7)) - 64;
Tilt.Y = (report[8] & 0x7F) - 64;
Pressure = (report[6] << 3) | ((report[7] & 0xC0) >> 5) | (report[1] & 1);
```

This is bit-for-bit identical to `IntuosV1Decoder.decodeUSBPen` in
`TabletKit/Sources/TabletKit/Decoders/IntuosV1Decoder.swift`, independently
arrived at. OTD's declared `MaxX`/`MaxY` for `GD-0608-U.json` (40640/32480)
also match the manual's active area × 100 lpmm × 2 (the ×2 coming from the
`<<1 | fractional bit` — effective 5080 lpi in the decoder's output units):

- 203.2 mm × 100 × 2 = 40640
- 162.4 mm × 100 × 2 = 32480

Both bugs reported against MockTab traced to this:

**Screen area coverage too small.** `WacomDeviceRegistry`'s entry for 0x0021
carried the un-doubled values (20320/16240), so only the tablet's top-left
quadrant mapped across the full screen. Fixed 2026-08-03 in TabletKit; the
same correction (and the same OTD/manual cross-check) was applied to the
other nine Intuos 1/2 registry rows (0x0020, 0x0022–0x0024, 0x0041–0x0045),
which shared the same un-doubled-value bug. Three of those rows also had an
unrelated pre-existing active-height error (found via the same manual
cross-check) corrected in the same pass: 0x0020/0x0041 102→106 mm,
0x0022/0x0043 229→241 mm, 0x0023/0x0024/0x0044/0x0045 305→317 mm.

**Pressure triggers by just hovering.** Not a decode bug — the manual doesn't
document a hover-noise floor (that's not the kind of thing spec sheets carry),
and OTD's parser doesn't null out low-end noise either; every driver here
passes the raw EMR sensor value straight through, low-end noise included.
Wacom's own control panel exposed a "click threshold" for exactly this. Added
as `ToolSettings.pressureThreshold` / the Pen Feel pane's Click Threshold
slider — user-facing per-tool dial, off by default. `InputInjector`'s shared
`tipPressureThreshold` floor (0.004 normalized) was deliberately left alone
rather than raised for everyone; see its doc comment in `InputInjector.swift`.

### maxPressure: 1023, not OTD's 2046 — not a discrepancy

OTD declares `MaxPressure: 2046` and never right-shifts the combined 11-bit
pressure field. `IntuosV1Decoder.decodeUSBPen` right-shifts by 1 whenever
`spec.maxPressure <= 1023` (registry value for this whole family), so
`normalizedPressure = (raw >> 1) / 1023 ≈ raw / 2046`. Same ratio, two scales.

### Not yet examined

Tool-ID/transponder scheme (menu strip, lens cursor, 4D mouse — MockTab's
Intuos1/2 support is pen + KC-100-style mouse subtypes only, per
`IntuosV1Decoder`'s `subtype == 0x06`/`0x08` branches), DuoSwitch button-bit
mapping, and eraser-end behavior beyond the shared `hasEraser` flag. None of
these were reported broken; none have been verified working either.
