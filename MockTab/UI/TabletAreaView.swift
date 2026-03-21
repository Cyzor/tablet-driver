import SwiftUI

/// Interactive tablet active-area editor.
/// Shows the full digitizer surface and a draggable active area rectangle.
struct TabletAreaView: View {
    @ObservedObject var settings: TabletSettings

    // Aspect ratios for supported tablets.
    // Auto-selected on connection; user can override via the picker.
    enum TabletModel: String, CaseIterable, Identifiable {
        case pth851  = "Intuos 5 Large (PTH-851)"
        case pth660  = "Intuos Pro M (PTH-660)"
        case pth860  = "Intuos Pro Large (PTH-860)"
        case ptz631w = "Intuos3 Widescreen (PTZ-631W)"
        var id: String { rawValue }
        var aspectRatio: Double {
            switch self {
            case .pth851:  return 44704.0 / 27940.0
            case .pth660:  return 44800.0 / 29600.0
            case .pth860:  return 62200.0 / 43200.0
            case .ptz631w: return 54204.0 / 31750.0
            }
        }
        init?(productID: Int) {
            switch productID {
            case 0x0317: self = .pth851
            case 0x0357: self = .pth660
            case 0x0358: self = .pth860
            case 0x00B5: self = .ptz631w
            default: return nil
            }
        }
        /// Display label for any product ID — falls back to hex for unknowns.
        static func displayName(forProductID pid: Int) -> String {
            TabletModel(productID: pid).map(\.rawValue)
                ?? "Unknown (0x\(String(pid, radix: 16, uppercase: true)))"
        }
    }

    @ObservedObject var tabletManager: TabletManager
    @AppStorage("selectedTabletModel") private var selectedModelRaw = TabletModel.pth860.rawValue
    private var selectedModel: TabletModel { TabletModel(rawValue: selectedModelRaw) ?? .pth860 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Tablet model", selection: $selectedModelRaw) {
                    ForEach(TabletModel.allCases) { model in
                        Text(model.rawValue).tag(model.rawValue)
                    }
                }
                .pickerStyle(.menu)

                // Pins the picker to whichever tablet is currently connected.
                // When multiple tablets are present, uses the most recently connected one.
                Button("Detect Connected") {
                    autoSelectModel(tabletManager.connectedProductID)
                }
                .fixedSize()
                .disabled(!tabletManager.isConnected)
            }

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

            HStack {
                Button("Reset to full area") {
                    settings.activeAreaX = 0; settings.activeAreaY = 0
                    settings.activeAreaWidth = 1; settings.activeAreaHeight = 1
                }
                .buttonStyle(.borderless)

                Spacer()

                Toggle("Proportional mapping", isOn: $settings.proportionalMapping)
                    .toggleStyle(.checkbox)
            }
        }
        .padding()
        .onAppear { autoSelectModel(tabletManager.connectedProductID) }
        .onChange(of: tabletManager.connectedProductID) { autoSelectModel($0) }
    }

    private func autoSelectModel(_ productID: Int) {
        if let model = TabletModel(productID: productID) {
            selectedModelRaw = model.rawValue
        }
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

