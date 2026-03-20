import SwiftUI
import CoreGraphics

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
                    Text(info.label).tag(index + 1)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: settings.targetDisplayIndex) { _ in }

            // Visual display layout
            displayLayout
        }
        .padding()
        .onAppear { displays = DisplayInfo.all() }
    }

    private var displayLayout: some View {
        GeometryReader { geo in
            let scale = layoutScale(displays: displays, in: geo.size)
            let offset = layoutOffset(displays: displays, in: geo.size, scale: scale)
            ZStack(alignment: .topLeading) {
                ForEach(Array(displays.enumerated()), id: \.offset) { index, info in
                    let rect = info.bounds.applying(.init(scaleX: scale, y: scale))
                        .offsetBy(dx: offset.x, dy: offset.y)
                    Rectangle()
                        .fill(settings.targetDisplayIndex == index + 1
                              ? Color.accentColor.opacity(0.2)
                              : Color.secondary.opacity(0.1))
                        .overlay(Rectangle().strokeBorder(
                            settings.targetDisplayIndex == index + 1
                                ? Color.accentColor : Color.secondary.opacity(0.5),
                            lineWidth: 1.5))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .onTapGesture { settings.targetDisplayIndex = index + 1 }
                        .overlay(
                            Text(info.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        )
                }
            }
        }
        .frame(height: 100)
    }

    private func layoutScale(displays: [DisplayInfo], in size: CGSize) -> CGFloat {
        guard !displays.isEmpty else { return 1 }
        let unionWidth = displays.map(\.bounds.maxX).max()! - displays.map(\.bounds.minX).min()!
        let unionHeight = displays.map(\.bounds.maxY).max()! - displays.map(\.bounds.minY).min()!
        return min(size.width / unionWidth, size.height / unionHeight) * 0.9
    }

    private func layoutOffset(displays: [DisplayInfo], in size: CGSize, scale: CGFloat) -> CGPoint {
        guard !displays.isEmpty else { return .zero }
        let minX = displays.map(\.bounds.minX).min()!
        let minY = displays.map(\.bounds.minY).min()!
        let scaledW = (displays.map(\.bounds.maxX).max()! - minX) * scale
        let scaledH = (displays.map(\.bounds.maxY).max()! - minY) * scale
        return CGPoint(
            x: (size.width - scaledW) / 2 - minX * scale,
            y: (size.height - scaledH) / 2 - minY * scale
        )
    }
}

struct DisplayInfo {
    var id: CGDirectDisplayID
    var bounds: CGRect
    var label: String

    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.enumerated().map { index, id in
            DisplayInfo(
                id: id,
                bounds: CGDisplayBounds(id),
                label: "Display \(index + 1) (\(Int(CGDisplayPixelsWide(id)))×\(Int(CGDisplayPixelsHigh(id))))"
            )
        }
    }
}
