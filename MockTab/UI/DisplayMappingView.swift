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

import AppKit
import CoreGraphics
import SwiftUI

struct DisplayMappingView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    @State private var displays: [DisplayInfo] = []
    @State private var rangeStart: Int = -1

    private let modeAll = TabletSettings.displayModeAll  // -1
    private let modeToggle = TabletSettings.displayModeToggle  // -2

    // MARK: - Recording Binding Helper

    /// Creates a binding that automatically registers undo when the value changes.
    private func recordingBinding<T: Equatable>(
        _ name: String,
        get: @escaping () -> T,
        set: @escaping (T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { newValue in
                let oldValue = get()
                guard newValue != oldValue else { return }
                set(newValue)
                settings.record(name) { set(oldValue) }
            }
        )
    }

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

            Picker(
                "",
                selection: recordingBinding(
                    "Display Mapping",
                    get: { settings.targetDisplayIndex },
                    set: { settings.targetDisplayIndex = $0 }
                )
            ) {
                Text("Primary display").tag(0)
                ForEach(displays, id: \.listIndex) { info in
                    Text(info.pickerLabel).tag(info.listIndex)
                }
                Text("Toggle between displays").tag(modeToggle)
                    .disabled(displays.count <= 1)
                Text("All — span across all displays").tag(modeAll)
                    .disabled(displays.count <= 1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if settings.targetDisplayIndex == modeToggle {
                toggleSection
            }

            displayCanvas
        }
        .padding()
    }

    // MARK: - Toggle section

    private var toggleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Displays in rotation — ⌘+click individual, ⇧+click ranges")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, info in
                    toggleThumbnail(at: index, info: info)
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(displays.count <= 1)
    }

    private func toggleThumbnail(at index: Int, info: DisplayInfo) -> some View {
        let included = isIncluded(info)

        return ZStack {
            // Wallpaper or flat fill
            if let wp = info.wallpaper {
                Image(nsImage: wp)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 48)
                    .clipped()
                    .opacity(included ? 0.65 : 0.20)
            } else {
                Rectangle()
                    .fill(
                        included
                            ? Color.accentColor.opacity(0.15)
                            : Color.secondary.opacity(0.07))
            }

            // Include / exclude icon
            Image(systemName: included ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(included ? Color.green : Color.secondary)
                .shadow(color: .black.opacity(0.4), radius: 1)

            // Display name badge
            VStack(spacing: 0) {
                Spacer()
                Text(info.name)
                    .font(.caption2)
                    .bold()
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .padding(.bottom, 3)
            }
        }
        .frame(width: 76, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    included ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: included ? 1.5 : 1
                )
        )
        .onTapGesture {
            let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

            if flags.contains(.shift) {
                // Shift+click: range selection from rangeStart to current index
                if rangeStart < 0 {
                    rangeStart = index
                } else {
                    let start = min(rangeStart, index)
                    let end = max(rangeStart, index)
                    var ids = settings.toggleDisplayIDSet
                    if ids.isEmpty { ids = Set(displays.map(\.id)) }
                    // Include all displays in the range
                    for i in start...end {
                        ids.insert(displays[i].id)
                    }
                    // Simplify back to empty (= all) when every display is included
                    settings.toggleDisplayIDSet = (ids == Set(displays.map(\.id))) ? [] : ids
                    rangeStart = -1
                }
            } else if flags.contains(.command) {
                // Cmd+click: toggle individual display
                toggleIncluded(info)
            } else {
                // Regular click: toggle individual display
                toggleIncluded(info)
                rangeStart = -1
            }
        }
    }

    // MARK: - Toggle helpers

    private func isIncluded(_ info: DisplayInfo) -> Bool {
        let ids = settings.toggleDisplayIDSet
        return ids.isEmpty || ids.contains(info.id)
    }

    private func toggleIncluded(_ info: DisplayInfo) {
        let oldIDs = settings.toggleDisplayIDSet
        var ids = oldIDs
        if ids.isEmpty {
            // All included implicitly → make explicit so we can exclude one
            ids = Set(displays.map(\.id))
        }
        if ids.contains(info.id) {
            ids.remove(info.id)
            if ids.isEmpty { return }  // never exclude the last display
        } else {
            ids.insert(info.id)
        }
        // Simplify back to empty (= all) when every display is included
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        settings.toggleDisplayIDSet = newIDs
        // Register undo for the toggle set change
        settings.record("Toggle Display Set") {
            settings.toggleDisplayIDSet = oldIDs
        }
    }

    /// Cmd+click on a canvas rectangle: builds the toggle rotation additively.
    /// Starting from an "all" (empty) set, the first click begins an explicit
    /// set with just that display; subsequent clicks add or remove entries.
    private func canvasCmdClick(at index: Int) {
        guard displays.indices.contains(index) else { return }
        let info = displays[index]
        let oldIDs = settings.toggleDisplayIDSet
        var ids = oldIDs
        if ids.isEmpty {
            // Start fresh: select only the clicked display
            ids = [info.id]
        } else if ids.contains(info.id) {
            ids.remove(info.id)
            if ids.isEmpty { ids = [] }  // back to "all"
        } else {
            ids.insert(info.id)
        }
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        settings.toggleDisplayIDSet = newIDs
        settings.targetDisplayIndex = modeToggle
        // Register undo for the toggle set change
        settings.record("Toggle Display Set") {
            settings.toggleDisplayIDSet = oldIDs
        }
    }

    // MARK: - Canvas layout

    private var displayCanvas: some View {
        GeometryReader { geo in
            let scale = layoutScale(in: geo.size)
            let offset = layoutOffset(in: geo.size, scale: scale)
            let maxCGY = displays.map(\.bounds.maxY).max() ?? 0
            let rects: [CGRect] = displays.map {
                swiftUIRect(for: $0, maxCGY: maxCGY, scale: scale, offset: offset)
            }
            // Pre-compute per-display selection state for use in Canvas closure.
            let idx = settings.targetDisplayIndex
            let toggleIDSet = settings.toggleDisplayIDSet
            let selectedStates: [Bool] = displays.map { info in
                if idx == modeAll { return true }
                if idx == modeToggle { return toggleIDSet.isEmpty || toggleIDSet.contains(info.id) }
                return idx == info.listIndex
            }

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

                    let nameResolved = ctx.resolve(
                        Text(info.name).font(.caption2).bold().foregroundColor(.white))
                    let resResolved = ctx.resolve(
                        Text(info.resolution).font(.caption2).foregroundColor(.white))
                    let measure = CGSize(width: rect.width - 8, height: 40)
                    let nameSize = nameResolved.measure(in: measure)
                    let resSize = resResolved.measure(in: measure)

                    let hPad: CGFloat = 6
                    let vPad: CGFloat = 4
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
                }
            }
            .onTapGesture { location in
                let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

                if flags.contains(.shift), displays.count > 1 {
                    // Shift+click any display → All mode
                    settings.targetDisplayIndex = modeAll

                } else if flags.contains(.command), displays.count > 1 {
                    // Cmd+click → build toggle rotation and activate Toggle mode
                    if let i = rects.firstIndex(where: { $0.contains(location) }) {
                        canvasCmdClick(at: i)
                    }

                } else {
                    // Plain click → select that specific display
                    for (index, rect) in rects.enumerated() where rect.contains(location) {
                        settings.targetDisplayIndex = displays[index].listIndex
                        break
                    }
                }
            }
        }
        .frame(height: 180)
    }

    // MARK: - Coordinate helpers

    private func swiftUIRect(
        for info: DisplayInfo,
        maxCGY: CGFloat,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGRect {
        let flippedY = maxCGY - info.bounds.maxY
        return CGRect(
            x: info.bounds.minX * scale + offset.x,
            y: flippedY * scale + offset.y,
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
            y: (size.height - scaledH) / 2
        )
    }
}

// MARK: - DisplayInfo

struct DisplayInfo {
    var id: CGDirectDisplayID
    /// 1-based index into CGGetActiveDisplayList — the value stored in targetDisplayIndex.
    var listIndex: Int
    var bounds: CGRect  // in CGDisplayBounds / Quartz coordinates
    var name: String  // localised device name if available
    var resolution: String  // e.g. "2560×1440"
    var wallpaper: NSImage?  // desktop image, or nil for solid colour / animated backdrops

    var pickerLabel: String { "\(name) (\(resolution))" }

    /// Returns all active displays sorted by screen position (left→right, top→bottom),
    /// matching the arrangement shown in System Settings > Displays.
    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        var screenMap: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            {
                screenMap[num] = screen
            }
        }

        let unsorted = ids.enumerated().map { index, id -> DisplayInfo in
            let name = screenMap[id]?.localizedName ?? "Display \(index + 1)"
            let w = Int(CGDisplayPixelsWide(id))
            let h = Int(CGDisplayPixelsHigh(id))
            let wallpaper: NSImage? = screenMap[id].flatMap { screen in
                NSWorkspace.shared.desktopImageURL(for: screen)
                    .flatMap { NSImage(contentsOf: $0) }
            }
            return DisplayInfo(
                id: id, listIndex: index + 1,
                bounds: CGDisplayBounds(id),
                name: name, resolution: "\(w)×\(h)",
                wallpaper: wallpaper)
        }

        // Sort left-to-right, then top-to-bottom — matches System Settings Displays arrangement.
        return unsorted.sorted {
            if abs($0.bounds.minX - $1.bounds.minX) > 1 { return $0.bounds.minX < $1.bounds.minX }
            return $0.bounds.minY < $1.bounds.minY
        }
    }
}
