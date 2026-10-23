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
        // The device line heads this section unless the tablet section above
        // carries it. Xencelabs tablets and displays report 0 keys here, since
        // theirs live on the puck or dongle companion (see quickKeysSection
        // below), so an empty section is skipped rather than shown bare.
        if isRemote {
            remoteKeySections(lb: lb)
        } else if expressKeyCount > 0 {
            Section {
                ForEach(0..<expressKeyCount, id: \.self) { i in
                    expressKeyRow(
                        index: i,
                        label: String(localized: "Key \(i + 1)", comment: "Express key N label, e.g. 'Key 1'"),
                        lb: lb)
                }
            } header: {
                PaneSectionHeader("Express Keys") { deviceLineUnlessTabletSection }
            }
        }

        // Two rotaries (Cintiq 24HD rings, PTK-670/870 dials) get a section
        // for each side as you see it, each with its own modes. The direction
        // toggle is device-wide, so it goes after the last section. Mechanical
        // dials say "Dial" instead of "Touch Ring".
        let ringSectionLabel = hasMechanicalDial
            ? String(localized: "Dial", comment: "Section header / row label for a mechanical rotate-only dial")
            : String(localized: "Touch Ring", comment: "Section header / row label for touch ring")
        if hasTouchRing {
            if hasDualRings {
                Section {
                    touchRingBlock(lb: lb)
                } header: {
                    sideHeader(ringSectionLabel, place: 0)
                }
                Section {
                    if hasMechanicalDial { dialToggleBlock2(lb: lb) }
                    touchRingSlotsSection(
                        ringSectionLabel,
                        isActive: rotaryActive(place: 1, lb: lb), showsDiagram: !hasMechanicalDial,
                        showsModeBadge: hasMechanicalDial,
                        ring: .secondary)
                } header: {
                    sideHeader(ringSectionLabel, place: 1)
                }
                if !hasTouchStrips { bothRingsDirectionSection }
            } else {
                Section(ringSectionLabel) {
                    touchRingBlock(lb: lb)
                    if !hasTouchStrips { reverseRingDirectionToggle }
                }
            }
        }

        if hasStripToggles {
            // Each strip has its own toggle and modes, so a section per side.
            let stripLabel = String(localized: "Touch Strip", comment: "Section header for one of a tablet's touch strips")
            ForEach(0..<2, id: \.self) { place in
                let strip = placed(.strip(place)).index
                Section {
                    stripToggleRow(place: place, lb: lb)
                    touchRingSlotsSection(
                        stripLabel,
                        isActive: strip == 0 ? lb.touchStrip1Active : lb.touchStrip2Active,
                        strip: place)
                } header: {
                    sideHeader(stripLabel, place: place)
                }
            }
            Section(String(localized: "Both Touch Strips", comment: "Section header for a setting shared by a tablet's two touch strips")) {
                reverseRingDirectionToggle
            }
        } else if hasTouchStrips {
            Section("Touch Strips") {
                ForEach(0..<2, id: \.self) { place in
                    let strip = placed(.strip(place)).index
                    touchRingSlotsSection(
                        sideName(place: place),
                        isActive: strip == 0 ? lb.touchStrip1Active : lb.touchStrip2Active,
                        side: sideSymbol(place: place),
                        scrollTarget: .strip(strip))
                }
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
        // The first ring or dial as you see it, and its center or toggle.
        let center = placed(.ringCenter(0)).index
        if hasMechanicalDial {
            dialToggleRow(
                center, undoName: String(localized: "Dial Toggle", comment: "Undo action name: dial toggle key binding in the Buttons pane"),
                lb: lb)
        } else if hasCenterButton {
            buttonRow(
                String(localized: "Center", comment: "Touch ring center button row label"),
                isActive: centerDown(center, lb: lb),
                binding: centerBinding(center, undoName: String(localized: "Touch Ring Button", comment: "Undo action name: touch ring center-click binding in the Buttons pane")),
                ringSlotCount: spec?.ringSlotCount ?? 4,
                modeNames: ringModeNames,
                placement: rotaryPlacement,
                offersRingModes: offersRingModes, offersModeJumps: offersModeJumps,
                recordRequestToken: centerToken(center))
            .id(ControlTarget.ringCenter(center))
        }
        touchRingSlotsSection(
            hasMechanicalDial
                ? String(localized: "Dial", comment: "Section header / row label for a mechanical rotate-only dial")
                : String(localized: "Touch Ring", comment: "Section header / row label for touch ring"),
            isActive: rotaryActive(place: 0, lb: lb), showsDiagram: !hasMechanicalDial,
            showsModeBadge: hasMechanicalDial,
            onCenterTap: hasCenterButton ? { bumpCenterToken(center) } : nil,
            centerBinding: !hasCenterButton ? nil : centerBinding(
                center, undoName: String(localized: "Touch Ring Button", comment: "Undo action name: touch ring center-click binding in the Buttons pane")))
    }

    /// The second dial's own "Dial Toggle" row (PTK-670/870), for the dial
    /// you see second. Only ever shown alongside
    /// `touchRingSlotsSection(ring: .secondary)` for `hasMechanicalDial`
    /// devices; capacitive dual-ring hardware (Cintiq 24HD) has no
    /// equivalent second toggle key and never calls this.
    @ViewBuilder
    func dialToggleBlock2(lb: LiveButtonState) -> some View {
        dialToggleRow(
            placed(.ringCenter(1)).index,
            undoName: String(localized: "Dial 2 Toggle", comment: "Undo action name: second dial toggle key binding in the Buttons pane"),
            lb: lb)
    }

    /// The toggle beside strip `place`, which cycles that strip's modes. It
    /// reports in the bezel slot of its side, so its binding lives there.
    @ViewBuilder
    func stripToggleRow(place: Int, lb: LiveButtonState) -> some View {
        let button = placed(.bezel(place)).index
        let label = String(localized: "Strip Toggle", comment: "Row label for the button that cycles a touch strip's modes")
        buttonRow(
            label,
            isActive: lb.bezelButtons[button],
            binding: settings.recordingBinding(
                label,
                get: { settings.bezelButtonBindings[button] },
                set: { newValue in
                    var updated = settings.bezelButtonBindings
                    updated[button] = newValue
                    settings.bezelButtonBindings = updated
                }),
            ringSlotCount: spec?.ringSlotCount ?? 4,
            offersSecondDial: true,
            modeNames: ringModeNames,
            isStripHardware: true,
            placement: rotaryPlacement,
            offersRingModes: offersRingModes,
            recordRequestToken: bezelRecordTokens[button])
        .id(ControlTarget.bezel(button))
    }

    /// The key at the middle of a PTK dial's cluster, which cycles dial
    /// `center`'s modes.
    @ViewBuilder
    func dialToggleRow(_ center: Int, undoName: String, lb: LiveButtonState) -> some View {
        buttonRow(
            String(localized: "Dial Toggle", comment: "Row label for the ExpressKey that cycles a mechanical dial's modes"),
            isActive: centerDown(center, lb: lb),
            binding: centerBinding(center, undoName: undoName),
            ringSlotCount: spec?.ringSlotCount ?? 4,
            modeNames: ringModeNames,
            isMechanicalDialHardware: true,
            dialToggleControl: center == 0 ? .first : .second,
            placement: rotaryPlacement,
            recordRequestToken: centerToken(center))
        .id(ControlTarget.ringCenter(center))
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
        // A strip turned a half turn runs the other way as you see it, so the
        // switch shows the direction as seen. Turning a ring over keeps its
        // direction, so a ring's switch shows the saved value.
        let turnedOver = hasTouchStrips && settings.tabletOrientation.isHalfTurn
        let reversed = settings.reverseRingDirection != turnedOver
        DescribedToggle(
            "Reverse Direction",
            isOn: settings.recordingBinding(
                String(localized: "Ring Direction", comment: "Undo action name: touch ring/dial direction toggle in the Buttons pane"),
                get: { settings.reverseRingDirection != turnedOver },
                set: { settings.reverseRingDirection = $0 != turnedOver }),
            currentIcon: hasTouchStrips
                ? (reversed ? "arrow.up" : "arrow.down")
                : (reversed ? "arrow.counterclockwise" : "arrow.clockwise"),
            current: hasTouchStrips
                ? (reversed ? " Reversed." : " Forward.")
                : (reversed ? " Counter-clockwise." : " Clockwise."),
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
            ForEach(0..<3, id: \.self) { i in
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                sideHeader(String(localized: "Toggle Buttons", comment: "Section header for the Cintiq 24HD's ring mode keys on one side"), place: 0).appFont(.headline)
                deviceLineUnlessTabletSection
            }
        }

        Section {
            ForEach(3..<8, id: \.self) { i in
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
            }
        } header: {
            sideHeader(String(localized: "Express Keys"), place: 0)
        }

        Section {
            touchRingSlotsSection(String(localized: "Touch Ring", comment: "Section header / row label for touch ring"), isActive: lb.touchRingActive, showsDiagram: true)
        } header: {
            sideHeader(String(localized: "Touch Ring", comment: "Section header / row label for touch ring"), place: 0)
        }

        Section {
            ForEach(8..<11, id: \.self) { i in
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
            }
        } header: {
            sideHeader(String(localized: "Toggle Buttons", comment: "Section header for the Cintiq 24HD's ring mode keys on one side"), place: 1)
        }

        Section {
            ForEach(11..<16, id: \.self) { i in
                expressKeyRow(index: i, label: Self.splitPadKeyLabel(slot: i).label, lb: lb)
            }
        } header: {
            sideHeader(String(localized: "Express Keys"), place: 1)
        }

        Section {
            touchRingSlotsSection(String(localized: "Touch Ring", comment: "Section header / row label for touch ring"), isActive: lb.touchRing2Active, showsDiagram: true)
        } header: {
            sideHeader(String(localized: "Touch Ring", comment: "Section header / row label for touch ring"), place: 1)
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


    /// `index` is the button's place, like `expressKeyRow`'s.
    @ViewBuilder
    func bezelButtonRow(index: Int, label: String, lb: LiveButtonState) -> some View {
        let button = placed(.bezel(index)).index
        buttonRow(
            label,
            isActive: lb.bezelButtons[button],
            binding: settings.recordingBinding(
                String(localized: "Bezel Button \(index + 1)"),
                get: { settings.bezelButtonBindings[button] },
                set: { newValue in
                    var updated = settings.bezelButtonBindings
                    updated[button] = newValue
                    settings.bezelButtonBindings = updated
                }
            ),
            modeNames: ringModeNames,
            placement: rotaryPlacement,
            offersRingModes: offersRingModes, offersModeJumps: offersModeJumps,
            recordRequestToken: bezelRecordTokens[button]
        )
        .id(ControlTarget.bezel(button))
    }

    // MARK: - Express key row helper

    /// `index` is the key's place, numbered as in Landscape; the row edits
    /// whichever key sits there now.
    @ViewBuilder
    func expressKeyRow(index: Int, label: String, lb: LiveButtonState) -> some View {
        let key = placed(.expressKey(index)).index
        buttonRow(
            label,
            isActive: lb.expressKeys[key],
            binding: settings.recordingBinding(
                String(localized: "Express Key \(index + 1)", comment: "Undo action name: express key binding in the Buttons pane"),
                get: { settings.expressKeyBindings[key] },
                set: { newValue in
                    var updated = settings.expressKeyBindings
                    updated[key] = newValue
                    settings.expressKeyBindings = updated
                }
            ),
            ringSlotCount: spec?.ringSlotCount ?? 4,
            offersSecondDial: hasDualRings || hasStripToggles,
            modeNames: ringModeNames, isMechanicalDialHardware: hasMechanicalDial,
            isStripHardware: hasStripToggles,
            placement: rotaryPlacement,
            offersRingModes: offersRingModes, offersModeJumps: offersModeJumps,
            recordRequestToken: keyRecordTokens[key]
        )
        .id(ControlTarget.expressKey(key))
    }

    /// The escape hatch: what a half turn would do to the assignments, done
    /// without turning the tablet, on the settings the pane shows.
    func turnAssignmentsAround() {
        guard let spec, let figure = Self.diagramFigure(for: spec) else { return }
        let orientation = settings.tabletOrientation
        settings.turnAssignmentsAround(
            figure.turnCarry(from: orientation, to: orientation.halfTurned,
                             ringLampsTurn: TabletControlMap.ringLampsTurn(spec)))
    }

    // MARK: - Places

    /// The control in `place`'s Landscape place as the tablet sits now. The
    /// pane numbers controls by place, so Key 1 is whichever key sits where
    /// Key 1 does in Landscape. Saved settings stay with the physical control.
    func placed(_ place: ControlTarget) -> ControlTarget { placedControls[place] ?? place }

    private var placedControls: [ControlTarget: ControlTarget] {
        guard !isRemote, let spec else { return [:] }
        let key = DiagramFigureKey(productID: spec.productID, orientation: settings.tabletOrientation)
        if let cached = Self.placeMaps[key] { return cached }
        var map: [ControlTarget: ControlTarget] = [:]
        if let figure = Self.diagramFigure(for: spec),
           let seen = figure.landscapeEquivalents(turnedTo: key.orientation) {
            for (control, place) in seen { map[place] = control }
        }
        Self.placeMaps[key] = map
        return map
    }

    private static var placeMaps: [DiagramFigureKey: [ControlTarget: ControlTarget]] = [:]

    /// Ring or dial mode actions belong on this device's own keys when it
    /// has a ring, dial, or strip whose modes MockTab keeps. The ExpressKey
    /// Remote's firmware keeps its own mode, so an action there would leave
    /// its lights out of step.
    var offersRingModes: Bool { !isRemote && (hasTouchRing || hasTouchStrips) }

    /// Jumping straight to a mode, where the hardware's own mode keys pick
    /// a mode each instead of cycling; see `TabletControlMap.modeKeysPickModes`.
    var offersModeJumps: Bool {
        offersRingModes && spec.map { TabletControlMap.modeKeysPickModes(productID: $0.productID) } == true
    }

    /// Rings, dials, and modes named by where they sit now.
    var rotaryPlacement: RotaryPlacement {
        RotaryPlacement(
            tradesRotaries: placed(hasStripToggles ? .strip(0) : hasMechanicalDial ? .dial(0) : .ring(0)).index == 1,
            lampShift: ringLampShift)
    }

    /// Places a ring's lamps have moved as the tablet turns; see
    /// `TabletControlMap.ringLampsTurn`.
    var ringLampShift: Int {
        guard let spec, !isRemote, TabletControlMap.ringLampsTurn(spec) else { return 0 }
        return settings.tabletOrientation.counterclockwiseTurns
    }

    /// Whether ring or dial `place` is turning, or a finger is on it.
    func rotaryActive(place: Int, lb: LiveButtonState) -> Bool {
        let rotary = placed(hasMechanicalDial ? .dial(place) : .ring(place)).index
        return hasMechanicalDial ? dialsTurning[rotary] : rotary == 0 ? lb.touchRingActive : lb.touchRing2Active
    }

    /// `label` with the side of `place` as you see it: left or right, or top
    /// or bottom with the tablet upright. Place 0 reads first.
    func sideTitle(_ label: String, place: Int) -> String {
        switch (settings.tabletOrientation.swapsAxes, place) {
        case (false, 0): return String(localized: "\(label) — Left")
        case (false, _): return String(localized: "\(label) — Right")
        case (true, 0): return String(localized: "\(label) — Top")
        case (true, _): return String(localized: "\(label) — Bottom")
        }
    }

    /// The side of `place` as you see it, as a symbol: left or right, or top
    /// or bottom with the tablet upright. Place 0 reads first.
    func sideSymbol(place: Int) -> Image {
        let name: String
        switch (settings.tabletOrientation.swapsAxes, place) {
        case (false, 0): name = "rectangle.lefthalf.inset.filled"
        case (false, _): name = "rectangle.righthalf.inset.filled"
        case (true, 0): name = "rectangle.tophalf.inset.filled"
        case (true, _): name = "rectangle.bottomhalf.inset.filled"
        }
        return Image(systemName: name)
    }

    /// A section title for one side's controls: the side as a symbol, then
    /// `label`. VoiceOver reads the side in words.
    func sideHeader(_ label: String, place: Int) -> some View {
        HStack(spacing: 6) {
            sideSymbol(place: place)
            Text(label)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sideTitle(label, place: place))
        .accessibilityAddTraits(.isHeader)
    }

    /// The side of `place` as you see it, on its own.
    func sideName(place: Int) -> String {
        switch (settings.tabletOrientation.swapsAxes, place) {
        case (false, 0): return String(localized: "Left", comment: "Left touch strip row label")
        case (false, _): return String(localized: "Right", comment: "Right touch strip row label")
        case (true, 0): return String(localized: "Top", comment: "Top touch strip row label")
        case (true, _): return String(localized: "Bottom", comment: "Bottom touch strip row label")
        }
    }

    /// Center button or dial toggle `center`, 0 or 1, as saved.
    func centerBinding(_ center: Int, undoName: String) -> Binding<ButtonBinding> {
        settings.recordingBinding(
            undoName,
            get: { center == 0 ? settings.touchRingButtonBinding : settings.touchRingButtonBinding2 },
            set: { if center == 0 { settings.touchRingButtonBinding = $0 } else { settings.touchRingButtonBinding2 = $0 } })
    }

    func centerDown(_ center: Int, lb: LiveButtonState) -> Bool {
        center == 0 ? lb.touchRingButtonDown : lb.touchRing2ButtonDown
    }

    func centerToken(_ center: Int) -> Int { center == 0 ? centerRecordToken : dial2RecordToken }

    func bumpCenterToken(_ center: Int) { if center == 0 { centerRecordToken += 1 } else { dial2RecordToken += 1 } }

    // MARK: - Tablet diagram

    /// The tablet drawn in its own section below the pen's, with the device
    /// line the first key section would otherwise carry.
    @ViewBuilder
    func tabletSection(lb: LiveButtonState) -> some View {
        if let figure = tabletDiagramFigure {
            Section {
                TabletDiagramView(figure: figure, lit: diagramLit(lb), enabled: diagramEnabled, onTap: { diagramTap($0) },
                                  onTurnAround: { turnAssignmentsAround() })
                    .frame(maxWidth: .infinity)
                    .frame(height: TabletBezelFrame<EmptyView>.height(settings.tabletOrientation))
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
                    .listRowBackground(Color.clear)
            } header: {
                PaneSectionHeader("Tablet") {
                    DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
                }
            }
        }
    }

    /// The device line for the first key section, unless the tablet section above carries it.
    @ViewBuilder
    var deviceLineUnlessTabletSection: some View {
        if tabletDiagramFigure == nil {
            DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
        }
    }

    /// The tablet as it sits on the desk, turned like the Tablet Area figure.
    var tabletDiagramFigure: TabletFigure? {
        guard let spec else { return nil }
        let key = DiagramFigureKey(productID: spec.productID, orientation: settings.tabletOrientation)
        if let cached = Self.diagramFigures[key] { return cached }
        let figure = Self.diagramFigure(for: spec)?.oriented(key.orientation)
        Self.diagramFigures[key] = .some(figure)
        return figure
    }

    private struct DiagramFigureKey: Hashable {
        let productID: Int
        let orientation: TabletOrientation
    }

    /// Figures by model and orientation, nil for a model without one. A
    /// figure depends on nothing else, so each pane update costs a lookup.
    private static var diagramFigures: [DiagramFigureKey: TabletFigure?] = [:]

    private static func diagramFigure(for spec: TabletSpec) -> TabletFigure? {
        // Other brands' product IDs can match a Wacom model's, so only their own layouts count.
        guard VendorDeviceRegistry.profile(forProductID: spec.productID) == nil
                || TabletLayoutExtras.productIDs.contains(spec.productID),
              spec.maxX > 0, spec.maxY > 0,
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
    /// `singleSidedSection`, `dualSidedSection`, `touchRingBlock`, and
    /// `bezelButtonsSection` show, and the mode lists of rings, dials, and strips.
    var diagramEnabled: UInt64 {
        var bits: UInt64 = 0
        for i in 0..<(hasSplitPadLayout ? 16 : expressKeyCount) { bits |= 1 << UInt64(i) }
        if hasTouchRing && !hasSplitPadLayout && !isRemote { bits |= 1 << UInt64(ControlTarget.ringCenter(0).bit) }
        if hasTouchRing && hasDualRings && hasMechanicalDial && !hasSplitPadLayout {
            bits |= 1 << UInt64(ControlTarget.ringCenter(1).bit)
        }
        for i in 0..<min(bezelButtonCount, 3) { bits |= 1 << UInt64(ControlTarget.bezel(i).bit) }
        if hasStripToggles {
            for i in 0..<2 { bits |= 1 << UInt64(ControlTarget.bezel(i).bit) }
        }
        if hasTouchRing {
            for i in 0..<(hasDualRings ? 2 : 1) {
                bits |= 1 << UInt64((hasMechanicalDial ? ControlTarget.dial(i) : .ring(i)).bit)
            }
        }
        if hasTouchStrips {
            for i in 0..<2 { bits |= 1 << UInt64(ControlTarget.strip(i).bit) }
        }
        return bits
    }

    /// Starts recording in the clicked key's row; a ring, dial, or strip
    /// has no single action, so its click only scrolls. A row scrolled into
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
        case let .bezel(i) where i < bezelRecordTokens.count: bezelRecordTokens[i] += 1
        default: break
        }
    }
}
