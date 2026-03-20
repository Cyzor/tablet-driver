import SwiftUI
import CoreGraphics
import AppKit

struct DisplayMappingView: View {
    @ObservedObject var settings: TabletSettings
    @State private var displays: [DisplayInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display Mapping")
                .font(.headline)

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

            displayLayout
        }
        .padding()
        .onAppear { displays = DisplayInfo.all() }
    }

    // MARK: - Visual layout

    private var displayLayout: some View {
        GeometryReader { geo in
            let scale  = layoutScale(in: geo.size)
            let offset = layoutOffset(in: geo.size, scale: scale)
            // Maximum Y in CG coordinates — used to flip from CG (Y up) → SwiftUI (Y down).
            let maxCGY = displays.map(\.bounds.maxY).max() ?? 0

            ZStack(alignment: .topLeading) {
                ForEach(Array(displays.enumerated()), id: \.offset) { index, info in
                    let rect = swiftUIRect(for: info, maxCGY: maxCGY, scale: scale, offset: offset)
                    let selected = settings.targetDisplayIndex == index + 1

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(
                                    selected ? Color.accentColor : Color.secondary.opacity(0.45),
                                    lineWidth: selected ? 2 : 1
                                )
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .overlay(
                            VStack(spacing: 2) {
                                Text(info.name)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Text(info.resolution)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .padding(4)
                            .frame(width: rect.width, height: rect.height)
                        )
                        .clipped()
                        .onTapGesture { settings.targetDisplayIndex = index + 1 }
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
        let minX     = displays.map(\.bounds.minX).min()!
        let minY     = displays.map(\.bounds.minY).min()!
        let maxY     = displays.map(\.bounds.maxY).max()!
        let scaledW  = (displays.map(\.bounds.maxX).max()! - minX) * scale
        let scaledH  = (maxY - minY) * scale
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
    var bounds:     CGRect   // in CGDisplayBounds / Quartz coordinates
    var name:       String   // localised device name if available
    var resolution: String   // e.g. "2560×1440"

    /// Label shown in the radio-button picker.
    var pickerLabel: String { "\(name) (\(resolution))" }

    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        // Map CGDirectDisplayID → NSScreen.localizedName (macOS 10.15+).
        var nameMap: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID {
                nameMap[num] = screen.localizedName
            }
        }

        return ids.enumerated().map { index, id in
            let name = nameMap[id] ?? "Display \(index + 1)"
            let w    = Int(CGDisplayPixelsWide(id))
            let h    = Int(CGDisplayPixelsHigh(id))
            return DisplayInfo(id: id, bounds: CGDisplayBounds(id),
                               name: name, resolution: "\(w)×\(h)")
        }
    }
}
