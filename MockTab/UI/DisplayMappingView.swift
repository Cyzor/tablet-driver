// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI
import CoreGraphics
import AppKit

struct DisplayMappingView: View {
    @ObservedObject var settings:      TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry
    @State private var displays: [DisplayInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            Spacer(minLength: 0)
            PresetStatusBar(settings: settings)
        }
        .onAppear { displays = DisplayInfo.all() }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Display Mapping").font(.headline)
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
            }

            Text("The active tablet area maps to the selected display.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Target display", selection: $settings.targetDisplayIndex) {
                Text("Primary display").tag(0)
                ForEach(Array(displays.enumerated()), id: \.offset) { index, info in
                    Text(info.pickerLabel).tag(index + 1)
                }
            }
            .pickerStyle(.radioGroup)

            displayCanvas
        }
        .padding()
    }

    // MARK: - Canvas layout

    private var displayCanvas: some View {
        GeometryReader { geo in
            let scale  = layoutScale(in: geo.size)
            let offset = layoutOffset(in: geo.size, scale: scale)
            // Maximum Y in CG coordinates — used to flip from CG (Y up) → SwiftUI (Y down).
            let maxCGY = displays.map(\.bounds.maxY).max() ?? 0
            // Pre-compute rects so the tap handler can use them.
            let rects: [CGRect] = displays.map {
                swiftUIRect(for: $0, maxCGY: maxCGY, scale: scale, offset: offset)
            }

            Canvas { ctx, _ in
                for (index, info) in displays.enumerated() {
                    let rect     = rects[index]
                    let selected = settings.targetDisplayIndex == index + 1
                    let path     = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)

                    if let wallpaper = info.wallpaper {
                        // Aspect-fill the wallpaper thumbnail, clipped to the display rect.
                        let iSize = wallpaper.size
                        if iSize.width > 0, iSize.height > 0 {
                            let iAspect  = iSize.width / iSize.height
                            let rAspect  = rect.width  / rect.height
                            let drawRect: CGRect
                            if iAspect > rAspect {
                                // Image is wider — fit height, crop sides.
                                let w = rect.height * iAspect
                                drawRect = CGRect(x: rect.midX - w / 2, y: rect.minY,
                                                  width: w, height: rect.height)
                            } else {
                                // Image is taller — fit width, crop top/bottom.
                                let h = rect.width / iAspect
                                drawRect = CGRect(x: rect.minX, y: rect.midY - h / 2,
                                                  width: rect.width, height: h)
                            }
                            ctx.drawLayer { layer in
                                layer.clip(to: path)
                                layer.draw(Image(nsImage: wallpaper), in: drawRect)
                            }
                        }
                        // Scrim — dark tint for readability; accent tint when selected.
                        let scrim: Color = selected
                            ? Color.accentColor.opacity(0.30)
                            : Color.black.opacity(0.15)
                        ctx.fill(path, with: .color(scrim))
                    } else {
                        // Fallback flat fill when no wallpaper image is available.
                        ctx.fill(path, with: .color(
                            selected ? Color.accentColor.opacity(0.18)
                                     : Color.secondary.opacity(0.1)
                        ))
                    }

                    // Border
                    ctx.stroke(path, with: .color(
                        selected ? Color.accentColor : Color.secondary.opacity(0.45)
                    ), style: StrokeStyle(lineWidth: selected ? 2 : 1))

                    // Labels — measure first so the badge fits the text exactly.
                    let nameResolved = ctx.resolve(
                        Text(info.name).font(.caption2).bold().foregroundColor(.white))
                    let resResolved  = ctx.resolve(
                        Text(info.resolution).font(.caption2).foregroundColor(.white))
                    let measure  = CGSize(width: rect.width - 8, height: 40)
                    let nameSize = nameResolved.measure(in: measure)
                    let resSize  = resResolved.measure(in: measure)

                    // Caption-style badge: dark translucent pill behind both lines.
                    let hPad: CGFloat = 6
                    let vPad: CGFloat = 4
                    let nameY   = rect.midY - 8
                    let resY    = rect.midY + 8
                    let badgeW  = min(max(nameSize.width, resSize.width) + hPad * 2,
                                     rect.width - 4)
                    let badge   = CGRect(x: rect.midX - badgeW / 2,
                                         y: nameY - nameSize.height / 2 - vPad,
                                         width:  badgeW,
                                         height: (resY + resSize.height / 2 + vPad)
                                               - (nameY - nameSize.height / 2 - vPad))

                    ctx.drawLayer { layer in
                        layer.clip(to: Path(rect.insetBy(dx: 2, dy: 2)))
                        layer.fill(Path(roundedRect: badge, cornerRadius: 3,
                                        style: .continuous),
                                   with: .color(.black.opacity(0.42)))
                        layer.draw(nameResolved,
                                   at: CGPoint(x: rect.midX, y: nameY), anchor: .center)
                        layer.draw(resResolved,
                                   at: CGPoint(x: rect.midX, y: resY),  anchor: .center)
                    }
                }
            }
            .onTapGesture { location in
                for (index, rect) in rects.enumerated() where rect.contains(location) {
                    settings.targetDisplayIndex = index + 1
                    break
                }
            }
        }
        .frame(height: 180)
    }

    // MARK: - Coordinate helpers

    /// Converts a CGDisplayBounds rect to SwiftUI layout coordinates (Y flipped, scaled, offset).
    private func swiftUIRect(for info: DisplayInfo,
                             maxCGY: CGFloat,
                             scale: CGFloat,
                             offset: CGPoint) -> CGRect {
        // CGDisplayBounds uses a coordinate space where Y increases upward (Quartz).
        // Flip Y so that "above" in System Preferences appears at the top in our view.
        let flippedY = maxCGY - info.bounds.maxY
        return CGRect(
            x:      info.bounds.minX  * scale + offset.x,
            y:      flippedY          * scale + offset.y,
            width:  info.bounds.width * scale,
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
        let minX    = displays.map(\.bounds.minX).min()!
        let minY    = displays.map(\.bounds.minY).min()!
        let maxY    = displays.map(\.bounds.maxY).max()!
        let scaledW = (displays.map(\.bounds.maxX).max()! - minX) * scale
        let scaledH = (maxY - minY) * scale
        return CGPoint(
            x: (size.width  - scaledW) / 2 - minX * scale,
            y: (size.height - scaledH) / 2
            // No minY term needed: the Y flip is handled in swiftUIRect.
        )
    }
}

// MARK: - DisplayInfo

struct DisplayInfo {
    var id:         CGDirectDisplayID
    var bounds:     CGRect    // in CGDisplayBounds / Quartz coordinates
    var name:       String    // localised device name if available
    var resolution: String    // e.g. "2560×1440"
    var wallpaper:  NSImage?  // desktop image, or nil for solid colour / animated backdrops

    /// Label shown in the radio-button picker.
    var pickerLabel: String { "\(name) (\(resolution))" }

    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        // Build ID → NSScreen map in one pass; used for both name and wallpaper lookup.
        var screenMap: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID {
                screenMap[num] = screen
            }
        }

        return ids.enumerated().map { index, id in
            let name   = screenMap[id]?.localizedName ?? "Display \(index + 1)"
            let w      = Int(CGDisplayPixelsWide(id))
            let h      = Int(CGDisplayPixelsHigh(id))

            // NSWorkspace.desktopImageURL(for:) requires no permissions and fires
            // no prompts — it is a plain metadata read available since macOS 10.6.
            // NSImage(contentsOf:) is an ordinary file read; this app is not
            // sandboxed so no entitlement or consent dialog is involved.
            // Both calls return nil gracefully for solid-colour / animated backdrops.
            let wallpaper: NSImage? = screenMap[id].flatMap { screen in
                NSWorkspace.shared.desktopImageURL(for: screen)
                    .flatMap { NSImage(contentsOf: $0) }
            }

            return DisplayInfo(id: id, bounds: CGDisplayBounds(id),
                               name: name, resolution: "\(w)×\(h)",
                               wallpaper: wallpaper)
        }
    }
}
