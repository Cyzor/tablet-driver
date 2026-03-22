import SwiftUI

/// Interactive tablet active-area editor.
/// Shows the full digitizer surface with a crop-tool-style draggable
/// active area rectangle — resizable from all four edges and corners,
/// repositionable by dragging the interior.
struct TabletAreaView: View {
    @ObservedObject var settings: TabletSettings

    // Aspect ratios and digitizer resolutions for supported tablets.
    enum TabletModel: String, CaseIterable, Identifiable {
        case pth851  = "Intuos 5 Large (PTH-851)"
        case pth660  = "Intuos Pro M (PTH-660)"
        case pth860  = "Intuos Pro Large (PTH-860)"
        case ptz631w = "Intuos3 Widescreen (PTZ-631W)"
        case dtk2400 = "Cintiq 24HD (DTK-2400)"
        var id: String { rawValue }

        /// Digitizer resolution in hardware line-units.
        var maxX: Int {
            switch self {
            case .pth851:  return 44704
            case .pth660:  return 44800
            case .pth860:  return 62200
            case .ptz631w: return 54204
            case .dtk2400: return 104480
            }
        }
        var maxY: Int {
            switch self {
            case .pth851:  return 27940
            case .pth660:  return 29600
            case .pth860:  return 43200
            case .ptz631w: return 31750
            case .dtk2400: return 65600
            }
        }

        var aspectRatio: Double { Double(maxX) / Double(maxY) }

        var productID: Int {
            switch self {
            case .pth851:  return 0x0317
            case .pth660:  return 0x0357
            case .pth860:  return 0x0358
            case .ptz631w: return 0x00B5
            case .dtk2400: return 0x00F4
            }
        }
        init?(productID: Int) {
            switch productID {
            case 0x0317: self = .pth851
            case 0x0357: self = .pth660
            case 0x0358: self = .pth860
            case 0x00B5: self = .ptz631w
            case 0x00F4: self = .dtk2400
            default: return nil
            }
        }
        static func displayName(forProductID pid: Int) -> String {
            TabletModel(productID: pid).map(\.rawValue)
                ?? "Unknown (0x\(String(pid, radix: 16, uppercase: true)))"
        }
    }

    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry

    /// Called when the user selects a different tablet model from the picker.
    var onDeviceSelected: ((Int) -> Void)?

    /// The product ID this view is currently showing.
    var boundProductID: Int?

    private var selectedModel: TabletModel {
        if let pid = boundProductID, let m = TabletModel(productID: pid) { return m }
        return .pth860
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            Spacer(minLength: 0)
            PresetStatusBar(settings: settings)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Tablet model", selection: pickerBinding) {
                    ForEach(TabletModel.allCases) { model in
                        Text(model.rawValue).tag(model.productID)
                    }
                }
                .pickerStyle(.menu)

                Button("Detect Tablet") {
                    AppMenuController.activateBestDevice()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            GeometryReader { geo in
                let cs = canvasSize(in: geo.size)
                ZStack(alignment: .topLeading) {
                    // Full digitizer outline
                    Rectangle()
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                        .frame(width: cs.width, height: cs.height)

                    // Active area crop rectangle
                    activeAreaCrop(canvasSize: cs)
                }
                .frame(width: cs.width, height: cs.height)
                .coordinateSpace(name: "cropCanvas")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 200)

            // Coordinate readout with editable fields
            coordinateReadout

            HStack {
                Button("Reset to Full Area") {
                    settings.activeAreaX = 0; settings.activeAreaY = 0
                    settings.activeAreaWidth = 1; settings.activeAreaHeight = 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Toggle("Proportional mapping", isOn: $settings.proportionalMapping)
                    .toggleStyle(.checkbox)
            }
        }
        .padding()
    }

    /// Binding that fires `onDeviceSelected` when the user picks a different model.
    private var pickerBinding: Binding<Int> {
        Binding(
            get: { boundProductID ?? selectedModel.productID },
            set: { newPID in
                if newPID != boundProductID {
                    onDeviceSelected?(newPID)
                }
            }
        )
    }

    // MARK: - Coordinate readout

    private var coordinateReadout: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Offset X").foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                percentField($settings.activeAreaX)
                Text("Offset Y").foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                percentField($settings.activeAreaY)
            }
            GridRow {
                Text("Width").foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                pixelField(fraction: $settings.activeAreaWidth,
                           maxValue: selectedModel.maxX,
                           minFraction: Self.minFraction,
                           maxFraction: 1 - settings.activeAreaX)
                Text("Height").foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                pixelField(fraction: $settings.activeAreaHeight,
                           maxValue: selectedModel.maxY,
                           minFraction: Self.minFraction,
                           maxFraction: 1 - settings.activeAreaY)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// An editable text field showing a 0–100 % value.
    private func percentField(_ binding: Binding<Double>) -> some View {
        TextField("", value: binding, format: .percent.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
    }

    /// An editable text field showing a pixel value derived from a fraction.
    private func pixelField(fraction: Binding<Double>, maxValue: Int,
                            minFraction: Double, maxFraction: Double) -> some View {
        let pixelBinding = Binding<Int>(
            get: { Int(round(fraction.wrappedValue * Double(maxValue))) },
            set: { newPx in
                let f = Double(newPx) / Double(maxValue)
                fraction.wrappedValue = Swift.min(Swift.max(f, minFraction), maxFraction)
            }
        )
        return TextField("", value: pixelBinding, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
    }

    // MARK: - Crop rectangle

    /// Drag-origin snapshot so deltas are computed from a stable reference.
    @State private var dragOrigin = DragOrigin()

    private struct DragOrigin {
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
    }

    /// Which edge / corner / body is being dragged.
    private enum CropEdge {
        case body
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private static let handleSize: CGFloat = 8
    private static let edgeThickness: CGFloat = 6
    private static let minFraction: Double = 0.05   // 5% minimum dimension

    private func activeAreaCrop(canvasSize cs: CGSize) -> some View {
        let x = settings.activeAreaX * cs.width
        let y = settings.activeAreaY * cs.height
        let w = settings.activeAreaWidth * cs.width
        let h = settings.activeAreaHeight * cs.height
        let rect = CGRect(x: x, y: y, width: w, height: h)

        return ZStack(alignment: .topLeading) {
            // Dimmed exterior — darkens everything outside the active area
            // so the crop region pops visually, like Photoshop's crop overlay.
            Canvas { ctx, size in
                var outer = Path(CGRect(origin: .zero, size: size))
                outer.addRect(rect)
                ctx.fill(outer, with: .color(.black.opacity(0.10)),
                         style: FillStyle(eoFill: true))
            }
            .frame(width: cs.width, height: cs.height)
            .allowsHitTesting(false)

            // Fill — drag to reposition
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: w, height: h)
                .offset(x: x, y: y)
                .gesture(cropGesture(.body, cs: cs))
                .cursor(.openHand)

            // Border
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: w, height: h)
                .offset(x: x, y: y)
                .allowsHitTesting(false)

            // Badge
            Canvas { ctx, _ in
                tabletBadge(ctx: ctx, areaRect: rect)
            }
            .frame(width: cs.width, height: cs.height)
            .allowsHitTesting(false)

            // Edge handles (invisible hit areas)
            edgeHandle(.top,    rect: rect, cs: cs)
            edgeHandle(.bottom, rect: rect, cs: cs)
            edgeHandle(.left,   rect: rect, cs: cs)
            edgeHandle(.right,  rect: rect, cs: cs)

            // Corner handles (visible dots)
            cornerHandle(.topLeft,     rect: rect, cs: cs)
            cornerHandle(.topRight,    rect: rect, cs: cs)
            cornerHandle(.bottomLeft,  rect: rect, cs: cs)
            cornerHandle(.bottomRight, rect: rect, cs: cs)
        }
    }

    // MARK: - Handle views

    private func edgeHandle(_ edge: CropEdge, rect: CGRect, cs: CGSize) -> some View {
        let t = Self.edgeThickness
        let hs = Self.handleSize
        let frame: (CGFloat, CGFloat)
        let offset: (CGFloat, CGFloat)

        switch edge {
        case .top:
            frame  = (rect.width - hs * 2, t)
            offset = (rect.minX + hs, rect.minY - t / 2)
        case .bottom:
            frame  = (rect.width - hs * 2, t)
            offset = (rect.minX + hs, rect.maxY - t / 2)
        case .left:
            frame  = (t, rect.height - hs * 2)
            offset = (rect.minX - t / 2, rect.minY + hs)
        case .right:
            frame  = (t, rect.height - hs * 2)
            offset = (rect.maxX - t / 2, rect.minY + hs)
        default: frame = (0, 0); offset = (0, 0)
        }

        return Color.clear
            .frame(width: frame.0, height: frame.1)
            .contentShape(Rectangle())
            .offset(x: offset.0, y: offset.1)
            .gesture(cropGesture(edge, cs: cs))
            .cursor(edgeCursor(edge))
    }

    private func cornerHandle(_ corner: CropEdge, rect: CGRect, cs: CGSize) -> some View {
        let s = Self.handleSize
        let pos: (CGFloat, CGFloat)
        switch corner {
        case .topLeft:     pos = (rect.minX, rect.minY)
        case .topRight:    pos = (rect.maxX, rect.minY)
        case .bottomLeft:  pos = (rect.minX, rect.maxY)
        case .bottomRight: pos = (rect.maxX, rect.maxY)
        default:           pos = (0, 0)
        }

        return Circle()
            .fill(Color.accentColor)
            .frame(width: s, height: s)
            .offset(x: pos.0 - s / 2, y: pos.1 - s / 2)
            .gesture(cropGesture(corner, cs: cs))
            .cursor(cornerCursor(corner))
    }

    // MARK: - Drag gesture

    /// Tracks the canvas-local start location so we can compute stable deltas
    /// from the drag origin snapshot.  Using `v.location` (absolute cursor
    /// position in the view) minus the start-of-drag anchor eliminates
    /// accumulated error from noisy pen input — every frame is an independent
    /// calculation from the snapshot, not a chain of incremental translations.
    @State private var dragAnchor: CGPoint?

    private func cropGesture(_ edge: CropEdge, cs: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("cropCanvas"))
            .onChanged { v in
                if dragAnchor == nil {
                    // First event — snapshot current state and record start location.
                    dragOrigin = DragOrigin(
                        x: settings.activeAreaX, y: settings.activeAreaY,
                        w: settings.activeAreaWidth, h: settings.activeAreaHeight)
                    dragAnchor = v.startLocation
                }
                guard let anchor = dragAnchor else { return }
                let dx = (v.location.x - anchor.x) / cs.width
                let dy = (v.location.y - anchor.y) / cs.height
                applyDrag(edge: edge, dx: dx, dy: dy)
            }
            .onEnded { _ in
                dragAnchor = nil
            }
    }

    private func applyDrag(edge: CropEdge, dx: Double, dy: Double) {
        let o = dragOrigin
        let minD = Self.minFraction

        switch edge {
        case .body:
            // Clamp so the active area never leaves the physical bounds.
            settings.activeAreaX = Swift.min(Swift.max(o.x + dx, 0), 1 - o.w)
            settings.activeAreaY = Swift.min(Swift.max(o.y + dy, 0), 1 - o.h)

        case .left:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            settings.activeAreaX = newX
            settings.activeAreaWidth = o.x + o.w - newX

        case .right:
            settings.activeAreaWidth = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)

        case .top:
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            settings.activeAreaY = newY
            settings.activeAreaHeight = o.y + o.h - newY

        case .bottom:
            settings.activeAreaHeight = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)

        case .topLeft:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            settings.activeAreaX = newX
            settings.activeAreaY = newY
            settings.activeAreaWidth  = o.x + o.w - newX
            settings.activeAreaHeight = o.y + o.h - newY

        case .topRight:
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            settings.activeAreaY = newY
            settings.activeAreaWidth  = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)
            settings.activeAreaHeight = o.y + o.h - newY

        case .bottomLeft:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            settings.activeAreaX = newX
            settings.activeAreaWidth  = o.x + o.w - newX
            settings.activeAreaHeight = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)

        case .bottomRight:
            settings.activeAreaWidth  = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)
            settings.activeAreaHeight = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)
        }
    }

    // MARK: - Cursors

    private func edgeCursor(_ edge: CropEdge) -> NSCursor {
        switch edge {
        case .top, .bottom:  return .resizeUpDown
        case .left, .right:  return .resizeLeftRight
        default:             return .arrow
        }
    }

    private func cornerCursor(_ corner: CropEdge) -> NSCursor {
        switch corner {
        case .topLeft, .bottomRight: return .crosshair
        case .topRight, .bottomLeft: return .crosshair
        default:                     return .arrow
        }
    }

    // MARK: - Badge

    /// Draws a dark translucent badge with the tablet nickname and model name
    /// centred inside `areaRect`, matching the display-pane caption style.
    private func tabletBadge(ctx: GraphicsContext, areaRect: CGRect) {
        let (line1, line2) = badgeLines()

        let line1Resolved = ctx.resolve(
            Text(line1).font(.caption2).bold().foregroundColor(.white))
        let line2Resolved = line2.map {
            ctx.resolve(Text($0).font(.caption2).foregroundColor(.white))
        }

        let hPad: CGFloat = 6
        let vPad: CGFloat = 4
        let gap:  CGFloat = 4
        let maxTextW = areaRect.width - hPad * 2 - 4

        guard maxTextW > 16 else { return }

        let measureBound = CGSize(width: maxTextW, height: 40)
        let s1 = line1Resolved.measure(in: measureBound)
        let s2 = line2Resolved?.measure(in: measureBound) ?? .zero

        let twoLines = line2Resolved != nil
        let textH    = twoLines ? s1.height + gap + s2.height : s1.height
        let badgeW   = min(max(s1.width, s2.width) + hPad * 2, areaRect.width - 4)
        let badgeH   = textH + vPad * 2
        let badgeX   = areaRect.midX - badgeW / 2
        let badgeY   = areaRect.midY - badgeH / 2

        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        let badgePath = Path(roundedRect: badgeRect, cornerRadius: 3, style: .continuous)
        let clipPath  = Path(areaRect.insetBy(dx: 2, dy: 2))

        ctx.drawLayer { layer in
            layer.clip(to: clipPath)
            layer.fill(badgePath, with: .color(.black.opacity(0.42)))

            if twoLines, let r2 = line2Resolved {
                let y1 = areaRect.midY - (gap / 2 + s1.height / 2)
                let y2 = areaRect.midY + (gap / 2 + s2.height / 2)
                layer.draw(line1Resolved, at: CGPoint(x: areaRect.midX, y: y1), anchor: .center)
                layer.draw(r2,            at: CGPoint(x: areaRect.midX, y: y2), anchor: .center)
            } else {
                layer.draw(line1Resolved, at: CGPoint(x: areaRect.midX, y: areaRect.midY),
                           anchor: .center)
            }
        }
    }

    private func badgeLines() -> (String, String?) {
        guard let pid = boundProductID else {
            return (selectedModel.rawValue, nil)
        }
        let modelName = TabletModel.displayName(forProductID: pid)
        if let tablet = registry.knownTablets.first(where: { $0.id == pid }),
           tablet.nickname != tablet.modelName {
            return (tablet.nickname, modelName)
        }
        return (modelName, nil)
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
}

// MARK: - Cursor modifier

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
