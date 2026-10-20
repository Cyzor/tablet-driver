// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import SwiftUI
import TabletKit

// The Buttons pane's ExpressKey layouts: single-sided, dual-sided (Cintiq
// 24HD), and bezel buttons, plus the shared key row.
extension ButtonMappingView {
    @ViewBuilder
    func singleSidedSection(lb: LiveButtonState) -> some View {
        // DeviceNameLabel heads this section so it sits between the pen section
        // and the hardware button rows, matching the original visual intent.
        // Xencelabs tablets/displays report 0 here — their express keys live
        // on the puck/dongle companion instead (see quickKeysSection below) —
        // so skip an empty section rather than showing a header with no rows.
        if isRemote {
            remoteKeySections(lb: lb)
        } else if expressKeyCount > 0 {
            Section {
                tabletDiagramRow(lb: lb)
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

        // Two rotaries (Cintiq 24HD rings, PTK-670/870 dials) get a Left and
        // a Right section, each with its own modes. The direction toggle is
        // device-wide, so it goes after the last section. Mechanical dials
        // say "Dial" instead of "Touch Ring".
        let ringSectionLabel = hasMechanicalDial
            ? String(localized: "Dial", comment: "Section header / row label for a mechanical rotate-only dial")
            : String(localized: "Touch Ring", comment: "Section header / row label for touch ring")
        if hasTouchRing {
            if hasDualRings {
                Section("\(ringSectionLabel) — Left") {
                    touchRingBlock(lb: lb)
                }
                Section("\(ringSectionLabel) — Right") {
                    if hasMechanicalDial { dialToggleBlock2(lb: lb) }
                    touchRingSlotsSection(
                        ringSectionLabel,
                        isActive: hasMechanicalDial ? dialsTurning[1] : lb.touchRing2Active, showsDiagram: !hasMechanicalDial,
                        showsModeBadge: hasMechanicalDial,
                        ring: .secondary)
                }
                if !hasTouchStrips { bothRingsDirectionSection }
            } else {
                Section(ringSectionLabel) {
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

    /// ExpressKey Remote keys, grouped and ordered as on the hardware.
    @ViewBuilder
    func remoteKeySections(lb: LiveButtonState) -> some View {
        Section {
            ForEach(Self.remoteRingKeySlots, id: \.self) { remoteKeyRow($0, lb: lb) }
        } header: {
            PaneSectionHeader("Ring Keys") {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }
        Section("Outer Keys") {
            ForEach(Self.remoteOuterLeftSlots + Self.remoteOuterRightSlots, id: \.self) { remoteKeyRow($0, lb: lb) }
        }
        Section("Inner Keys") {
            ForEach(Self.remoteInnerSlots, id: \.self) { remoteKeyRow($0, lb: lb) }
        }
    }

    /// Key 17 arrives past the 16 express-key slots, where the injector
    /// reads bezel binding 0; the remote has no bezel.
    @ViewBuilder
    func remoteKeyRow(_ index: Int, lb: LiveButtonState) -> some View {
        let label = Self.remoteKeyLabel(slot: index)
        if index < 16 {
            expressKeyRow(index: index, label: label, lb: lb)
        } else {
            bezelButtonRow(index: 0, label: label, lb: lb)
        }
    }

    /// Center row plus the ring's mode list, for the primary ring's section.
    ///
    /// PTK dials have no center press; their mode key is the middle
    /// ExpressKey of the dial's cluster, shown as "Dial Toggle". The 24HD's
    /// rings have no center either; three keys beside each ring pick its
    /// modes. The remote's center button belongs to its firmware.
    @ViewBuilder
    func touchRingBlock(lb: LiveButtonState) -> some View {
        let hasCenterButton = !hasMechanicalDial && !isRemote && !hasSplitPadLayout
        if hasMechanicalDial {
            buttonRow(
                String(localized: "Dial Toggle", comment: "Row label for the ExpressKey that cycles a mechanical dial's modes"),
                isActive: lb.touchRingButtonDown,
                binding: settings.recordingBinding(
                    String(localized: "Dial Toggle", comment: "Undo action name: dial toggle key binding in the Buttons pane"),
                    get: { settings.touchRingButtonBinding },
                    set: { settings.touchRingButtonBinding = $0 }),
                ringSlotCount: spec?.ringSlotCount ?? 4,
                modeNames: ringModeNames,
                isMechanicalDialHardware: true,
                dialToggleControl: .first,
                recordRequestToken: centerRecordToken)
            .id(ControlTarget.ringCenter(0))
        } else if hasCenterButton {
            buttonRow(
                String(localized: "Center", comment: "Touch ring center button row label"),
                isActive: lb.touchRingButtonDown,
                binding: settings.recordingBinding(
                    String(localized: "Touch Ring Button", comment: "Undo action name: touch ring center-click binding in the Buttons pane"),
                    get: { settings.touchRingButtonBinding },
                    set: { settings.touchRingButtonBinding = $0 }),
                ringSlotCount: spec?.ringSlotCount ?? 4,
                modeNames: ringModeNames,
                recordRequestToken: centerRecordToken)
            .id(ControlTarget.ringCenter(0))
        }
        touchRingSlotsSection(
            hasMechanicalDial
                ? String(localized: "Dial", comment: "Section header / row label for a mechanical rotate-only dial")
                : String(localized: "Touch Ring", comment: "Section header / row label for touch ring"),
            isActive: hasMechanicalDial ? dialsTurning[0] : lb.touchRingActive, showsDiagram: !hasMechanicalDial,
            showsModeBadge: hasMechanicalDial,
            onCenterTap: hasCenterButton ? { centerRecordToken += 1 } : nil,
            centerBinding: !hasCenterButton ? nil : settings.recordingBinding(
                String(localized: "Touch Ring Button", comment: "Undo action name: touch ring center-click binding in the Buttons pane"),
                get: { settings.touchRingButtonBinding },
                set: { settings.touchRingButtonBinding = $0 }))
    }

    /// Second dial's own "Dial Toggle" row (PTK-670/870's right cluster
    /// center key) — the counterpart to `touchRingBlock`'s row, but for
    /// `touchRingButtonBinding2`. Only ever shown alongside
    /// `touchRingSlotsSection(ring: .secondary)` for `hasMechanicalDial`
    /// devices; capacitive dual-ring hardware (Cintiq 24HD) has no
    /// equivalent second toggle key and never calls this.
    @ViewBuilder
    func dialToggleBlock2(lb: LiveButtonState) -> some View {
        buttonRow(
            String(localized: "Dial Toggle", comment: "Row label for the ExpressKey that cycles a mechanical dial's modes"),
            isActive: lb.touchRing2ButtonDown,
            binding: settings.recordingBinding(
                String(localized: "Dial 2 Toggle", comment: "Undo action name: second dial toggle key binding in the Buttons pane"),
                get: { settings.touchRingButtonBinding2 },
                set: { settings.touchRingButtonBinding2 = $0 }),
            ringSlotCount: spec?.ringSlotCount ?? 4,
            isMechanicalDialHardware: true,
            dialToggleControl: .second,
            recordRequestToken: dial2RecordToken)
        .id(ControlTarget.ringCenter(1))
    }

    /// Direction preference for every ring/dial/strip on the device — one
    /// setting, deliberately not per-ring or per-slot: a user reaches for this
    /// because their muscle memory disagrees with the hardware convention, and
    /// that disagreement is uniform. The caption follows Pen Feel's "Invert
    /// Rotation Direction" — naming the current direction with an arrow glyph
    /// rather than describing what each mode does, which stays short and stays
    /// true whatever the four slots are set to.
    ///
    /// Wording branches on `hasTouchStrips`: a linear strip has no rotational
    /// sense, so "Clockwise"/"Counter-clockwise" (correct for a ring or dial)
    /// would be nonsensical there. A device with strips only gets
    /// direction-neutral "Forward"/"Reversed" wording instead. This toggle is
    /// never shown for a device with both a ring/dial and strips at once
    /// today (see the call sites' `if !hasTouchStrips` guards), so branching
    /// on `hasTouchStrips` alone is sufficient — revisit if that changes.
    /// The direction toggle on two-ring hardware, in its own section so the
    /// header states its scope; under either ring it read as that ring's.
    var bothRingsDirectionSection: some View {
        Section(
            hasMechanicalDial
                ? String(localized: "Both Dials", comment: "Section header for a setting shared by a tablet's two dials")
                : String(localized: "Both Touch Rings", comment: "Section header for a setting shared by a tablet's two touch rings")
        ) {
            reverseRingDirectionToggle
        }
    }

    @ViewBuilder
    var reverseRingDirectionToggle: some View {
        DescribedToggle(
            "Reverse Direction",
            isOn: settings.recordingBinding(
                String(localized: "Ring Direction", comment: "Undo action name: touch ring/dial direction toggle in the Buttons pane"),
                get: { settings.reverseRingDirection },
                set: { settings.reverseRingDirection = $0 }),
            currentIcon: hasTouchStrips
                ? (settings.reverseRingDirection ? "arrow.up" : "arrow.down")
                : (settings.reverseRingDirection ? "arrow.counterclockwise" : "arrow.clockwise"),
            current: hasTouchStrips
                ? (settings.reverseRingDirection ? " Reversed." : " Forward.")
                : (settings.reverseRingDirection ? " Counter-clockwise." : " Clockwise."),
            help: "Flips the direction of every ring, dial, and strip on this tablet, whatever each mode is set to. Turn on if the hardware runs opposite to your expectation.")
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
    var quickKeysSection: some View {
        if companionProductID == DeviceCompanions.expressKeyRemoteProductID,
           let companion = companionContext {
            let _ = (companion.settings.undoManager = settings.undoManager)
            ButtonMappingView(
                settings: companion.settings, tabletManager: tabletManager, registry: registry,
                instanceKey: companion.instanceKey, isEmbeddedRemote: true)
        } else if let companionSettings = companionContext?.settings {
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
    func dualSidedSection(lb: LiveButtonState) -> some View {
        Section {
            tabletDiagramRow(lb: lb)
            ForEach(0..<3, id: \.self) { i in
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
            }
        } header: {
            PaneSectionHeader("Toggle Buttons — Left") {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }

        Section("Express Keys — Left") {
            ForEach(3..<8, id: \.self) { i in
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
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
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
            }
        }

        Section("Express Keys — Right") {
            ForEach(11..<16, id: \.self) { i in
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
            }
        }

        Section("Touch Ring — Right") {
            touchRingSlotsSection(
                String(
                    localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                isActive: lb.touchRing2Active, showsDiagram: true)
        }
        bothRingsDirectionSection
    }

    // MARK: - Bezel buttons (device's own onboard capacitive buttons, e.g.
    // the Cintiq DTK-2400's OSD keys or the Xencelabs display's touch
    // buttons) — a fixed-size section folded onto the bottom of the pane,
    // independent of expressKeyBindings since some devices already use all
    // 16 of those slots.

    @ViewBuilder
    func bezelButtonsSection(lb: LiveButtonState) -> some View {
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
    var hasBezelLED: Bool {
        guard let pid = productID else { return false }
        return TabletManager.staticSpec(forProductID: pid)?.offeredControls.contains(.displayPanel) == true
    }


    @ViewBuilder
    func bezelButtonRow(index: Int, label: String, lb: LiveButtonState) -> some View {
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
            ),
            modeNames: ringModeNames
        )
    }

    // MARK: - Express key row helper

    @ViewBuilder
    func expressKeyRow(index: Int, label: String, lb: LiveButtonState) -> some View {
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
            ringSlotCount: spec?.ringSlotCount ?? 4,
            offersSecondDial: hasDualRings,
            modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial,
            recordRequestToken: keyRecordTokens[index]
        )
        .id(ControlTarget.expressKey(index))
    }

    // MARK: - Tablet diagram

    /// The tablet drawn above its key rows, once its family's key order is verified.
    @ViewBuilder
    func tabletDiagramRow(lb: LiveButtonState) -> some View {
        if let figure = tabletDiagramFigure {
            TabletDiagramView(figure: figure, lit: diagramLit(lb), enabled: diagramEnabled, onTap: { diagramTap($0) })
                .frame(maxWidth: .infinity)
                .frame(height: TabletBezelFrame<EmptyView>.height(.landscape))
                .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
                .listRowBackground(Color.clear)
        }
    }

    var tabletDiagramFigure: TabletFigure? {
        guard let spec else { return nil }
        if let cached = Self.diagramFigures[spec.productID] { return cached }
        let figure = Self.diagramFigure(for: spec)
        Self.diagramFigures[spec.productID] = .some(figure)
        return figure
    }

    /// Figures by product ID, nil for a model without one. A figure depends
    /// only on the model, so each pane update costs a lookup.
    private static var diagramFigures: [Int: TabletFigure?] = [:]

    private static func diagramFigure(for spec: TabletSpec) -> TabletFigure? {
        guard spec.maxX > 0, spec.maxY > 0,
              let map = TabletControlMap.forDevice(productID: spec.productID, spec: spec)
        else { return nil }
        let mm = spec.activeWidthMM.flatMap { w in spec.activeHeightMM.map { CGSize(width: w, height: $0) } }
        var figure = TabletFigure(layoutProductID: spec.productID, surfaceMM: mm,
                                  aspect: Double(spec.maxX) / Double(spec.maxY), isPenDisplay: spec.isPenDisplay)
        figure.controls = map.parts
        return figure
    }

    /// The controls in use, as `ControlTarget` bits. Input from another
    /// tablet lights nothing: its key 3 isn't this tablet's.
    func diagramLit(_ lb: LiveButtonState) -> UInt64 {
        guard !liveInputMuffled else { return 0 }
        var bits: UInt64 = 0
        func set(_ target: ControlTarget, _ on: Bool) { if on { bits |= 1 << UInt64(target.bit) } }
        for (i, down) in lb.expressKeys.prefix(16).enumerated() { set(.expressKey(i), down) }
        for (i, down) in lb.bezelButtons.prefix(3).enumerated() { set(.bezel(i), down) }
        set(.ringCenter(0), lb.touchRingButtonDown)
        set(.ringCenter(1), lb.touchRing2ButtonDown)
        set(.ring(0), lb.touchRingActive)
        set(.ring(1), lb.touchRing2Active)
        set(.strip(0), lb.touchStrip1Active)
        set(.strip(1), lb.touchStrip2Active)
        let dials = dialsTurning
        set(.dial(0), dials[0])
        set(.dial(1), dials[1])
        return bits
    }

    /// The controls with a row below, which answer clicks: the rows
    /// `singleSidedSection`, `dualSidedSection`, and `touchRingBlock` show.
    var diagramEnabled: UInt64 {
        var bits: UInt64 = 0
        for i in 0..<(hasSplitPadLayout ? 16 : expressKeyCount) { bits |= 1 << UInt64(i) }
        if hasTouchRing && !hasSplitPadLayout && !isRemote { bits |= 1 << UInt64(ControlTarget.ringCenter(0).bit) }
        if hasTouchRing && hasDualRings && hasMechanicalDial && !hasSplitPadLayout {
            bits |= 1 << UInt64(ControlTarget.ringCenter(1).bit)
        }
        return bits
    }

    /// Starts recording in the clicked control's row. A row scrolled into
    /// view only now is created after the first bump, so a second bump once
    /// the scroll settles reaches it; a row already recording ignores it.
    func diagramTap(_ target: ControlTarget) {
        bumpRecordToken(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { bumpRecordToken(target) }
    }

    private func bumpRecordToken(_ target: ControlTarget) {
        switch target {
        case let .expressKey(i) where i < keyRecordTokens.count: keyRecordTokens[i] += 1
        case .ringCenter(0): centerRecordToken += 1
        case .ringCenter(1): dial2RecordToken += 1
        default: break
        }
    }
}
