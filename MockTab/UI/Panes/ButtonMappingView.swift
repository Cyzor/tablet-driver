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
import SwiftUI

// MARK: - ButtonMappingView

struct ButtonMappingView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isLiveResizing = false

    /// Live button state, zeroed when this window is not key or is live-resizing.
    /// Zeroing during resize stops ~100 Hz tablet events from compounding the
    /// window-geometry invalidations that already occur every resize frame.
    private var liveButtons: LiveButtonState {
        guard controlActiveState == .key, !isLiveResizing else { return LiveButtonState() }
        return tabletManager.liveButtons
    }

    private var tool: ToolSettings { settings.activeTool }

    // Pre-allocated Binding<ToolSettings> — created once, not per body call.
    // Used to derive Binding<ButtonBinding> for each key path so SwiftUI
    // view identity is stable across ~16 Hz liveButtons invalidations.
    private var activeToolBinding: Binding<ToolSettings> {
        $settings.activeTool
    }

    // Pre-allocated touch ring slot bindings — one Binding per slot per direction.
    // Eliminates per-call closure allocation in touchRingSlotsSection during
    // ~16 Hz liveButtons invalidations (same pattern as penNBinding / tipBinding).
    private var slot0CWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(0) else { return .none }
                return self.settings.touchRingSlots[0].cwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(0) else { return }
                var newSlots = oldSlots
                newSlots[0].cwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 1 CW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot0CCWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(0) else { return .none }
                return self.settings.touchRingSlots[0].ccwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(0) else { return }
                var newSlots = oldSlots
                newSlots[0].ccwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 1 CCW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot1CWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(1) else { return .none }
                return self.settings.touchRingSlots[1].cwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(1) else { return }
                var newSlots = oldSlots
                newSlots[1].cwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 2 CW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot1CCWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(1) else { return .none }
                return self.settings.touchRingSlots[1].ccwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(1) else { return }
                var newSlots = oldSlots
                newSlots[1].ccwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 2 CCW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot2CWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(2) else { return .none }
                return self.settings.touchRingSlots[2].cwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(2) else { return }
                var newSlots = oldSlots
                newSlots[2].cwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 3 CW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot2CCWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(2) else { return .none }
                return self.settings.touchRingSlots[2].ccwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(2) else { return }
                var newSlots = oldSlots
                newSlots[2].ccwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 3 CCW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot3CWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(3) else { return .none }
                return self.settings.touchRingSlots[3].cwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(3) else { return }
                var newSlots = oldSlots
                newSlots[3].cwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 4 CW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot3CCWBinding: Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(3) else { return .none }
                return self.settings.touchRingSlots[3].ccwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(3) else { return }
                var newSlots = oldSlots
                newSlots[3].ccwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 4 CCW") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }

    /// Direction for slotBinding(for:direction:).
    private enum SlotDirection { case cw, ccw }

    // Pre-allocated touch ring slot action bindings — one Binding per slot.
    // Eliminates per-call closure allocation in touchRingSlotsSection during
    // ~16 Hz liveButtons invalidations (same pattern as slot0CWBinding etc.).
    private var slot0ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(0) else { return .scroll }
                return self.settings.touchRingSlots[0].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(0) else { return }
                var newSlots = oldSlots
                newSlots[0].action = newAction
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 1 Action") {
                    self.settings.touchRingSlots = oldSlots
                }
            }
        )
    }
    private var slot1ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(1) else { return .scroll }
                return self.settings.touchRingSlots[1].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(1) else { return }
                var newSlots = oldSlots
                newSlots[1].action = newAction
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 2 Action") {
                    self.settings.touchRingSlots = oldSlots
                }
            }
        )
    }
    private var slot2ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(2) else { return .scroll }
                return self.settings.touchRingSlots[2].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(2) else { return }
                var newSlots = oldSlots
                newSlots[2].action = newAction
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 3 Action") {
                    self.settings.touchRingSlots = oldSlots
                }
            }
        )
    }
    private var slot3ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(3) else { return .scroll }
                return self.settings.touchRingSlots[3].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(3) else { return }
                var newSlots = oldSlots
                newSlots[3].action = newAction
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 4 Action") {
                    self.settings.touchRingSlots = oldSlots
                }
            }
        )
    }

    // Pre-allocated touch ring slot speed bindings — one Binding per slot.
    // Eliminates per-call closure allocation during ~16 Hz liveButtons invalidations.
    private var slot0SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(0) else { return 1.0 }
                return self.settings.touchRingSlots[0].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(0) else { return }
                var newSlots = oldSlots
                newSlots[0].speed = newSpeed
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 1 Speed") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot1SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(1) else { return 1.0 }
                return self.settings.touchRingSlots[1].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(1) else { return }
                var newSlots = oldSlots
                newSlots[1].speed = newSpeed
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 2 Speed") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot2SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(2) else { return 1.0 }
                return self.settings.touchRingSlots[2].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(2) else { return }
                var newSlots = oldSlots
                newSlots[2].speed = newSpeed
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 3 Speed") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }
    private var slot3SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(3) else { return 1.0 }
                return self.settings.touchRingSlots[3].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(3) else { return }
                var newSlots = oldSlots
                newSlots[3].speed = newSpeed
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot 4 Speed") { self.settings.touchRingSlots = oldSlots }
            }
        )
    }

    private var pen1Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton1Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton1Binding
                t.wrappedValue.penButton1Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Button 1") {
                    t.wrappedValue.penButton1Binding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    private var pen2Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton2Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton2Binding
                t.wrappedValue.penButton2Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Button 2") {
                    t.wrappedValue.penButton2Binding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    private var pen3Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton3Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton3Binding
                t.wrappedValue.penButton3Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Button 3") {
                    t.wrappedValue.penButton3Binding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    private var pen4Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton4Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton4Binding
                t.wrappedValue.penButton4Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Button 4") {
                    t.wrappedValue.penButton4Binding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    private var pen5Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton5Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton5Binding
                t.wrappedValue.penButton5Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Button 5") {
                    t.wrappedValue.penButton5Binding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    private var tipBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.tipBinding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.tipBinding
                t.wrappedValue.tipBinding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Tip Button") {
                    t.wrappedValue.tipBinding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    private var eraserBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.eraserBinding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.eraserBinding
                t.wrappedValue.eraserBinding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Eraser Button") {
                    t.wrappedValue.eraserBinding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    private var wheelBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.wheelBinding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.wheelBinding
                t.wrappedValue.wheelBinding = newValue
                self.settings.objectWillChange.send()
                self.settings.record("Wheel") {
                    t.wrappedValue.wheelBinding = oldValue
                    self.settings.objectWillChange.send()
                }
            }
        )
    }

    // MARK: - Touch ring slot helpers

    /// Array index → slot action binding (pre-allocated stored properties survive
    /// ~16 Hz liveButtons invalidations in touchRingSlotsSection).
    private func slotBinding(at index: Int) -> Binding<ControlSlot.Action> {
        switch index {
        case 0: return slot0ActionBinding
        case 1: return slot1ActionBinding
        case 2: return slot2ActionBinding
        case 3: return slot3ActionBinding
        default: return Binding(get: { .scroll }, set: { _ in })
        }
    }

    /// Array index → pre-allocated speed binding for touch ring slot.
    private func slotSpeedBinding(at index: Int) -> Binding<Double> {
        switch index {
        case 0: return slot0SpeedBinding
        case 1: return slot1SpeedBinding
        case 2: return slot2SpeedBinding
        case 3: return slot3SpeedBinding
        default: return Binding(get: { 1.0 }, set: { _ in })
        }
    }

    /// Index → pre-allocated CW/CCW binding for touch ring slot.
    /// Called from touchRingSlotsSection only; the pre-allocated stored
    /// properties (slot0CWBinding etc.) survive ~16 Hz liveButtons invalidations.
    private func slotBinding(for index: Int, direction: SlotDirection) -> Binding<ButtonBinding> {
        switch (index, direction) {
        case (0, .cw): return slot0CWBinding
        case (0, .ccw): return slot0CCWBinding
        case (1, .cw): return slot1CWBinding
        case (1, .ccw): return slot1CCWBinding
        case (2, .cw): return slot2CWBinding
        case (2, .ccw): return slot2CCWBinding
        case (3, .cw): return slot3CWBinding
        case (3, .ccw): return slot3CCWBinding
        default: return Binding(get: { .none }, set: { _ in })
        }
    }

    /// Array index → CW rotation binding (used when action == .keyPress).
    private func slotCWBinding(at index: Int) -> Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(index) else { return .none }
                return self.settings.touchRingSlots[index].cwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(index) else { return }
                var newSlots = oldSlots
                newSlots[index].cwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot \(index + 1) CW") {
                    self.settings.touchRingSlots = oldSlots
                }
            }
        )
    }

    /// Array index → CCW rotation binding (used when action == .keyPress).
    private func slotCCWBinding(at index: Int) -> Binding<ButtonBinding> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(index) else { return .none }
                return self.settings.touchRingSlots[index].ccwBinding
            },
            set: { newBinding in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(index) else { return }
                var newSlots = oldSlots
                newSlots[index].ccwBinding = newBinding
                self.settings.touchRingSlots = newSlots
                self.settings.record("Ring Slot \(index + 1) CCW") {
                    self.settings.touchRingSlots = oldSlots
                }
            }
        )
    }

    private var spec: WacomDeviceSpec? {
        productID.flatMap { WacomDeviceRegistry.spec(for: $0) }
    }

    private var activeToolSpec: WacomToolSpec? {
        guard let productID, let ctx = tabletManager.contexts[productID] else { return nil }
        return WacomToolCatalog.spec(forToolCode: ctx.activeToolCode)
    }

    private var hasTouchRing: Bool { spec?.hasTouchRing == true }
    private var hasDualRings: Bool { spec?.hasDualRings == true }
    private var hasTouchStrips: Bool { spec?.hasTouchStrips == true }

    // MARK: - Recording Binding Helper

    /// Creates a binding that automatically registers undo for any change.
    /// The `owner` should be the object that has the undoManager (tool or settings).
    private func recordingBinding<T>(
        _ name: String,
        owner: AnyObject,
        get: @escaping () -> T,
        set: @escaping (T) -> Void
    ) -> Binding<T> {
        // Always register undo against settings — its undoManager is reliably wired
        // by SettingsWindowController.  Routing through toolOwner.record() silently
        // failed whenever tool.undoManager was nil (e.g. before proximity entry).
        // ToolSettings mutations don't propagate to settings.objectWillChange
        // automatically, so send explicitly for tool-owned bindings.
        let settings = self.settings
        let isToolOwned = owner is ToolSettings
        return Binding(
            get: get,
            set: { newValue in
                let oldValue = get()
                set(newValue)
                if isToolOwned { settings.objectWillChange.send() }
                settings.record(name) {
                    set(oldValue)
                    if isToolOwned { settings.objectWillChange.send() }
                }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            AppOverrideBar(
                settings: settings, domainKeys: AppOverrideBar.buttonKeys, productID: productID)
            Form {
                penButtonsSection(lb: liveButtons)
                if hasDualRings {
                    dualSidedSection(lb: liveButtons)
                } else {
                    singleSidedSection(lb: liveButtons)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            DeviceStatusBar(
                settings: settings, tabletManager: tabletManager, registry: registry,
                productID: productID ?? 0)
        }
        .background(
            LiveResizeDetector(isResizing: $isLiveResizing)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Pen buttons section

    @ViewBuilder
    private func penButtonsSection(lb: LiveButtonState) -> some View {
        let toolSpec = activeToolSpec
        let isMouse = toolSpec?.toolType == .mouse
        // For mice, show all 5 HID-path button slots regardless of spec.buttonCount
        // (spec.buttonCount describes only the digitizer path, not the full HID mouse report)
        let btnCount = isMouse ? 5 : (toolSpec?.buttonCount ?? 2)
        let hasWheel = toolSpec?.hasWheel == true

        Section {
            // Tip — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Tip", comment: "Pen tip button row label in Buttons tab"),
                    isActive: lb.tipDown,
                    binding: tipBinding)
            }

            // Eraser — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Eraser", comment: "Eraser button row label in Buttons tab"),
                    isActive: lb.eraserDown,
                    binding: eraserBinding)
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
                    binding: pen1Binding)
            }
            // Button 2
            if btnCount >= 2 {
                buttonRow(
                    isMouse
                        ? String(localized: "Button 2", comment: "Pen button row label: mouse button 2")
                        : String(localized: "Side button 2", comment: "Pen button row label: second side button"),
                    isActive: lb.button2Down,
                    binding: pen2Binding)
            }
            // Button 3
            if btnCount >= 3 {
                buttonRow(
                    isMouse
                        ? String(localized: "Button 3", comment: "Pen button row label: mouse button 3")
                        : String(localized: "Side button 3", comment: "Pen button row label: third side button"),
                    isActive: lb.button3Down,
                    binding: pen3Binding)
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
            // background shows through unchanged.
            PenDiagramView(liveButtons: lb)
                .equatable()
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 64)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(isMouse ? "Mouse Buttons" : "Pen Buttons"))
                ToolNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }
    }

    // MARK: - Single-sided layout (most tablets)

    @ViewBuilder
    private func singleSidedSection(lb: LiveButtonState) -> some View {
        // DeviceNameLabel heads this section so it sits between the pen section
        // and the hardware button rows, matching the original visual intent.
        Section {
            ForEach(0..<8, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(format: NSLocalizedString("Key %lld", comment: "Express key N label, e.g. 'Key 1'"), i + 1),
                    lb: lb)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Express Keys"))
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }

        if hasTouchRing {
            Section(LocalizedStringKey("Touch Ring")) {
                buttonRow(
                    String(localized: "Center", comment: "Touch ring center button row label"),
                    isActive: lb.touchRingButtonDown,
                    binding: recordingBinding(
                        "Touch Ring Button", owner: settings,
                        get: { settings.touchRingButtonBinding },
                        set: { settings.touchRingButtonBinding = $0 }),
                    ringSlotCount: spec?.ringSlotCount ?? 4)
                touchRingSlotsSection(
                    String(
                        localized: "Touch Ring",
                        comment: "Section header / row label for touch ring"),
                    isActive: lb.touchRingActive)
            }
        }

        if hasTouchStrips {
            Section(LocalizedStringKey("Touch Strips")) {
                touchRingSlotsSection(
                    String(localized: "Left", comment: "Left touch strip row label"),
                    isActive: lb.touchStrip1Active)
                touchRingSlotsSection(
                    String(localized: "Right", comment: "Right touch strip row label"),
                    isActive: lb.touchStrip2Active)
            }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Toggle Buttons — Left"))
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }

        Section(LocalizedStringKey("Express Keys — Left")) {
            ForEach(3..<8, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(format: NSLocalizedString("Key %lld", comment: "Express key N label, e.g. 'Key 1'"), i - 2),
                    lb: lb)
            }
        }

        Section(LocalizedStringKey("Touch Ring — Left")) {
            touchRingSlotsSection(
                String(
                    localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                isActive: lb.touchRingActive)
        }

        Section(LocalizedStringKey("Toggle Buttons — Right")) {
            ForEach(8..<11, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Button \(i - 7)",
                        comment: "Toggle button N label, e.g. 'Button 1'"), lb: lb)
            }
        }

        Section(LocalizedStringKey("Express Keys — Right")) {
            ForEach(11..<16, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(format: NSLocalizedString("Key %lld", comment: "Express key N label, e.g. 'Key 1'"), i - 10),
                    lb: lb)
            }
        }

        Section(LocalizedStringKey("Touch Ring — Right")) {
            touchRingSlotsSection(
                String(
                    localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                isActive: lb.touchRing2Active)
        }
    }

    // MARK: - Express key row helper

    @ViewBuilder
    private func expressKeyRow(index: Int, label: String, lb: LiveButtonState) -> some View {
        buttonRow(
            label,
            isActive: lb.expressKeys[index],
            binding: recordingBinding(
                "Express Key \(index + 1)", owner: settings,
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

    /// Renders the ring/strip slot rows as individual list rows.
    /// Each slot becomes a separate Form row, visually consistent with buttonRow().
    @ViewBuilder
    private func touchRingSlotsSection(
        _ label: String, isActive: Bool
    ) -> some View {
        // Label row — shows "Touch Ring", "Left", or "Right" with live-active indicator.
        HStack(spacing: 6) {
            activeIndicator(isActive)
            labelText(label, isActive: isActive)
            Spacer(minLength: 0)
        }

        // One list row per slot — matches buttonRow() visual language.
        // Show only as many slots as the spec declares (default 4); model always stores 4.
        let slotCount = min(settings.touchRingSlots.count, spec?.ringSlotCount ?? 4)
        let ringSlotCount = spec?.ringSlotCount ?? 4
        ForEach(Array(settings.touchRingSlots.prefix(slotCount).enumerated()), id: \.element.id)
        { idx, slot in
            TouchRingSlotRowView(
                slot: slot,
                idx: idx,
                isActiveSlot: isActive && settings.touchRingActiveSlotIndex == idx,
                ringSlotCount: ringSlotCount,
                actionBinding: slotBinding(at: idx),
                speedBinding: slotSpeedBinding(at: idx),
                cwBinding: slotBinding(for: idx, direction: .cw),
                ccwBinding: slotBinding(for: idx, direction: .ccw)
            )
            .equatable()
        }
    }

    // MARK: - Button binding row

    @ViewBuilder
    private func buttonRow(
        _ label: String, isActive: Bool,
        binding: Binding<ButtonBinding>,
        ringSlotCount: Int = 4
    ) -> some View {
        HStack(spacing: 0) {
            activeIndicator(isActive)
            // Fixed minimum width with trailing alignment so the binding control
            // starts at a consistent x position regardless of label length.
            labelText(label, isActive: isActive)
                .frame(minWidth: 100, alignment: .trailing)
            ButtonBindingControl(binding: binding, ringSlotCount: ringSlotCount)
                .equatable()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shared row subviews

    /// Green checkmark when a hardware button is currently held; invisible
    /// when idle so the label column stays stable without a ghost shape.
    private func activeIndicator(_ isActive: Bool) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.green)
            .imageScale(.small)
            .opacity(isActive ? 1 : 0)
    }

    private func labelText(_ label: String, isActive: Bool) -> some View {
        Text(label)
            .foregroundStyle(Color.primary)
            .fontWeight(isActive ? .semibold : .regular)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(isActive ? 0.12 : 0))
            )
    }

}

// MARK: - Touch ring slot row

/// One row in the touch-ring slot list. Extracted so `.equatable()` can short-circuit
/// body evaluation on resize frames when neither slot data nor active state has changed.
private struct TouchRingSlotRowView: View, Equatable {
    let slot: ControlSlot
    let idx: Int
    let isActiveSlot: Bool
    let ringSlotCount: Int
    let actionBinding: Binding<ControlSlot.Action>
    let speedBinding: Binding<Double>
    let cwBinding: Binding<ButtonBinding>
    let ccwBinding: Binding<ButtonBinding>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.slot == rhs.slot
            && lhs.idx == rhs.idx
            && lhs.isActiveSlot == rhs.isActiveSlot
            && lhs.ringSlotCount == rhs.ringSlotCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .imageScale(.small)
                    .opacity(isActiveSlot ? 1 : 0)
                Text("Mode \(idx + 1)")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 100, alignment: .trailing)
                    .padding(.horizontal, 5)
                Picker("", selection: actionBinding) {
                    ForEach(ControlSlot.Action.allCases, id: \.self) { action in
                        Text(action.displayLabel).tag(action)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()

                if slot.action != .off {
                    let speedLabel = slot.speed < 0.01
                        ? String(
                            localized: "Off",
                            comment: "Ring speed slider at minimum — rotation disabled")
                        : String(format: "%.2g×", slot.speed)
                    Text(speedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                        .padding(.leading, 8)
                    Slider(value: speedBinding, in: 0...3.0, step: 0.25)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .help("Adjust how fast the ring scrolls or repeats key presses.")
                        .padding(.trailing, 40)
                } else {
                    Spacer(minLength: 10)
                }
            }

            if slot.action == .keyPress {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ButtonBindingControl(
                            binding: cwBinding, compact: true,
                            ringSlotCount: ringSlotCount)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ButtonBindingControl(
                            binding: ccwBinding, compact: true,
                            ringSlotCount: ringSlotCount)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - ButtonBindingControl

/// A Bloom-style shortcut recorder control.
/// • Click the field to start recording — press any key combo to bind it.
/// • ESC cancels; Delete alone clears the binding.
/// • Use the ▾ menu to assign click actions instead of a key combo.
/// • The ✕ button clears any existing assignment.
struct ButtonBindingControl: View, Equatable {
    @Binding var binding: ButtonBinding
    var compact: Bool = false
    var ringSlotCount: Int = 4
    @State private var isRecording = false
    @State private var monitor: Any?
    /// Modifier keys accumulated while recording (before any base key is pressed).
    @State private var pendingModifiers: NSEvent.ModifierFlags = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.binding == rhs.binding
            && lhs.compact == rhs.compact
            && lhs.ringSlotCount == rhs.ringSlotCount
    }

    var body: some View {
        // Cached once per body call — prevents String(localized:) + CGEventFlags
        // set ops in displayLabel from firing on every SwiftUI invalidation.
        let displayText = binding.displayLabel
        HStack(spacing: 4) {
            // Recording field
            Button(action: toggleRecording) {
                HStack {
                    Text(displayText)
                        .foregroundStyle(fieldTextColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(minWidth: compact ? 60 : 140, maxWidth: compact ? 120 : .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(fieldBackground)
            .help(
                LocalizedStringKey(
                    "Click to record a keyboard shortcut. Press Escape to cancel or Delete to clear. Use the ▾ menu to assign a click action."
                ))

            // Clear button
            if binding.kind != .none && !isRecording {
                Button {
                    binding = .none
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Clear this button assignment.")
            }

            // Click-action picker
            clickMenu
        }
        .onDisappear { if isRecording { stopRecording() } }
    }

    // MARK: - Menu

    /// Lazy menu — allocated once per ButtonBindingControl instance, not per body call.
    /// Uses direct binding assignments instead of set() to avoid retain cycles.
    private var clickMenu: some View {
        Menu {
            Button("Left Click") { binding = ButtonBinding(kind: .leftClick) }
                .help("Primary mouse button (used for drawing and selecting)")
            Button("Right Click") { binding = ButtonBinding(kind: .rightClick) }
                .help("Secondary mouse button (context menus)")
            Button("Middle Click") { binding = ButtonBinding(kind: .middleClick) }
                .help("Middle mouse button (panning in many apps)")
            Button("Middle Click + Tip") { binding = ButtonBinding(kind: .middleClickWithTip) }
                .help("Middle click only when pen tip is in contact")
            Button("Double Click") { binding = ButtonBinding(kind: .doubleClick) }
                .help("Two rapid clicks in succession")
            Button("Eraser") { binding = ButtonBinding(kind: .eraser) }
                .help("Eraser tool (pressure-sensitive in drawing apps)")
            Divider()
            Button("Spacebar") { binding = ButtonBinding(kind: .spacebar) }
                .help("Spacebar key (hand-tool in many design apps)")
            Button("Toggle Display") { binding = ButtonBinding(kind: .displayToggle) }
                .help("Switch tablet mapping between displays")
            Menu("Touch Ring Mode") {
                Button("Cycle") { binding = ButtonBinding(kind: .ringCycle) }
                    .help("Cycle through ring modes")
                Divider()
                ForEach(0..<ringSlotCount, id: \.self) { i in
                    Button("Jump to Mode \(i + 1)") {
                        binding = ButtonBinding(kind: .ringSelectSlot, keyCode: UInt16(i))
                    }
                    .help("Switch ring directly to mode \(i + 1)")
                }
            }
            Divider()
            Button("⌘ Command") { binding = ButtonBinding(modifierOnly: .command) }
                .help("Hold Command modifier (⌘)")
            Button("⌥ Option") { binding = ButtonBinding(modifierOnly: .option) }
                .help("Hold Option modifier (⌥)")
            Button("⇧ Shift") { binding = ButtonBinding(modifierOnly: .shift) }
                .help("Hold Shift modifier (⇧)")
            Button("⌃ Control") { binding = ButtonBinding(modifierOnly: .control) }
                .help("Hold Control modifier (⌃)")
            Divider()
            Button("None") { binding = .none }
                .help("Disable this button")
        } label: {
            Image(systemName: "ellipsis")
                .font(.settingsBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help(
            "Assign a click action: left-click, right-click, middle-click, modifier keys, or display toggle."
        )
    }

    // MARK: - Visual state

    private var fieldText: String {
        if isRecording {
            return pendingModifiers.isEmpty
                ? String(
                    localized: "Type shortcut\u{2026}",
                    comment: "Placeholder in shortcut recorder field while recording")
                : modifierGlyphs(pendingModifiers) + "…"
        }
        if binding.kind == .none {
            return String(
                localized: "Record Shortcut",
                comment: "Placeholder in shortcut recorder field when empty")
        }
        return binding.displayLabel
    }

    /// Modifier key symbols in standard macOS display order (⌃⌥⇧⌘).
    private func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private var fieldTextColor: Color {
        if isRecording { return .accentColor }
        if binding.kind == .none { return .secondary }
        return .primary
    }

    @ViewBuilder private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                isRecording
                    ? Color.accentColor.opacity(0.07)
                    : Color(NSColor.controlBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isRecording ? Color.accentColor : Color(NSColor.separatorColor),
                        lineWidth: 1
                    )
            )
    }

    // MARK: - Actions

    private func set(_ kind: ButtonBinding.Kind) {
        stopRecording()
        binding = ButtonBinding(kind: kind)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        pendingModifiers = []
        // Monitor both keyDown (regular keys) and flagsChanged (modifier-only presses).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .flagsChanged: self.handleFlagsChanged(event)
            default: self.handleKey(event)
            }
            return nil  // consume — prevents the key from reaching any other responder
        }
    }

    private func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isRecording = false
        pendingModifiers = []
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let current = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
        if current.isEmpty {
            // Every modifier key has been released.
            guard !pendingModifiers.isEmpty else { return }
            binding = ButtonBinding(modifierOnly: pendingModifiers)
            stopRecording()
        } else {
            // Accumulate — releasing one modifier of a combo (e.g. ⌘ before ⇧)
            // must not lose the earlier modifier from the committed set.
            pendingModifiers.formUnion(current)
        }
    }

    private func handleKey(_ event: NSEvent) {
        let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 && bare.isEmpty {
            // ESC alone → cancel without changing the binding
        } else if event.keyCode == 51 && bare.isEmpty {
            // Delete alone → clear
            binding = .none
        } else {
            binding = ButtonBinding(fromKey: event)
        }
        stopRecording()
    }
}

// MARK: - LiveResizeDetector

/// Zero-size NSViewRepresentable that bridges NSView live-resize callbacks into
/// SwiftUI @State. Scoped to the view's own window — fires only when that window
/// is being resized, not when any other window resizes.
private struct LiveResizeDetector: NSViewRepresentable {
    @Binding var isResizing: Bool

    func makeNSView(context: Context) -> TrackingView { TrackingView(binding: $isResizing) }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) {
            self.binding = binding
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            DispatchQueue.main.async { self.binding.wrappedValue = true }
        }
        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            DispatchQueue.main.async { self.binding.wrappedValue = false }
        }
    }
}
