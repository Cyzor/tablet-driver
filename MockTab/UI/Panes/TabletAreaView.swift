import SwiftUI

/// Interactive tablet active-area editor.
/// Shows the full digitizer surface with a crop-tool-style draggable
/// active area rectangle — resizable from all four edges and corners,
/// repositionable by dragging the interior.
struct TabletAreaView: View {
    @ObservedObject var settings: TabletSettings

    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry

    /// Called when the user selects a different tablet from the picker.
    var onDeviceSelected: ((Int) -> Void)?

    /// The product ID this view is currently showing.
    var boundProductID: Int?

    // MARK: - Digitizer dimensions

    /// Digitizer width for the currently-shown device, in hardware line-units.
    private var activeDeviceMaxX: Int {
        if let pid = boundProductID {
            if let s = tabletManager.contexts[pid]?.tabletDevice?.spec { return s.maxX }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.maxX }
        }
        return 44800
    }

    /// Digitizer height for the currently-shown device, in hardware line-units.
    private var activeDeviceMaxY: Int {
        if let pid = boundProductID {
            if let s = tabletManager.contexts[pid]?.tabletDevice?.spec { return s.maxY }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.maxY }
        }
        return 29600
    }

    /// True if the connected device is a pen display (Cintiq-class).
    private var activeDeviceIsPenDisplay: Bool {
        if let pid = boundProductID {
            if let s = tabletManager.contexts[pid]?.tabletDevice?.spec { return s.isPenDisplay }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.isPenDisplay }
        }
        return false
    }

    private var activeAspectRatio: Double {
        let y = activeDeviceMaxY
        guard y > 0 else { return 44800.0 / 29600.0 }
        return Double(activeDeviceMaxX) / Double(y)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppOverrideBar(settings: settings, domainKeys: AppOverrideBar.areaKeys, productID: boundProductID)
            Form {
                Section {
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
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

                    coordinateReadout
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

                    HStack {

                        Toggle(LocalizedStringKey("Proportional mapping"), isOn: proportionalMappingBinding)
                            .toggleStyle(.checkbox)
                            .help(LocalizedStringKey("Lock the tablet-to-screen mapping ratio to match your display's proportions, so the cursor never feels stretched or compressed."))
                        
                        Spacer()
                        
                        Button(LocalizedStringKey("Reset to Full Area")) {
                            let snap = TabletSettings.AreaSnapshot(
                                x: settings.activeAreaX, y: settings.activeAreaY,
                                w: settings.activeAreaWidth, h: settings.activeAreaHeight)
                            settings.activeAreaX = 0; settings.activeAreaY = 0
                            settings.activeAreaWidth = 1; settings.activeAreaHeight = 1
                            settings.recordAreaDrag(before: snap)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(LocalizedStringKey("Reset the active area to the full tablet surface (undoable)."))

                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                } header: {
                    sectionHeading
                }

                if activeDeviceIsPenDisplay {
                    Section(LocalizedStringKey("Pen Display Calibration")) {
                        // Calibration status + actions
                        HStack {
                            if let cal = activeCalibration {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedStringKey("Calibrated"))
                                        .font(.body)
                                    Text(cal.calibratedAt, format: .dateTime.month(.abbreviated).day().year())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(LocalizedStringKey("Not calibrated"))
                            }
                            Spacer()
                            Button(LocalizedStringKey("Calibrate…")) {
                                startCalibration()
                            }
                            .buttonStyle(.bordered)
                            .disabled(settings.targetDisplayIndex == TabletSettings.displayModeAll)
                            .help(LocalizedStringKey("Open the calibration overlay to tap crosshair targets on your pen display."))
                            if activeCalibration != nil {
                                Button(LocalizedStringKey("Reset")) {
                                    resetCalibration()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        // Manual fine-tune offset
                        DisclosureGroup(LocalizedStringKey("Manual Fine-Tune")) {
                            HStack(spacing: 16) {
                                HStack(spacing: 4) {
                                    Text(LocalizedStringKey("Horizontal:"))
                                        .foregroundStyle(.secondary)
                                    TextField("", value: parallaxXBinding,
                                              format: .number.precision(.fractionLength(1)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .multilineTextAlignment(.trailing)
                                    Text("pt").foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Text(LocalizedStringKey("Vertical:"))
                                        .foregroundStyle(.secondary)
                                    TextField("", value: parallaxYBinding,
                                              format: .number.precision(.fractionLength(1)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .multilineTextAlignment(.trailing)
                                    Text("pt").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(LocalizedStringKey("Reset Offset")) {
                                    let oldX = settings.parallaxOffsetX
                                    let oldY = settings.parallaxOffsetY
                                    settings.parallaxOffsetX = 0
                                    settings.parallaxOffsetY = 0
                                    settings.record("Reset Offset") {
                                        settings.parallaxOffsetX = oldX
                                        settings.parallaxOffsetY = oldY
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(settings.parallaxOffsetX == 0 && settings.parallaxOffsetY == 0)
                            }
                        }
                        .help(LocalizedStringKey("Apply a small constant offset on top of calibration for sub-pixel fine-tuning."))
                    }
                }

                Section(LocalizedStringKey("Orientation")) {
                    OrientationPickerView(settings: settings)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: registry, productID: boundProductID ?? 0)
        }
    }

    // MARK: - Device identity

    private struct DeviceLabel {
        let primary: String
        let secondary: String?
    }

    private var deviceLabel: DeviceLabel {
        guard let pid = boundProductID else {
            if let activePID = tabletManager.activeContext?.productID {
                return DeviceLabel(primary: TabletManager.deviceName(forProductID: activePID), secondary: nil)
            }
            return DeviceLabel(primary: String(localized: "No device", comment: "Fallback label when no tablet is connected"), secondary: nil)
        }
        let modelName = TabletManager.deviceName(forProductID: pid)
        if let tablet = registry.knownTablets.first(where: { $0.id == pid }),
           tablet.nickname != tablet.modelName {
            return DeviceLabel(primary: tablet.nickname, secondary: modelName)
        }
        return DeviceLabel(primary: modelName, secondary: nil)
    }

    // MARK: - Section heading

    private var sectionHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey("Active Surface Area")).font(.headline)
            DeviceNameLabel(tabletManager: tabletManager, registry: registry)
        }
    }

    // MARK: - Calibration

    /// The active calibration entry for the current orientation and display, if any.
    private var activeCalibration: CalibrationEntry? {
        let displayID = resolveCurrentDisplayID()
        return settings.calibration(for: settings.tabletOrientation, displayID: displayID)
    }

    /// Resolve the CGDirectDisplayID for the current target display setting.
    private func resolveCurrentDisplayID() -> UInt32 {
        let idx = settings.targetDisplayIndex
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGMainDisplayID()
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CGMainDisplayID()
        }
        if idx == TabletSettings.displayModeAll { return 0 }
        if idx > 0, idx <= ids.count { return ids[idx - 1] }
        return CGMainDisplayID()
    }

    @State private var calibrationWindow: CalibrationOverlayWindow?

    /// Launch the calibration overlay on the target display.
    private func startCalibration() {
        let displayID = resolveCurrentDisplayID()
        guard displayID != 0 else { return }  // can't calibrate "All Displays"
        let bounds = CGDisplayBounds(displayID)

        let session = CalibrationSession(
            settings: settings,
            tabletManager: tabletManager,
            displayID: displayID,
            displayBounds: bounds,
            orientation: settings.tabletOrientation)

        let window = CalibrationOverlayWindow(session: session)
        calibrationWindow = window
        window.beginCalibration()
    }

    /// Clear calibration data for the current orientation and display.
    private func resetCalibration() {
        let displayID = resolveCurrentDisplayID()
        let key = CalibrationKey(orientation: settings.tabletOrientation.rawValue, displayID: displayID)
        let oldJSON = settings.calibrationJSON
        var entries = settings.calibrationEntries
        entries.removeAll { $0.key == key }
        settings.calibrationEntries = entries
        settings.record("Reset Calibration") {
            settings.calibrationJSON = oldJSON
        }
        tabletManager.activeContext?.injector.invalidateCalibrationCache()
    }

    /// Binding that clamps and registers undo for horizontal parallax offset.
    private var parallaxXBinding: Binding<Double> {
        Binding(
            get: { settings.parallaxOffsetX },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, -20), 20)
                let oldValue = settings.parallaxOffsetX
                settings.parallaxOffsetX = clamped
                settings.record("Parallax Offset") {
                    settings.parallaxOffsetX = oldValue
                }
            }
        )
    }

    /// Binding that clamps and registers undo for vertical parallax offset.
    private var parallaxYBinding: Binding<Double> {
        Binding(
            get: { settings.parallaxOffsetY },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, -20), 20)
                let oldValue = settings.parallaxOffsetY
                settings.parallaxOffsetY = clamped
                settings.record("Parallax Offset") {
                    settings.parallaxOffsetY = oldValue
                }
            }
        )
    }

    /// Binding that registers undo when proportional mapping is toggled.
    private var proportionalMappingBinding: Binding<Bool> {
        Binding(
            get: { settings.proportionalMapping },
            set: { newValue in
                let oldValue = settings.proportionalMapping
                settings.proportionalMapping = newValue
                settings.record("Proportional Mapping") {
                    settings.proportionalMapping = oldValue
                }
            }
        )
    }

    // MARK: - Coordinate readout

    private var coordinateReadout: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
//            GridRow {
//                Text("Offset X").foregroundStyle(.secondary)
//                    .frame(width: 60, alignment: .trailing)
//                percentField($settings.activeAreaX)
//                Text("Offset Y").foregroundStyle(.secondary)
//                    .frame(width: 60, alignment: .trailing)
//                percentField($settings.activeAreaY)
//            }
            GridRow {
                Text(LocalizedStringKey("Width")).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                pixelField(fraction: $settings.activeAreaWidth,
                           maxValue: activeDeviceMaxX,
                           minFraction: Self.minFraction,
                           maxFraction: 1 - settings.activeAreaX)
                Text(LocalizedStringKey("Height")).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                pixelField(fraction: $settings.activeAreaHeight,
                           maxValue: activeDeviceMaxY,
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
            get: {
                guard maxValue > 0 else { return 0 }
                let value = fraction.wrappedValue * Double(maxValue)
                guard !value.isNaN && !value.isInfinite else { return 0 }
                return Int(round(value))
            },
            set: { newPx in
                guard maxValue > 0 else { return }
                let f = Double(newPx) / Double(maxValue)
                guard !f.isNaN && !f.isInfinite else { return }
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
    /// Draft crop values during a drag; nil when not dragging.
    /// Used to defer updates to settings until the drag completes.
    @State private var draftArea: DragOrigin? = nil

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
        // Use draft values if dragging, otherwise settings
        let activeX = draftArea?.x ?? settings.activeAreaX
        let activeY = draftArea?.y ?? settings.activeAreaY
        let activeW = draftArea?.w ?? settings.activeAreaWidth
        let activeH = draftArea?.h ?? settings.activeAreaHeight

        let x = activeX * cs.width
        let y = activeY * cs.height
        let w = activeW * cs.width
        let h = activeH * cs.height
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
                    // First event — snapshot current state, initialize draft, and record start location.
                    dragOrigin = DragOrigin(
                        x: settings.activeAreaX, y: settings.activeAreaY,
                        w: settings.activeAreaWidth, h: settings.activeAreaHeight)
                    draftArea = dragOrigin  // Initialize draft from current state
                    dragAnchor = v.startLocation
                }
                guard let anchor = dragAnchor else { return }
                let dx = (v.location.x - anchor.x) / cs.width
                let dy = (v.location.y - anchor.y) / cs.height
                applyDrag(edge: edge, dx: dx, dy: dy)
            }
            .onEnded { _ in
                // Commit draft to settings and register one coalesced undo entry
                if dragAnchor != nil, let draft = draftArea {
                    settings.activeAreaX = draft.x
                    settings.activeAreaY = draft.y
                    settings.activeAreaWidth = draft.w
                    settings.activeAreaHeight = draft.h
                    settings.recordAreaDrag(before: TabletSettings.AreaSnapshot(
                        x: dragOrigin.x, y: dragOrigin.y,
                        w: dragOrigin.w, h: dragOrigin.h))
                }
                dragAnchor = nil
                draftArea = nil
            }
    }

    private func applyDrag(edge: CropEdge, dx: Double, dy: Double) {
        guard var draft = draftArea else { return }
        let o = dragOrigin
        let minD = Self.minFraction

        switch edge {
        case .body:
            // Clamp so the active area never leaves the physical bounds.
            draft.x = Swift.min(Swift.max(o.x + dx, 0), 1 - o.w)
            draft.y = Swift.min(Swift.max(o.y + dy, 0), 1 - o.h)

        case .left:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            draft.x = newX
            draft.w = o.x + o.w - newX

        case .right:
            draft.w = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)

        case .top:
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            draft.y = newY
            draft.h = o.y + o.h - newY

        case .bottom:
            draft.h = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)

        case .topLeft:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            draft.x = newX
            draft.y = newY
            draft.w = o.x + o.w - newX
            draft.h = o.y + o.h - newY

        case .topRight:
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            draft.y = newY
            draft.w = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)
            draft.h = o.y + o.h - newY

        case .bottomLeft:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            draft.x = newX
            draft.w = o.x + o.w - newX
            draft.h = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)

        case .bottomRight:
            draft.w = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)
            draft.h = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)
        }

        draftArea = draft
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
        let label = deviceLabel

        let line1Resolved = ctx.resolve(
            Text(label.primary).font(.badgeTitle).bold().foregroundColor(.white))
        let line2Resolved = label.secondary.map {
            ctx.resolve(Text($0).font(.badgeSubtitle).foregroundColor(.white))
        }

        let hPad: CGFloat = 6
        let vPad: CGFloat = 4
        let gap:  CGFloat = 4
        let maxTextW = areaRect.width - hPad * 2 - 4

        guard maxTextW > 16 else { return }

        let measureBound = CGSize(width: maxTextW, height: 40)
        let s1 = line1Resolved.measure(in: measureBound)
        let s2 = line2Resolved?.measure(in: measureBound) ?? .zero

        // Vanish if area is too narrow; avoids text wrapping/measurement changes
        guard areaRect.width >= 140 else { return }

        let maxTextWidth = max(s1.width, s2.width)
        let twoLines = line2Resolved != nil
        let textH    = twoLines ? s1.height + gap + s2.height : s1.height

        let badgeW   = min(maxTextWidth + hPad * 2, areaRect.width - 4)
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

    // MARK: - Helpers

    private func canvasSize(in available: CGSize) -> CGSize {
        let ratio = settings.tabletOrientation.swapsAxes
            ? 1.0 / activeAspectRatio
            : activeAspectRatio
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
