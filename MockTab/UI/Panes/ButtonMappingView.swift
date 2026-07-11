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
    var productID: Int?

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isLiveResizing = false

    /// Live button state, zeroed when this window is not key or is live-resizing.
    /// Zeroing during resize stops ~100 Hz tablet events from compounding the
    /// window-geometry invalidations that already occur every resize frame.
    private var liveButtons: LiveButtonState {
        guard controlActiveState == .key, !isLiveResizing else { return LiveButtonState() }
        let context = productID.flatMap { tabletManager.contexts[$0] }
            ?? tabletManager.activeContext
        return context?.liveButtons ?? LiveButtonState()
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
        guard let pid = productID else { return nil }
        // Most devices are in the registry keyed by their own PID.
        // The ACK-40401 wireless dongle's own registry entry is a
        // name-only placeholder (maxX/maxY/buttonCount all 0) — skip it
        // and fall back to the paired tablet's PID reported over the RF
        // link instead of showing an empty Buttons pane.
        if let s = WacomDeviceRegistry.spec(for: pid), s.maxX > 0 { return s }
        if let ctx = tabletManager.contexts[pid], ctx.pairedProductID > 0 {
            return WacomDeviceRegistry.spec(for: ctx.pairedProductID)
        }
        // Non-Wacom drivable devices (Xencelabs) aren't in WacomDeviceRegistry
        // at all — synthesize the same spec shape TabletManager attached the
        // live driver with.
        if let ctx = tabletManager.contexts[pid] {
            return TabletManager.vendorDeviceSpec(forVendorID: ctx.vendorID, productID: pid)
        }
        return nil
    }

    private var activeToolSpec: WacomToolSpec? {
        guard let productID, let ctx = tabletManager.contexts[productID] else { return nil }
        return WacomToolCatalog.spec(forToolCode: ctx.activeToolCode)
    }

    private var hasTouchRing: Bool { spec?.hasTouchRing == true }
    private var hasDualRings: Bool { spec?.hasDualRings == true }
    private var hasTouchStrips: Bool { spec?.hasTouchStrips == true }

    // MARK: - Companion peripheral (e.g. Xencelabs Quick Keys puck/dongle)

    /// PID of a connected aux-only companion peripheral for this tablet
    /// (currently only the Xencelabs Quick Keys puck/dongle), or nil if
    /// none is connected. Resolved live from `VendorDeviceRegistry`'s
    /// static companion hint plus which devices are actually connected —
    /// see `VendorDeviceRegistry.connectedCompanion`.
    private var companionProductID: Int? {
        guard let pid = productID else { return nil }
        return VendorDeviceRegistry.connectedCompanion(
            forProductID: pid, connectedProductIDs: tabletManager.connectedProductIDs)
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
    /// Driven by the active device spec so PTK-670/870 (10 keys) and DTU
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
            productID: productID, overrideKeys: AppOverrideBar.buttonKeys
        ) {
            // Aux-only devices (Quick Keys puck/dongle) have no pen digitizer,
            // so the pen-buttons section is structurally inapplicable — and
            // instead of the generic express-key/ring layout they get the
            // exact same Quick Keys content that quickKeysSection folds into
            // a tablet's window, just fed from this window's own settings and
            // live state. One component, identical look and behavior (LED
            // color wells included) wherever the puck's controls appear.
            if spec?.parser == .xencelabs && spec?.maxX == 0 {
                quickKeysContent(settings, qkSpec: spec, lb: liveButtons)
            } else {
                penButtonsSection(lb: liveButtons)
                if hasDualRings {
                    dualSidedSection(lb: liveButtons)
                } else {
                    singleSidedSection(lb: liveButtons)
                }
            }
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
            PaneSectionHeader(isMouse ? "Mouse Buttons" : "Pen Buttons") {
                ToolNameLabel(tabletManager: tabletManager, registry: registry, productID: productID)
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
                    DeviceNameLabel(tabletManager: tabletManager, registry: registry, productID: productID)
                }
            }
        }

        if hasTouchRing {
            Section("Touch Ring") {
                buttonRow(
                    String(localized: "Center", comment: "Touch ring center button row label"),
                    isActive: lb.touchRingButtonDown,
                    binding: settings.recordingBinding(
                        "Touch Ring Button",
                        get: { settings.touchRingButtonBinding },
                        set: { settings.touchRingButtonBinding = $0 }),
                    ringSlotCount: spec?.ringSlotCount ?? 4)
                touchRingSlotsSection(
                    String(
                        localized: "Touch Ring",
                        comment: "Section header / row label for touch ring"),
                    isActive: lb.touchRingActive)
                touchRingDiagramRow
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
            }
        }

        quickKeysSection()
    }

    // MARK: - Companion "Quick Keys" section

    /// Express keys + dial for a connected companion puck/dongle, folded
    /// into the tablet's own Buttons pane instead of the companion getting
    /// a window (and settings) of its own — see `companionProductID`.
    /// Bindings read/write the companion's *own* `TabletSettings` instance
    /// (its own `DeviceContext`, keyed by its own PID), not the tablet's —
    /// each physical device keeps its own independent binding storage,
    /// exactly as if the companion still had its own pane; only the window
    /// is merged.
    @ViewBuilder
    private func quickKeysSection() -> some View {
        if let companionSettings = companionContext?.settings {
            quickKeysContent(companionSettings, qkSpec: companionSpec, lb: companionLiveButtons)
        }
    }

    /// The Quick Keys UI itself, parameterized on whose settings/spec/live
    /// state it renders: the companion's (folded into a tablet's window via
    /// `quickKeysSection`) or this window's own (the puck's standalone
    /// window). Keeps the puck's controls — including the dial-LED color
    /// wells — identical wherever they appear.
    @ViewBuilder
    private func quickKeysContent(
        _ companionSettings: TabletSettings, qkSpec: WacomDeviceSpec?, lb: LiveButtonState
    ) -> some View {
        let keyCount = min(max(qkSpec?.buttonCount ?? 8, 0) - 1, 16)

        Section("Quick Keys") {
                ForEach(0..<max(keyCount, 0), id: \.self) { i in
                    buttonRow(
                        String(localized: "Key \(i + 1)", comment: "Quick Keys express key N label"),
                        isActive: lb.expressKeys[i],
                        binding: companionSettings.recordingBinding(
                            "Quick Keys Key \(i + 1)",
                            get: { companionSettings.expressKeyBindings[i] },
                            set: { newValue in
                                var updated = companionSettings.expressKeyBindings
                                updated[i] = newValue
                                companionSettings.expressKeyBindings = updated
                            }
                        ))
                }
                // The bottom mode button rides the same indexed express-key
                // array as the last slot (buttons[8] in AuxButtons — see
                // XencelabsDecoder.decodeAux).
                buttonRow(
                    String(localized: "Mode", comment: "Quick Keys bottom mode button label"),
                    isActive: lb.expressKeys[keyCount],
                    binding: companionSettings.recordingBinding(
                        "Quick Keys Mode Button",
                        get: { companionSettings.expressKeyBindings[keyCount] },
                        set: { newValue in
                            var updated = companionSettings.expressKeyBindings
                            updated[keyCount] = newValue
                            companionSettings.expressKeyBindings = updated
                        }
                    ))
                // Dial center click — reuses the touch-ring center-button
                // slot, mirroring how XencelabsDecoder reports it via
                // AuxButtons.touchRingButtonDown rather than an indexed key.
                buttonRow(
                    String(localized: "Dial", comment: "Quick Keys dial center-click row label"),
                    isActive: lb.touchRingButtonDown,
                    binding: companionSettings.recordingBinding(
                        "Quick Keys Dial Button",
                        get: { companionSettings.touchRingButtonBinding },
                        set: { companionSettings.touchRingButtonBinding = $0 }
                    ))
                // Dial rotation (CW/CCW detents) — same ControlSlot model
                // used by a real touch ring; not pre-allocated per-property
                // like the tablet's own ring bindings above since this pane
                // renders far less often (rendered only while a companion is
                // connected, one Section, no independent hot redraw path).
                let ringSlotCount = qkSpec?.ringSlotCount ?? 4
                let slotCount = min(companionSettings.touchRingSlots.count, ringSlotCount)
                ForEach(
                    Array(companionSettings.touchRingSlots.prefix(slotCount).enumerated()),
                    id: \.element.id
                ) { idx, slot in
                    TouchRingSlotRowView(
                        slot: slot,
                        idx: idx,
                        isActiveSlot: false,
                        ringSlotCount: ringSlotCount,
                        actionBinding: companionSlotActionBinding(companionSettings, at: idx),
                        speedBinding: companionSlotSpeedBinding(companionSettings, at: idx),
                        cwBinding: companionSlotBinding(companionSettings, at: idx, direction: .cw),
                        ccwBinding: companionSlotBinding(companionSettings, at: idx, direction: .ccw),
                        colorBinding: companionSlotColorBinding(companionSettings, at: idx)
                    )
                    .equatable()
                }
                companionTouchRingDiagramRow(
                    companionSettings, ringSlotCount: ringSlotCount,
                    centerDown: lb.touchRingButtonDown)
        }
    }

    /// Companion-scoped counterpart to `touchRingDiagramRow`, reading the
    /// puck/dongle's own settings and live state instead of the tablet's.
    private func companionTouchRingDiagramRow(
        _ companionSettings: TabletSettings, ringSlotCount: Int, centerDown: Bool
    ) -> some View {
        TouchRingDiagramView(
            activeSlotIndex: companionSettings.touchRingActiveSlotIndex,
            centerDown: centerDown,
            slotCount: ringSlotCount
        )
        .equatable()
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 140)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private func companionSlotActionBinding(
        _ companionSettings: TabletSettings, at index: Int
    ) -> Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard companionSettings.touchRingSlots.indices.contains(index) else { return .scroll }
                return companionSettings.touchRingSlots[index].action
            },
            set: { newValue in
                guard companionSettings.touchRingSlots.indices.contains(index) else { return }
                var updated = companionSettings.touchRingSlots
                updated[index].action = newValue
                companionSettings.touchRingSlots = updated
            }
        )
    }

    private func companionSlotSpeedBinding(
        _ companionSettings: TabletSettings, at index: Int
    ) -> Binding<Double> {
        Binding(
            get: {
                guard companionSettings.touchRingSlots.indices.contains(index) else { return 1.0 }
                return companionSettings.touchRingSlots[index].speed
            },
            set: { newValue in
                guard companionSettings.touchRingSlots.indices.contains(index) else { return }
                var updated = companionSettings.touchRingSlots
                updated[index].speed = newValue
                companionSettings.touchRingSlots = updated
            }
        )
    }

    private func companionSlotBinding(
        _ companionSettings: TabletSettings, at index: Int, direction: SlotDirection
    ) -> Binding<ButtonBinding> {
        Binding(
            get: {
                guard companionSettings.touchRingSlots.indices.contains(index) else { return .none }
                let slot = companionSettings.touchRingSlots[index]
                return direction == .cw ? slot.cwBinding : slot.ccwBinding
            },
            set: { newValue in
                guard companionSettings.touchRingSlots.indices.contains(index) else { return }
                var updated = companionSettings.touchRingSlots
                if direction == .cw { updated[index].cwBinding = newValue }
                else { updated[index].ccwBinding = newValue }
                companionSettings.touchRingSlots = updated
            }
        )
    }

    /// Coalesces a burst of color-wheel updates into one undo entry, registered
    /// once the wheel goes quiet — the system color panel fires the binding
    /// continuously during a drag, and only the finished designation is worth
    /// an undo step (TextEdit-style). Reference type so the snapshot and timer
    /// survive view re-renders; @State preserves the instance.
    private final class DialColorUndoCoalescer {
        private var snapshot: [ControlSlot]?
        private var pending: DispatchWorkItem?

        func noteChange(settings: TabletSettings, before slots: [ControlSlot]) {
            if snapshot == nil { snapshot = slots }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak settings] in
                MainActor.assumeIsolated {
                    guard let self, let settings, let snap = self.snapshot else { return }
                    self.snapshot = nil
                    settings.record("Dial Color") { settings.touchRingSlots = snap }
                }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    @State private var dialColorUndo = DialColorUndoCoalescer()

    /// Dial-LED color for one mode slot, bridged to SwiftUI Color. Reads the
    /// stored custom color or the factory palette default; writes store raw
    /// sRGB bytes (no LED calibration — close enough to tell modes apart).
    /// The panel's opacity slider doubles as LED brightness: it's stored as
    /// the alpha and premultiplied into the RGB when pushed to the device,
    /// exactly how the vendor stack scales brightness.
    private func companionSlotColorBinding(
        _ companionSettings: TabletSettings, at index: Int
    ) -> Binding<Color> {
        Binding(
            get: {
                let defaults = XencelabsControl.defaultSlotColors
                let d = defaults[((index % defaults.count) + defaults.count) % defaults.count]
                let c = companionSettings.touchRingSlots.indices.contains(index)
                    ? companionSettings.touchRingSlots[index].ledColor : nil
                let (r, g, b, a) = c.map { ($0.r, $0.g, $0.b, $0.a) } ?? (d.r, d.g, d.b, 255)
                return Color(
                    red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255,
                    opacity: Double(a) / 255)
            },
            set: { newValue in
                guard companionSettings.touchRingSlots.indices.contains(index),
                      let rgb = NSColor(newValue).usingColorSpace(.sRGB)
                else { return }
                dialColorUndo.noteChange(
                    settings: companionSettings,
                    before: companionSettings.touchRingSlots)
                var updated = companionSettings.touchRingSlots
                updated[index].ledColor = ControlSlot.LEDColor(
                    r: UInt8((rgb.redComponent * 255).rounded()),
                    g: UInt8((rgb.greenComponent * 255).rounded()),
                    b: UInt8((rgb.blueComponent * 255).rounded()),
                    a: UInt8((rgb.alphaComponent * 255).rounded()))
                companionSettings.touchRingSlots = updated
            }
        )
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
                DeviceNameLabel(tabletManager: tabletManager, registry: registry, productID: productID)
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
                isActive: lb.touchRingActive)
            touchRingDiagramRow
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
                isActive: lb.touchRing2Active)
            touchRingDiagramRow
        }
    }

    // MARK: - Express key row helper

    @ViewBuilder
    private func expressKeyRow(index: Int, label: String, lb: LiveButtonState) -> some View {
        buttonRow(
            label,
            isActive: lb.expressKeys[index],
            binding: settings.recordingBinding(
                "Express Key \(index + 1)",
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

    // MARK: - Touch ring diagram row

    /// Schematic ring graphic, mirrored visual treatment of PenDiagramView.
    /// Equatable inputs (activeSlotIndex + centerDown + slotCount) ensure the
    /// row short-circuits during ~16 Hz liveButtons invalidations.
    private var touchRingDiagramRow: some View {
        TouchRingDiagramView(
            activeSlotIndex: settings.touchRingActiveSlotIndex,
            centerDown: liveButtons.touchRingButtonDown,
            slotCount: spec?.ringSlotCount ?? 4
        )
        .equatable()
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 140)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
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
                .scaledFrame(minWidth: 100, alignment: .trailing)
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
            .accessibilityHidden(true)
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
    /// Dial-LED color for this mode slot; nil (all Wacom call sites) hides
    /// the color well entirely. Xencelabs Quick Keys only.
    var colorBinding: Binding<Color>? = nil

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
                    .accessibilityHidden(true)
                Text("Mode \(idx + 1)")
                    .foregroundStyle(.secondary)
                    .scaledFrame(minWidth: 100, alignment: .trailing)
                    .padding(.horizontal, 5)
                Picker("", selection: actionBinding) {
                    ForEach(ControlSlot.Action.allCases, id: \.self) { action in
                        Text(action.displayLabel).tag(action)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()

                if slot.action != .off && slot.action != .skip {
                    let speedLabel = slot.speed < 0.01
                        ? String(
                            localized: "Off",
                            comment: "Ring speed slider at minimum — rotation disabled")
                        : String(format: "%.2g×", slot.speed)
                    Text(speedLabel)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .scaledFrame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                        .padding(.leading, 8)
                    Slider(value: speedBinding, in: 0...3.0, step: 0.25)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .help("Adjust how fast the ring scrolls or repeats key presses.")
                        .padding(.trailing, colorBinding == nil ? 40 : 12)
                } else {
                    Spacer(minLength: 10)
                }

                if let colorBinding {
                    // Standard macOS color well → system color panel,
                    // TextEdit-style. Sets the dial's LED for this mode; the
                    // panel's opacity slider doubles as LED brightness.
                    // Trailing-edge placement after the flexible slider/spacer
                    // keeps every row's well on one vertical line — inline
                    // placement next to the action picker made them wander
                    // with the picker's width.
                    ColorPicker("", selection: colorBinding, supportsOpacity: true)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        .padding(.trailing, 40)
                        .help("Dial LED color and brightness while this mode is active.")
                        .accessibilityLabel("Dial LED color")
                }
            }

            if slot.action == .keyPress {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clockwise")
                        ButtonBindingControl(
                            binding: cwBinding, compact: true,
                            ringSlotCount: ringSlotCount)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Counter-clockwise")
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
    /// Set by the left-mouse-down monitor so toggleRecording() knows the
    /// click that fired the button action was the same one that already
    /// stopped recording — and should not restart it.
    @State private var stoppedByMouseDown = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.binding == rhs.binding
            && lhs.compact == rhs.compact
            && lhs.ringSlotCount == rhs.ringSlotCount
    }

    var body: some View {
        // Cached once per body call — prevents String(localized:) + CGEventFlags
        // set ops in displayLabel from firing on every SwiftUI invalidation.
        // fieldText adds recording-state placeholder text on top of displayLabel.
        let displayText = fieldText
        HStack(spacing: 4) {
            // Recording field
            Button(action: toggleRecording) {
                HStack {
                    Text(displayText)
                        .foregroundStyle(fieldTextColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minWidth: compact ? 60 : 140, maxWidth: compact ? 120 : .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(fieldBackground)
            .help(
                "Click to record a keyboard shortcut. Press Escape to cancel or Delete to clear. Use the ▾ menu to assign a click action.")

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
                .accessibilityLabel("Clear button assignment")
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
            Button("Escape") {
                binding = ButtonBinding(kind: .keyCombo, keyCode: 53, modifierFlags: 0, keyLabel: "⎋")
            }
            .help("Escape key")
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
                .appFont(.settingsBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help(
            "Assign a click action: left-click, right-click, middle-click, modifier keys, or display toggle."
        )
        .accessibilityLabel("Click action menu")
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
        // The left-mouse-down monitor already stopped recording on the mouse-down
        // event that caused this button action to fire. Don't restart — the user
        // clicked this field to dismiss, not to begin a new recording.
        if stoppedByMouseDown {
            stoppedByMouseDown = false
            return
        }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stoppedByMouseDown = false
        isRecording = true
        pendingModifiers = []
        // Monitor keyDown and flagsChanged (keyboard input) plus leftMouseDown.
        // leftMouseDown is passed through (return event) so the click reaches its
        // target — which may be another field that then starts its own recording,
        // naturally enforcing single-field mutual exclusion without coordination.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown]
        ) { event in
            switch event.type {
            case .flagsChanged:
                self.handleFlagsChanged(event)
                return nil
            case .leftMouseDown:
                self.stoppedByMouseDown = true
                self.stopRecording()
                return event  // pass through — click reaches its target
            default:
                self.handleKey(event)
                return nil
            }
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
