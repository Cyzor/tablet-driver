// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import TabletKit

// MARK: - DisplayArrangementView

/// The displays drawn in their real arrangement, to scale, with wallpapers and
/// name badges; `isSelected` tints and outlines the mapped ones. Shared by the
/// Display pane's preview and the mapping sheet.
struct DisplayArrangementView: View {
    let displays: [DisplayInfo]
    let isSelected: (DisplayInfo) -> Bool
    /// Index of a clicked display; nil makes the view read-only.
    var onTap: ((Int) -> Void)? = nil

    @AppStorage(AppearancePrefs.storageKey) private var textSizeIndex: Int = AppearancePrefs.defaultIndex
    private var textScale: CGFloat { AppearancePrefs.scale(forIndex: textSizeIndex) }

    var body: some View {
        GeometryReader { geo in
            let scale = layoutScale(in: geo.size)
            let offset = layoutOffset(in: geo.size, scale: scale)
            let rects: [CGRect] = displays.map {
                swiftUIRect(for: $0, scale: scale, offset: offset)
            }
            let selectedStates: [Bool] = displays.map(isSelected)

            Canvas { ctx, _ in
                for (index, info) in displays.enumerated() {
                    let rect = rects[index]
                    let selected = selectedStates[index]
                    let path = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)

                    if let wallpaper = info.wallpaper {
                        let iSize = wallpaper.size
                        if iSize.width > 0, iSize.height > 0 {
                            let iAspect = iSize.width / iSize.height
                            let rAspect = rect.width / rect.height
                            let drawRect: CGRect
                            if iAspect > rAspect {
                                let w = rect.height * iAspect
                                drawRect = CGRect(
                                    x: rect.midX - w / 2, y: rect.minY,
                                    width: w, height: rect.height)
                            } else {
                                let h = rect.width / iAspect
                                drawRect = CGRect(
                                    x: rect.minX, y: rect.midY - h / 2,
                                    width: rect.width, height: h)
                            }
                            ctx.drawLayer { layer in
                                layer.clip(to: path)
                                layer.draw(Image(nsImage: wallpaper), in: drawRect)
                            }
                        }
                        let scrim: Color =
                            selected
                            ? Color.accentColor.opacity(0.30)
                            : Color.black.opacity(0.15)
                        ctx.fill(path, with: .color(scrim))
                    } else {
                        ctx.fill(
                            path,
                            with: .color(
                                selected
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.secondary.opacity(0.1)
                            ))
                    }

                    ctx.stroke(
                        path,
                        with: .color(
                            selected ? Color.accentColor : Color.secondary.opacity(0.45)
                        ), style: StrokeStyle(lineWidth: selected ? 2 : 1))

                    let hPad: CGFloat = 6
                    let vPad: CGFloat = 4
                    let maxTextW = rect.width - 8
                    let badgeFont = NSFont.systemFont(
                        ofSize: AppFontRole.badgeTitle.baseSize * textScale, weight: .bold)
                    let tier = info.labelTier(fitting: maxTextW - hPad * 2, font: badgeFont)
                    let titleString = tier == .index ? "\(info.listIndex)" : (tier == .firstWord ? info.firstWord : info.name)

                    let nameResolved = ctx.resolve(
                        Text(titleString).font(Font.appFont(.badgeTitle, scale: textScale)).bold().foregroundColor(.white))
                    let measure = CGSize(width: maxTextW, height: 40)
                    let nameSize = nameResolved.measure(in: measure)

                    if tier == .full {
                        let resResolved = ctx.resolve(
                            Text(info.resolution).font(Font.appFont(.badgeSubtitle, scale: textScale)).foregroundColor(.white))
                        let resSize = resResolved.measure(in: measure)

                        let nameY = rect.midY - 8
                        let resY = rect.midY + 8
                        let badgeW = min(
                            max(nameSize.width, resSize.width) + hPad * 2,
                            rect.width - 4)
                        let badge = CGRect(
                            x: rect.midX - badgeW / 2,
                            y: nameY - nameSize.height / 2 - vPad,
                            width: badgeW,
                            height: (resY + resSize.height / 2 + vPad)
                                - (nameY - nameSize.height / 2 - vPad))

                        ctx.drawLayer { layer in
                            layer.clip(to: Path(rect.insetBy(dx: 2, dy: 2)))
                            layer.fill(
                                Path(
                                    roundedRect: badge, cornerRadius: 3,
                                    style: .continuous),
                                with: .color(.black.opacity(0.42)))
                            layer.draw(
                                nameResolved,
                                at: CGPoint(x: rect.midX, y: nameY), anchor: .center)
                            layer.draw(
                                resResolved,
                                at: CGPoint(x: rect.midX, y: resY), anchor: .center)
                        }
                    } else {
                        // Too narrow for both lines — show one centered
                        // line (first word, or a bare index as a last resort).
                        let badgeW = min(nameSize.width + hPad * 2, rect.width - 4)
                        let badge = CGRect(
                            x: rect.midX - badgeW / 2,
                            y: rect.midY - nameSize.height / 2 - vPad,
                            width: badgeW,
                            height: nameSize.height + vPad * 2)

                        ctx.drawLayer { layer in
                            layer.clip(to: Path(rect.insetBy(dx: 2, dy: 2)))
                            layer.fill(
                                Path(
                                    roundedRect: badge, cornerRadius: 3,
                                    style: .continuous),
                                with: .color(.black.opacity(0.42)))
                            layer.draw(
                                nameResolved,
                                at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                        }
                    }
                }
            }
            .onTapGesture { location in
                guard let onTap, let i = rects.firstIndex(where: { $0.contains(location) }) else { return }
                onTap(i)
            }
        }
    }

    private func swiftUIRect(
        for info: DisplayInfo,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGRect {
        // CGDisplayBounds is already top-down (Y increases downward), same as
        // SwiftUI — no flip needed. Flipping it here inverted the vertical
        // stacking order of displays relative to each other.
        return CGRect(
            x: info.bounds.minX * scale + offset.x,
            y: info.bounds.minY * scale + offset.y,
            width: info.bounds.width * scale,
            height: info.bounds.height * scale
        )
    }

    private func layoutScale(in size: CGSize) -> CGFloat {
        guard !displays.isEmpty else { return 1 }
        let unionW = (displays.map(\.bounds.maxX).max()! - displays.map(\.bounds.minX).min()!)
        let unionH = (displays.map(\.bounds.maxY).max()! - displays.map(\.bounds.minY).min()!)
        guard unionW > 0, unionH > 0 else { return 1 }
        return min((size.width - 16) / unionW, (size.height - 16) / unionH)
    }

    private func layoutOffset(in size: CGSize, scale: CGFloat) -> CGPoint {
        guard !displays.isEmpty else { return .zero }
        let minX = displays.map(\.bounds.minX).min()!
        let minY = displays.map(\.bounds.minY).min()!
        let maxY = displays.map(\.bounds.maxY).max()!
        let scaledW = (displays.map(\.bounds.maxX).max()! - minX) * scale
        let scaledH = (maxY - minY) * scale
        return CGPoint(
            x: (size.width - scaledW) / 2 - minX * scale,
            y: (size.height - scaledH) / 2 - minY * scale
        )
    }
}
