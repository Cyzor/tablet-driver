import SwiftUI

/// Interactive tablet active-area editor.
/// Shows the full digitizer surface and a draggable active area rectangle.
struct TabletAreaView: View {
    @ObservedObject var settings: TabletSettings

    // Aspect ratios for the two supported tablets.
    // User can select which model is connected.
    enum TabletModel: String, CaseIterable, Identifiable {
        case pth851 = "Intuos 5 Large (PTH-851)"
        case pth860 = "Intuos Pro Large (PTH-860)"
        var id: String { rawValue }
        var aspectRatio: Double {
            switch self {
            case .pth851: return 44704.0 / 27940.0
            case .pth860: return 62200.0 / 43200.0
            }
        }
    }

    @AppStorage("selectedTabletModel") private var selectedModelRaw = TabletModel.pth860.rawValue
    private var selectedModel: TabletModel { TabletModel(rawValue: selectedModelRaw) ?? .pth860 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tablet model", selection: $selectedModelRaw) {
                ForEach(TabletModel.allCases) { model in
                    Text(model.rawValue).tag(model.rawValue)
                }
            }
            .pickerStyle(.menu)

            GeometryReader { geo in
                let canvasSize = canvasSize(in: geo.size)
                ZStack(alignment: .topLeading) {
                    // Full digitizer outline
                    Rectangle()
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                        .frame(width: canvasSize.width, height: canvasSize.height)

                    // Active area
                    activeAreaRect(canvasSize: canvasSize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 200)

            // Numeric inputs
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Offset X").frame(width: 80, alignment: .leading)
                    percentSlider($settings.activeAreaX, label: "")
                    Text("Y")
                    percentSlider($settings.activeAreaY, label: "")
                }
                GridRow {
                    Text("Width").frame(width: 80, alignment: .leading)
                    percentSlider(Binding(
                        get: { settings.activeAreaWidth },
                        set: { settings.activeAreaWidth = min($0, 1 - settings.activeAreaX) }
                    ), label: "")
                    Text("Height")
                    percentSlider(Binding(
                        get: { settings.activeAreaHeight },
                        set: { settings.activeAreaHeight = min($0, 1 - settings.activeAreaY) }
                    ), label: "")
                }
            }

            Button("Reset to full area") {
                settings.activeAreaX = 0; settings.activeAreaY = 0
                settings.activeAreaWidth = 1; settings.activeAreaHeight = 1
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }

    // MARK: - Active area drag rectangle

    @GestureState private var dragOffset: CGSize = .zero
    @State private var dragging: DragHandle? = nil

    enum DragHandle { case body, topLeft, bottomRight }

    private func activeAreaRect(canvasSize: CGSize) -> some View {
        let x = settings.activeAreaX * canvasSize.width
        let y = settings.activeAreaY * canvasSize.height
        let w = settings.activeAreaWidth * canvasSize.width
        let h = settings.activeAreaHeight * canvasSize.height

        return ZStack(alignment: .topLeading) {
            // Fill
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: w, height: h)
                .offset(x: x, y: y)
                .gesture(DragGesture()
                    .onChanged { v in
                        let dx = v.translation.width / canvasSize.width
                        let dy = v.translation.height / canvasSize.height
                        settings.activeAreaX = Swift.min(Swift.max(settings.activeAreaX + dx, 0),
                                                                 1 - settings.activeAreaWidth)
                        settings.activeAreaY = Swift.min(Swift.max(settings.activeAreaY + dy, 0),
                                                                 1 - settings.activeAreaHeight)
                    }
                )

            // Stroke
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: w, height: h)
                .offset(x: x, y: y)

            // Bottom-right resize handle
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .offset(x: x + w - 5, y: y + h - 5)
                .gesture(DragGesture()
                    .onChanged { v in
                        let newW = (w + v.translation.width) / canvasSize.width
                        let newH = (h + v.translation.height) / canvasSize.height
                        settings.activeAreaWidth = Swift.min(Swift.max(newW, 0.05), 1)
                        settings.activeAreaHeight = Swift.min(Swift.max(newH, 0.05), 1)
                    }
                )
        }
    }

    // MARK: - Helpers

    private func canvasSize(in available: CGSize) -> CGSize {
        let ratio = selectedModel.aspectRatio
        let maxW = available.width - 8
        let maxH = available.height - 8
        if maxW / ratio <= maxH {
            return CGSize(width: maxW, height: maxW / ratio)
        } else {
            return CGSize(width: maxH * ratio, height: maxH)
        }
    }

    private func percentSlider(_ binding: Binding<Double>, label: String) -> some View {
        Slider(value: binding, in: 0...1)
            .frame(minWidth: 80)
    }
}

