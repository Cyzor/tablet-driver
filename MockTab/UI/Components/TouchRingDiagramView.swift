// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - TouchRingDiagramView

/// Schematic top-down view of a touch ring.  The currently selected slot
/// (`activeSlotIndex`) fills in accent colour; the centre button fills in
/// accent when `centerDown` is true.
///
/// Mirrors PenDiagramView's perf model: static pre-parsed paths, single
/// Canvas draw pass, Equatable on minimal state so the ~16 Hz liveButtons
/// invalidations in ButtonMappingView short-circuit when nothing visible
/// has changed.
struct TouchRingDiagramView: View, Equatable {
    /// 0-based slot index of the currently active ring mode (0..<slotCount).
    let activeSlotIndex: Int
    /// True while the ring centre button is physically held.
    let centerDown: Bool
    /// Number of visual slots: 4 for most tablets, 3 for Cintiq 24HD-class.
    let slotCount: Int

    // SVG viewBox is 0 0 137.63 137.63 for both quarters and thirds variants.
    private static let svgSize = 137.63

    // MARK: - Pre-parsed paths (quarters)

    // swiftlint:disable line_length
    private static let outlineQ = Path(svgData:
        "M68.81,2c36.84,0,66.81,29.97,66.81,66.81s-29.97,66.81-66.81,66.81S2,105.66,2,68.81,31.97,2,68.81,2M68.81,0C30.87,0,0,30.87,0,68.81s30.87,68.81,68.81,68.81,68.81-30.87,68.81-68.81S106.76,0,68.81,0h0Z")
    private static let centerQ = Path(svgData:
        "M68.81,96.05c7.54,0,14.32-3.04,19.26-7.98,4.94-4.95,7.98-11.72,7.98-19.26,0-7.54-3.04-14.32-7.98-19.26-4.95-4.94-11.72-7.98-19.26-7.98-7.54,0-14.32,3.04-19.26,7.98-4.94,4.95-7.98,11.72-7.98,19.26,0,7.54,3.04,14.32,7.98,19.26,4.95,4.94,11.72,7.98,19.26,7.98Z")
    // Quarter slots, indexed 0..3 → top-left, top-right, bottom-right, bottom-left
    // (Mode 1 = upper-left, advancing clockwise. Hardware LED byte sent is
    //  (index + 1) % 4 — see setRingLED — so byte 0 = BL remains the hardware
    //  origin, but our user-visible slot 0 maps to TL/UL.  SVG IDs ring-slot-1..4
    //  are TL/TR/BR/BL; listed here as 1, 2, 3, 4.)
    private static let slotsQ: [Path] = [
        Path(svgData: "M30.04,64.81c.97,0,1.82-.7,1.97-1.66,1.22-8.02,5-15.21,10.48-20.68,5.46-5.47,12.66-9.25,20.68-10.48.96-.15,1.66-1,1.66-1.97V7.3c0-1.19-1.03-2.11-2.22-1.99-15.13,1.46-28.75,8.21-38.91,18.38C13.53,33.85,6.78,47.46,5.31,62.6c-.11,1.18.8,2.22,1.99,2.22h22.73Z"),
        Path(svgData: "M107.59,64.81h22.73c1.19,0,2.11-1.03,1.99-2.22-1.46-15.13-8.21-28.75-18.38-38.91-10.16-10.16-23.77-16.91-38.91-18.38-1.18-.11-2.22.8-2.22,1.99v22.73c0,.97.7,1.82,1.66,1.97,8.02,1.22,15.21,5,20.68,10.48,5.47,5.46,9.25,12.66,10.48,20.68.15.96,1,1.66,1.97,1.66Z"),
        Path(svgData: "M107.59,72.81c-.97,0-1.82.7-1.97,1.66-1.22,8.02-5,15.21-10.48,20.68-5.46,5.47-12.66,9.25-20.68,10.48-.96.15-1.66,1-1.66,1.97v22.73c0,1.19,1.03,2.11,2.22,1.99,15.13-1.46,28.75-8.21,38.91-18.38,10.16-10.16,16.91-23.77,18.38-38.91.11-1.18-.8-2.22-1.99-2.22h-22.73Z"),
        Path(svgData: "M30.04,72.81H7.3c-1.19,0-2.11,1.03-1.99,2.22,1.46,15.13,8.21,28.75,18.38,38.91,10.16,10.16,23.77,16.91,38.91,18.38,1.18.11,2.22-.8,2.22-1.99v-22.73c0-.97-.7-1.82-1.66-1.97-8.02-1.22-15.21-5-20.68-10.48-5.47-5.46-9.25-12.66-10.48-20.68-.15-.96-1-1.66-1.97-1.66Z"),
    ]

    // MARK: - Pre-parsed paths (thirds, for Cintiq 24HD and similar)

    private static let centerT = Path(svgData:
        "M68.81,97.05c7.81,0,14.85-3.15,19.97-8.27,5.12-5.12,8.27-12.16,8.27-19.97,0-7.81-3.15-14.85-8.27-19.97-5.12-5.12-12.16-8.27-19.97-8.27-7.81,0-14.85,3.15-19.97,8.27-5.12,5.12-8.27,12.16-8.27,19.97,0,7.81,3.15,14.85,8.27,19.97,5.12,5.12,12.16,8.27,19.97,8.27Z")
    // Third slots, indexed 0..2 → left, right, bottom
    // (Modes advance counter-clockwise from the left wedge.
    private static let slotsT: [Path] = [
        Path(svgData: "M34.52,85.12c.83-.51,1.19-1.54.81-2.44-1.77-4.28-2.76-8.96-2.76-13.87,0-9.99,4.06-19.08,10.61-25.63,5.29-5.29,12.23-8.96,19.97-10.17.96-.15,1.65-1,1.65-1.97V7.3c0-1.19-1.03-2.11-2.22-1.99-15.13,1.46-28.75,8.21-38.91,18.38-11.54,11.53-18.69,27.52-18.69,45.12,0,9.98,2.31,19.44,6.4,27.86.52,1.07,1.84,1.47,2.85.85l20.26-12.4Z"),
        Path(svgData: "M113.94,23.69c-10.16-10.16-23.77-16.91-38.91-18.38-1.18-.11-2.22.8-2.22,1.99v23.75c0,.97.69,1.82,1.65,1.97,7.74,1.21,14.69,4.88,19.97,10.17,6.55,6.55,10.62,15.63,10.61,25.63,0,4.91-.98,9.59-2.76,13.87-.37.9-.01,1.93.81,2.44l20.26,12.4c1.01.62,2.33.22,2.85-.85,4.1-8.42,6.41-17.88,6.4-27.86,0-17.61-7.15-33.59-18.69-45.12Z"),
        Path(svgData: "M98.93,91.94c-.83-.51-1.92-.35-2.55.39s-1.27,1.43-1.94,2.11c-6.55,6.55-15.63,10.62-25.63,10.61-9.99,0-19.08-4.06-25.63-10.61-.68-.68-1.32-1.38-1.94-2.11s-1.72-.9-2.55-.39l-20.25,12.4c-1.01.62-1.26,1.98-.55,2.93,1.78,2.36,3.71,4.59,5.79,6.67,11.53,11.54,27.52,18.69,45.12,18.69,17.61,0,33.59-7.15,45.12-18.69,2.08-2.08,4.01-4.31,5.79-6.67.71-.95.47-2.31-.55-2.93l-20.25-12.4Z"),
    ]
    // swiftlint:enable line_length

    var body: some View {
        Canvas { context, size in
            // Square ring centred in available space, preserving aspect ratio.
            let scale = min(size.width, size.height) / Self.svgSize
            let drawn = Self.svgSize * scale
            let tx = (size.width - drawn) / 2.0
            let ty = (size.height - drawn) / 2.0
            var t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)

            func draw(_ path: Path, fill: Color, stroke: Color) {
                guard let xp = path.cgPath.copy(using: &t) else { return }
                let p = Path(xp)
                context.fill(p, with: .color(fill))
                context.stroke(p, with: .color(stroke), style: StrokeStyle(lineWidth: 0.1))
            }

            let passive = Color.secondary
            let bodyFill = Color.primary.opacity(0.80)
            let strokeDim = Color.secondary
            let accent = Color.accentColor

            let useThirds = slotCount == 3
            let slotPaths = useThirds ? Self.slotsT : Self.slotsQ
            let centerPath = useThirds ? Self.centerT : Self.centerQ

            draw(Self.outlineQ, fill: bodyFill, stroke: strokeDim)
            for (idx, path) in slotPaths.enumerated() {
                let isActive = idx == activeSlotIndex
                draw(path,
                     fill: isActive ? accent : passive,
                     stroke: isActive ? accent : strokeDim)
            }
            draw(centerPath,
                 fill: centerDown ? accent : bodyFill,
                 stroke: centerDown ? accent : strokeDim)
        }
    }
}
