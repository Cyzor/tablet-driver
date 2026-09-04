// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TabletKit

// MARK: - ButtonMappingView

struct ButtonMappingView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isLiveResizing = false
    /// Bumped when the ring diagram's center is clicked, starting recording
    /// in the Center row's binding field — direct manipulation on the diagram.
    @State private var centerRecordToken = 0
    /// Same for the pen diagram's parts: tip, eraser, buttons 1–3.
    @State private var penRecordTokens = [0, 0, 0, 0, 0]

    /// Live button state, zeroed when this window is not key or is live-resizing.
    /// Zeroing during resize stops ~100 Hz tablet events from compounding the
    /// window-geometry invalidations that already occur every resize frame.
    private var liveButtons: LiveButtonState {
        guard controlActiveState == .key, !isLiveResizing else { return LiveButtonState() }
        let context = tabletManager.context(forKey: instanceKey)
            ?? tabletManager.activeContext
        return context?.liveButtons ?? LiveButtonState()
    }

    // Not private: read from the ButtonMappingView extension in
    // ButtonMappingBindings.swift.
    var tool: ToolSettings { settings.activeTool }

    private var spec: WacomDeviceSpec? {
        guard let pid = productID else { return nil }
        // Most devices are in the registry keyed by their own PID.
        // The ACK-40401 wireless dongle's own registry entry is a
        // name-only placeholder (maxX/maxY/buttonCount all 0) — skip it
        // and fall back to the paired tablet's PID reported over the RF
        // link instead of showing an empty Buttons pane.
        if let s = WacomDeviceRegistry.spec(for: pid), s.maxX > 0 { return s }
        if let ctx = tabletManager.context(forKey: instanceKey), ctx.pairedProductID > 0 {
            return WacomDeviceRegistry.spec(for: ctx.pairedProductID)
        }
        // Non-Wacom drivable devices (Xencelabs) aren't in WacomDeviceRegistry
        // at all — synthesize the same spec shape TabletManager attached the
        // live driver with.
        if let ctx = tabletManager.context(forKey: instanceKey) {
            return TabletManager.vendorDeviceSpec(forVendorID: ctx.vendorID, productID: pid)
        }
        return nil
    }

    private var activeToolSpec: WacomToolSpec? {
        guard let ctx = tabletManager.context(forKey: instanceKey) else { return nil }
        return WacomToolCatalog.spec(forToolCode: ctx.activeToolCode)
    }

    private var hasTouchRing: Bool { spec?.hasTouchRing == true }
    private var hasDualRings: Bool { spec?.hasDualRings == true }
    private var hasTouchStrips: Bool { spec?.hasTouchStrips == true }

    /// Whether to draw the split left/right *pad* layout (three toggle buttons
    /// plus five express keys per side, sixteen fixed slots). That shape is a
    /// Cintiq 24HD trait, not a consequence of having two rings: the gen-3
    /// Intuos Pro also sets `hasDualRings` but has a single eight-key column.
    /// Keyed on the family rather than `buttonCount`, since the Cintiq itself
    /// declares `buttonCount: 8` while filling all sixteen slots — the
    /// dual-sided layout has never respected that field for anyone.
    private var hasSplitPadLayout: Bool {
        hasDualRings && spec?.parser == .cintiqV1
    }
    private var bezelButtonCount: Int { spec?.bezelButtonCount ?? 0 }

    // MARK: - Companion peripheral (e.g. Xencelabs Quick Keys puck/dongle)

    /// PID of an aux-only companion peripheral for this tablet (currently
    /// only the Xencelabs Quick Keys puck/dongle). A live connection wins
    /// (`VendorDeviceRegistry.connectedCompanion`); failing that, a
    /// companion seen earlier this session still resolves so its section
    /// stays visible — greyed via `companionIsConnected` — instead of
    /// vanishing while the accessory is detached (disable-vs-hide rule:
    /// disconnection is temporary state, not a capability change).
    private var companionProductID: Int? {
        guard let pid = productID else { return nil }
        if let live = VendorDeviceRegistry.connectedCompanion(
            forProductID: pid, connectedProductIDs: tabletManager.connectedProductIDs)
        {
            return live
        }
        return VendorDeviceRegistry.profile(forProductID: pid)?.companions
            .first { tabletManager.contexts[$0] != nil }
    }

    /// This window's own device, live right now. Distinct from
    /// `companionIsConnected`: when the puck has no pen-bearing partner it
    /// gets its own window and *is* the bound device, so the Quick Keys
    /// Hardware rows gate on this instead.
    private var isSelfConnected: Bool {
        tabletManager.context(forKey: instanceKey)?.isConnected == true
    }

    private var companionIsConnected: Bool {
        companionContext?.isConnected == true
    }

    private var companionContext: DeviceContext? {
        companionProductID.flatMap { tabletManager.contexts[$0] }
    }

    private var companionSpec: WacomDeviceSpec? {
        guard let pid = companionProductID, let ctx = companionContext else { return nil }
        return TabletManager.vendorDeviceSpec(forVendorID: ctx.vendorID, productID: pid)
    }

    /// Live button state for the companion, zeroed under the same
    /// not-key/live-resizing conditions as the tablet's own `liveButtons`.
    private var companionLiveButtons: LiveButtonState {
        guard controlActiveState == .key, !isLiveResizing else { return LiveButtonState() }
        return companionContext?.liveButtons ?? LiveButtonState()
    }

    /// Number of express-key rows to display in the single-sided section.
    /// Driven by the active device spec so PTK-670/870 (8 keys, plus a
    /// separate dial center-press on each ring — not counted here) and DTU
    /// (4 keys) get the right row count instead of a hard-coded 8. Clamped
    /// to the storage limit of `expressKeyBindings` (16) for safety.
    private var expressKeyCount: Int {
        let count = spec?.buttonCount ?? 8
        return min(max(count, 0), 16)
    }

    // MARK: - Body

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey, overrideKeys: AppOverrideBar.buttonKeys,
            onResetToDefaults: resetToDefaults
        ) {
            // Aux-only devices (Quick Keys puck/dongle) have no pen digitizer,
            // so the pen-buttons section is structurally inapplicable — and
            // instead of the generic express-key/ring layout they get the
            // exact same QuickKeysSectionView that quickKeysSection folds into
            // a tablet's window, just fed from this window's own settings and
            // live state. One component, identical look and behavior (LED
            // color wells included) wherever the puck's controls appear.
            if spec?.parser == .xencelabs && spec?.maxX == 0 {
                QuickKeysSectionView(
                    settings: settings, spec: spec, liveButtons: liveButtons,
                    isDeviceConnected: isSelfConnected,
                    nameLabel: DeviceNameLabel(
                        tabletManager: tabletManager, registry: registry, instanceKey: instanceKey))
            } else {
                penButtonsSection(lb: liveButtons)
                if hasSplitPadLayout {
                    dualSidedSection(lb: liveButtons)
                } else {
                    singleSidedSection(lb: liveButtons)
                }
                if bezelButtonCount > 0 {
                    bezelButtonsSection(lb: liveButtons)
                }
            }
        }
        .background(
            LiveResizeDetector(isResizing: $isLiveResizing)
                .allowsHitTesting(false)
        )
        // A companion seen in a *previous* session has a registry row but no
        // context yet, and `companionProductID` resolves through contexts —
        // without this the Quick Keys section vanishes until the puck powers
        // on (or its standalone window happens to create the context). Stub
        // it up front so the section renders (editable, with a "Not
        // connected" header hint) instead of disappearing.
        .onAppear {
            if let pid = productID {
                tabletManager.ensureCompanionStubs(forOwnerProductID: pid)
            }
        }
    }

    // MARK: - Reset to Defaults

    /// Restores every field `AppOverrideBar.buttonKeys` tracks to its shipped
    /// default. Buttons 3–5, the wheel, and bezel buttons are deliberately
    /// left alone — they aren't in `buttonKeys`, so they aren't part of the
    /// per-app-override system either, and touching them here would reset
    /// state this pane's own override scoping doesn't otherwise cover.
    private typealias ButtonToolState = (
        tip: ButtonBinding, eraser: ButtonBinding, pen1: ButtonBinding, pen2: ButtonBinding
    )
    private typealias ButtonSettingsState = (
        expressKeys: [ButtonBinding], touchRingButton: ButtonBinding,
        touchRingSlots: [ControlSlot], touchRingActiveSlot: Int,
        reverseRingDirection: Bool
    )

    private func resetToDefaults() {
        let toolOld: ButtonToolState = (tool.tipBinding, tool.eraserBinding, tool.penButton1Binding, tool.penButton2Binding)
        let settingsOld: ButtonSettingsState = (
            settings.expressKeyBindings, settings.touchRingButtonBinding,
            settings.touchRingSlots, settings.touchRingActiveSlotIndex,
            settings.reverseRingDirection
        )
        let isMouse = activeToolSpec?.toolType == .mouse
        let toolDefaults: ButtonToolState = (.leftClick, .eraser, .rightClick, isMouse ? .rightClick : .middleClick)
        let vendorID = tabletManager.context(forKey: instanceKey)?.vendorID ?? 0x056A
        let settingsDefaults: ButtonSettingsState = (
            TabletSettings.defaultExpressKeyBindings(vendorID: vendorID),
            ButtonBinding(kind: .ringCycle), ControlSlot.defaults, 0, false
        )

        settings.undoManager?.beginUndoGrouping()
        applyButtonToolReset(toolDefaults, undoTo: toolOld)
        applyButtonSettingsReset(settingsDefaults, undoTo: settingsOld)
        settings.undoManager?.endUndoGrouping()
    }

    /// Self-recursive so "Reset to Defaults" also redoes the tool-owned half.
    private func applyButtonToolReset(_ new: ButtonToolState, undoTo old: ButtonToolState) {
        let t = activeToolBinding
        t.wrappedValue.tipBinding = new.tip
        t.wrappedValue.eraserBinding = new.eraser
        t.wrappedValue.penButton1Binding = new.pen1
        t.wrappedValue.penButton2Binding = new.pen2
        settings.objectWillChange.send()
        settings.record(String(localized: "Reset to Defaults", comment: "Undo action name: restoring a pane's controls to their defaults")) {
            self.applyButtonToolReset(old, undoTo: new)
        }
    }

    /// Self-recursive so "Reset to Defaults" also redoes the settings-owned half.
    private func applyButtonSettingsReset(_ new: ButtonSettingsState, undoTo old: ButtonSettingsState) {
        settings.expressKeyBindings = new.expressKeys
        settings.touchRingButtonBinding = new.touchRingButton
        settings.touchRingSlots = new.touchRingSlots
        settings.touchRingActiveSlotIndex = new.touchRingActiveSlot
        settings.reverseRingDirection = new.reverseRingDirection
        settings.record(String(localized: "Reset to Defaults", comment: "Undo action name: restoring a pane's controls to their defaults")) {
            self.applyButtonSettingsReset(old, undoTo: new)
        }
    }

    // MARK: - Pen buttons section

    @ViewBuilder
    private func penButtonsSection(lb: LiveButtonState) -> some View {
        let toolSpec = activeToolSpec
        let isMouse = toolSpec?.toolType == .mouse
        // For mice, show all 5 HID-path button slots regardless of spec.buttonCount
        // (spec.buttonCount describes only the digitizer path, not the full HID mouse report)
        //
        // toolSpec is nil whenever no pen has reported in yet (before first
        // proximity, or between proximity events — TabletManager zeroes
        // activeToolCode on every proximity exit). The fallback used to be a
        // flat 2, which meant the Xencelabs 3-button pen's pane reverted to a
        // 2-button view any time the pen lifted off — hiding the 3rd slot even
        // though it's a real assignable button on that hardware. Both
        // Xencelabs pens share one spec (buttonCount: 3, see WacomToolSpec's
        // Xencelabs section) since the wire protocol can't tell them apart,
        // so defaulting to 3 here is correct for either pen; a genuine
        // 2-button pen just leaves the 3rd slot unused.
        let btnCount = isMouse ? 5 : (toolSpec?.buttonCount ?? (spec?.parser == .xencelabs ? 3 : 2))
        let hasWheel = toolSpec?.hasWheel == true

        Section {
            // Tip — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Tip", comment: "Pen tip button row label in Buttons tab"),
                    isActive: lb.tipDown,
                    binding: tipBinding,
                    recordRequestToken: penRecordTokens[0])
            }

            // Eraser — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Eraser", comment: "Eraser button row label in Buttons tab"),
                    isActive: lb.eraserDown,
                    binding: eraserBinding,
                    recordRequestToken: penRecordTokens[1])
            }

            // Button 1
            if btnCount >= 1 {
                buttonRow(
                    isMouse
                        ? String(localized: "Button 1", comment: "Pen button row label: mouse button 1")
                        : (btnCount == 1
                            ? String(localized: "Side button", comment: "Pen button row label: single side button")
                            : String(localized: "Side button 1", comment: "Pen button row label: first side button")),
                    isActive: lb.button1Down,
                    binding: pen1Binding,
                    recordRequestToken: penRecordTokens[2])
            }
            // Button 2
            if btnCount >= 2 {
                buttonRow(
                    isMouse
                        ? String(localized: "Button 2", comment: "Pen button row label: mouse button 2")
                        : String(localized: "Side button 2", comment: "Pen button row label: second side button"),
                    isActive: lb.button2Down,
                    binding: pen2Binding,
                    recordRequestToken: penRecordTokens[3])
            }
            // Button 3
            if btnCount >= 3 {
                buttonRow(
                    isMouse
                        ? String(localized: "Button 3", comment: "Pen button row label: mouse button 3")
                        : String(localized: "Side button 3", comment: "Pen button row label: third side button"),
                    isActive: lb.button3Down,
                    binding: pen3Binding,
                    recordRequestToken: penRecordTokens[4])
            }
            // Button 4
            if btnCount >= 4 {
                buttonRow(
                    isMouse
                        ? String(localized: "Button 4", comment: "Pen button row label: mouse button 4")
                        : String(localized: "Side button 4", comment: "Pen button row label: fourth side button"),
                    isActive: lb.button4Down,
                    binding: pen4Binding)
            }
            // Button 5
            if btnCount >= 5 {
                buttonRow(
                    isMouse
                        ? String(localized: "Button 5", comment: "Pen button row label: mouse button 5")
                        : String(localized: "Side button 5", comment: "Pen button row label: fifth side button"),
                    isActive: lb.button5Down,
                    binding: pen5Binding)
            }

            // Wheel row — airbrush fingerwheel or scroll wheel
            if hasWheel {
                let wheelLabel =
                    toolSpec?.toolType == .airbrush
                    ? String(localized: "Fingerwheel", comment: "Airbrush fingerwheel row label")
                    : String(localized: "Scroll Wheel", comment: "Mouse scroll wheel row label")
                buttonRow(wheelLabel, isActive: false, binding: wheelBinding)
            }

            // Diagram row: no label column; transparent so the section
            // background shows through unchanged. Clicking a part starts
            // recording in its binding row — parts whose row isn't shown
            // (mouse tools, missing buttons) stay inert.
            PenDiagramView(liveButtons: lb, onPartTap: { part in
                switch part {
                case .tip: if !isMouse { penRecordTokens[0] += 1 }
                case .eraser: if !isMouse { penRecordTokens[1] += 1 }
                case .button1: if btnCount >= 1 { penRecordTokens[2] += 1 }
                case .button2: if btnCount >= 2 { penRecordTokens[3] += 1 }
                case .button3: if btnCount >= 3 { penRecordTokens[4] += 1 }
                }
            }, enabledParts: {
                var parts: Set<PenDiagramView.Part> = []
                if !isMouse { parts.insert(.tip); parts.insert(.eraser) }
                if btnCount >= 1 { parts.insert(.button1) }
                if btnCount >= 2 { parts.insert(.button2) }
                if btnCount >= 3 { parts.insert(.button3) }
                return parts
            }())
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 64)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
        } header: {
            PaneSectionHeader(isMouse ? "Mouse Buttons" : "Pen Buttons") {
                ToolNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }
    }

    // MARK: - Single-sided layout (most tablets)

    @ViewBuilder
    private func singleSidedSection(lb: LiveButtonState) -> some View {
        // DeviceNameLabel heads this section so it sits between the pen section
        // and the hardware button rows, matching the original visual intent.
        // Xencelabs tablets/displays report 0 here — their express keys live
        // on the puck/dongle companion instead (see quickKeysSection below) —
        // so skip an empty section rather than showing a header with no rows.
        if expressKeyCount > 0 {
            Section {
                ForEach(0..<expressKeyCount, id: \.self) { i in
                    expressKeyRow(
                        index: i,
                        label: String(localized: "Key \(i + 1)", comment: "Express key N label, e.g. 'Key 1'"),
                        lb: lb)
                }
            } header: {
                PaneSectionHeader("Express Keys") {
                    DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
                }
            }
        }

        // Dual-ring hardware without the Cintiq's split pad (the gen-3 Intuos
        // Pro's two dials) still needs both rings shown, so borrow the
        // dual-sided layout's Left/Right headers. Both rings drive one shared
        // mode setting — mirrored, exactly as on the Cintiq — so the right
        // section is a second live view of the same slots, not its own
        // storage. A per-ring binding would need the work listed in
        // WacomKnownDevice.swift's ring2 TODO.
        // The direction toggle is device-wide, so it belongs to whichever of
        // these sections comes last rather than repeating in each.
        if hasTouchRing {
            if hasDualRings {
                Section("Touch Ring — Left") { touchRingBlock(lb: lb) }
                Section("Touch Ring — Right") {
                    touchRingSlotsSection(
                        String(
                            localized: "Touch Ring",
                            comment: "Section header / row label for touch ring"),
                        isActive: lb.touchRing2Active, showsDiagram: true)
                    if !hasTouchStrips { reverseRingDirectionToggle }
                }
            } else {
                Section("Touch Ring") {
                    touchRingBlock(lb: lb)
                    if !hasTouchStrips { reverseRingDirectionToggle }
                }
            }
        }

        if hasTouchStrips {
            Section("Touch Strips") {
                touchRingSlotsSection(
                    String(localized: "Left", comment: "Left touch strip row label"),
                    isActive: lb.touchStrip1Active)
                touchRingSlotsSection(
                    String(localized: "Right", comment: "Right touch strip row label"),
                    isActive: lb.touchStrip2Active)
                reverseRingDirectionToggle
            }
        }

        quickKeysSection
    }

    /// Center-click row plus the ring's mode list — the body of the primary
    /// ring's section, shared by the single-ring and dual-ring headers above.
    @ViewBuilder
    private func touchRingBlock(lb: LiveButtonState) -> some View {
        buttonRow(
            String(localized: "Center", comment: "Touch ring center button row label"),
            isActive: lb.touchRingButtonDown,
            binding: settings.recordingBinding(
                String(localized: "Touch Ring Button", comment: "Undo action name: touch ring center-click binding in the Buttons pane"),
                get: { settings.touchRingButtonBinding },
                set: { settings.touchRingButtonBinding = $0 }),
            ringSlotCount: spec?.ringSlotCount ?? 4,
            recordRequestToken: centerRecordToken)
        touchRingSlotsSection(
            String(
                localized: "Touch Ring",
                comment: "Section header / row label for touch ring"),
            isActive: lb.touchRingActive, showsDiagram: true,
            onCenterTap: { centerRecordToken += 1 })
    }

    /// Direction preference for every ring/dial/strip on the device — one
    /// setting, deliberately not per-ring or per-slot: a user reaches for this
    /// because their muscle memory disagrees with the hardware convention, and
    /// that disagreement is uniform. The caption follows Pen Feel's "Invert
    /// Rotation Direction" — naming the current direction with an arrow glyph
    /// rather than describing what each mode does, which stays short and stays
    /// true whatever the four slots are set to.
    @ViewBuilder
    private var reverseRingDirectionToggle: some View {
        DescribedToggle(
            "Reverse Direction",
            isOn: settings.recordingBinding(
                String(localized: "Ring Direction", comment: "Undo action name: touch ring/dial direction toggle in the Buttons pane"),
                get: { settings.reverseRingDirection },
                set: { settings.reverseRingDirection = $0 })
        ) {
            Text("Current: ")
                + Text(
                    Image(
                        systemName: settings.reverseRingDirection
                            ? "arrow.counterclockwise"
                            : "arrow.clockwise"))
                + Text(
                    settings.reverseRingDirection
                        ? " Counter-clockwise."
                        : " Clockwise.")
        }
        .help("Flips the direction of every ring, dial, and strip on this tablet, whatever each mode is set to. Turn on if the hardware runs opposite to your expectation.")
    }

    /// Express keys + dial for a connected companion puck/dongle, folded
    /// into the tablet's own Buttons pane instead of the companion getting
    /// a window (and settings) of its own — see `companionProductID`.
    /// `QuickKeysSectionView` reads/writes the companion's *own*
    /// `TabletSettings` instance (its own `DeviceContext`, keyed by its own
    /// PID), not the tablet's — each physical device keeps its own
    /// independent binding storage, exactly as if the companion still had
    /// its own pane; only the window is merged.
    @ViewBuilder
    private var quickKeysSection: some View {
        if let companionSettings = companionContext?.settings {
            // The companion's settings instance never passes through this
            // window's controller, which wires only its own settings to the
            // window undo manager — the companion borrows it here or its
            // edits record no undo actions at all.
            let _ = (companionSettings.undoManager = settings.undoManager)
            // Editable regardless of connection, same as the pen/bezel
            // sections — the companion's capability spec is already known
            // from its stub, so there's no reason to block edits just
            // because the puck happens to be detached right now. The
            // header shows a "Not connected" hint instead of disabling
            // the section (disable-vs-hide rule: connection is temporary
            // state, not a capability change).
            QuickKeysSectionView(
                settings: companionSettings, spec: companionSpec, liveButtons: companionLiveButtons,
                isDeviceConnected: companionIsConnected,
                // Keyed to the companion, not this window's tablet — the
                // section configures the puck, so its header must name the
                // puck (or its nickname) and track the puck's connection.
                nameLabel: DeviceNameLabel(
                    tabletManager: tabletManager, registry: registry,
                    instanceKey: companionContext?.instanceKey))
        }
    }

    // MARK: - Dual-sided layout (Cintiq 24HD and similar)
    // Indices  0– 2 = left toggle buttons (near ring)
    // Indices  3– 7 = left express keys
    // Indices  8–10 = right toggle buttons (near ring, mirror)
    // Indices 11–15 = right express keys (mirror)
    // Both rings share the same mode setting (mirrored behavior).

    @ViewBuilder
    private func dualSidedSection(lb: LiveButtonState) -> some View {
        Section {
            ForEach(0..<3, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Button \(i + 1)",
                        comment: "Toggle button N label, e.g. 'Button 1'"), lb: lb)
            }
        } header: {
            PaneSectionHeader("Toggle Buttons — Left") {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }

        Section("Express Keys — Left") {
            ForEach(3..<8, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(localized: "Key \(i - 2)", comment: "Express key N label, e.g. 'Key 1'"),
                    lb: lb)
            }
        }

        Section("Touch Ring — Left") {
            touchRingSlotsSection(
                String(
                    localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                isActive: lb.touchRingActive, showsDiagram: true)
        }

        Section("Toggle Buttons — Right") {
            ForEach(8..<11, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Button \(i - 7)",
                        comment: "Toggle button N label, e.g. 'Button 1'"), lb: lb)
            }
        }

        Section("Express Keys — Right") {
            ForEach(11..<16, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(localized: "Key \(i - 10)", comment: "Express key N label, e.g. 'Key 1'"),
                    lb: lb)
            }
        }

        Section("Touch Ring — Right") {
            touchRingSlotsSection(
                String(
                    localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                isActive: lb.touchRing2Active, showsDiagram: true)
            reverseRingDirectionToggle
        }
    }

    // MARK: - Bezel buttons (device's own onboard capacitive buttons, e.g.
    // the Cintiq DTK-2400's OSD keys or the Xencelabs display's touch
    // buttons) — a fixed-size section folded onto the bottom of the pane,
    // independent of expressKeyBindings since some devices already use all
    // 16 of those slots.

    @ViewBuilder
    private func bezelButtonsSection(lb: LiveButtonState) -> some View {
        Section {
            ForEach(0..<bezelButtonCount, id: \.self) { i in
                bezelButtonRow(
                    index: i,
                    label: String(
                        localized: "Bezel Button \(i + 1)",
                        comment: "Bezel button N label, e.g. 'Bezel Button 1'"), lb: lb)
            }
            if hasBezelLED {
                HStack(alignment: .top) {
                    Text("Button Backlight")
                    Spacer()
                    LEDColorControl(
                        style: .inline,
                        color: Binding(
                            get: { settings.bezelLEDColorValue },
                            set: { settings.bezelLEDColorValue = $0 }),
                        defaultWire: (r: 0xF7, g: 0x00, b: 0x00),
                        undoLabel: "Bezel Button Backlight",
                        settings: settings)
                        .equatable()
                        // Ease off the window edge a touch — flush-trailing
                        // reads cramped next to the bordered rows above.
                        .padding(.trailing, 12)
                }
                .help("Color and brightness of the light behind the bezel buttons. The hardware keeps its own color until you change it.")
            }
        } header: {
            PaneSectionHeader("Bezel Buttons") {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }
    }

    /// Whether the bezel buttons have a host-controllable backlight LED —
    /// Xencelabs pen displays only; the Cintiq's OSD keys have no light of
    /// their own. Static capability, so the well stays put while the
    /// display is unplugged (writes replay on reconnect).
    private var hasBezelLED: Bool {
        guard let pid = productID, let spec = TabletManager.staticSpec(forProductID: pid)
        else { return false }
        return spec.parser == .xencelabs && spec.isPenDisplay
    }


    @ViewBuilder
    private func bezelButtonRow(index: Int, label: String, lb: LiveButtonState) -> some View {
        buttonRow(
            label,
            isActive: lb.bezelButtons[index],
            binding: settings.recordingBinding(
                String(localized: "Bezel Button \(index + 1)"),
                get: { settings.bezelButtonBindings[index] },
                set: { newValue in
                    var updated = settings.bezelButtonBindings
                    updated[index] = newValue
                    settings.bezelButtonBindings = updated
                }
            )
        )
    }

    // MARK: - Express key row helper

    @ViewBuilder
    private func expressKeyRow(index: Int, label: String, lb: LiveButtonState) -> some View {
        buttonRow(
            label,
            isActive: lb.expressKeys[index],
            binding: settings.recordingBinding(
                String(localized: "Express Key \(index + 1)", comment: "Undo action name: express key binding in the Buttons pane"),
                get: { settings.expressKeyBindings[index] },
                set: { newValue in
                    var updated = settings.expressKeyBindings
                    updated[index] = newValue
                    settings.expressKeyBindings = updated
                }
            ),
            ringSlotCount: spec?.ringSlotCount ?? 4
        )
    }

    // MARK: - Touch ring / strip slots section

    /// The mode block for a ring or strip: label row, then the summary-list/
    /// detail-editor component (which carries the clickable ring diagram when
    /// `showsDiagram` is set — rings only, strips have no round schematic).
    @ViewBuilder
    private func touchRingSlotsSection(
        _ label: String, isActive: Bool, showsDiagram: Bool = false,
        onCenterTap: (() -> Void)? = nil
    ) -> some View {
        // Label row — shows "Touch Ring", "Left", or "Right" with live-active indicator.
        HStack(spacing: 6) {
            activeIndicator(isActive)
            labelText(label, isActive: isActive)
            Spacer(minLength: 0)
        }

        // Show only as many slots as the spec declares (default 4); model always stores 4.
        let ringSlotCount = spec?.ringSlotCount ?? 4
        TouchRingModeListView(
            slots: settings.touchRingSlots,
            shownSlotCount: min(settings.touchRingSlots.count, ringSlotCount),
            ringSlotCount: ringSlotCount,
            isRingActive: isActive,
            activeSlotIndex: settings.touchRingActiveSlotIndex,
            centerDown: liveButtons.touchRingButtonDown,
            showsDiagram: showsDiagram,
            actionBinding: slotBinding(at:),
            speedBinding: slotSpeedBinding(at:),
            cwBinding: { self.slotBinding(for: $0, direction: .cw) },
            ccwBinding: { self.slotBinding(for: $0, direction: .ccw) },
            onCenterTap: onCenterTap
        )
    }

    // buttonRow / activeIndicator / labelText now live in
    // UI/Components/ButtonRow.swift, shared with QuickKeysSectionView.

}

// Touch ring slot rows, the shortcut-recorder control, and the live-resize
// detector used above all live in UI/Components/ now — see
// TouchRingSlotRow.swift, ButtonBindingControl.swift, and
// LiveResizeDetector.swift.
