// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

// Binding<T> accessors for ButtonMappingView's rows: touch ring slot
// direction/action/speed, and pen/tip/eraser/wheel. Split out from the main
// file because it's mechanical boilerplate, not view logic — every property
// here is a pure get/set closure over `settings`, pre-allocated as a stored
// property (rather than built fresh per call) so SwiftUI view identity
// stays stable across the ~16 Hz liveButtons invalidations that redraw
// these rows.
extension ButtonMappingView {
    // Pre-allocated Binding<ToolSettings> — created once, not per body call.
    // Used to derive Binding<ButtonBinding> for each key path so SwiftUI
    // view identity is stable across ~16 Hz liveButtons invalidations.
    var activeToolBinding: Binding<ToolSettings> {
        $settings.activeTool
    }

    // Pre-allocated touch ring slot bindings — one Binding per slot per direction.
    // Eliminates per-call closure allocation in touchRingSlotsSection during
    // ~16 Hz liveButtons invalidations (same pattern as penNBinding / tipBinding).
    var slot0CWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 1 CW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot0CCWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 1 CCW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot1CWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 2 CW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot1CCWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 2 CCW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot2CWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 3 CW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot2CCWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 3 CCW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot3CWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 4 CW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot3CCWBinding: Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot 4 CCW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }

    /// Direction for slotBinding(for:direction:).
    enum SlotDirection { case cw, ccw }

    // Pre-allocated touch ring slot action bindings — one Binding per slot.
    // Eliminates per-call closure allocation in touchRingSlotsSection during
    // ~16 Hz liveButtons invalidations (same pattern as slot0CWBinding etc.).
    var slot0ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(0) else { return .scroll }
                return self.settings.touchRingSlots[0].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(0) else { return }
                var newSlots = oldSlots
                newSlots[0].setAction(newAction)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 1 Action", comment: "Undo action name: touch ring slot action mode in the Buttons pane"), from: oldSlots, to: newSlots) {
                    self.settings.touchRingSlots = $0
                }
            }
        )
    }
    var slot1ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(1) else { return .scroll }
                return self.settings.touchRingSlots[1].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(1) else { return }
                var newSlots = oldSlots
                newSlots[1].setAction(newAction)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 2 Action", comment: "Undo action name: touch ring slot action mode in the Buttons pane"), from: oldSlots, to: newSlots) {
                    self.settings.touchRingSlots = $0
                }
            }
        )
    }
    var slot2ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(2) else { return .scroll }
                return self.settings.touchRingSlots[2].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(2) else { return }
                var newSlots = oldSlots
                newSlots[2].setAction(newAction)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 3 Action", comment: "Undo action name: touch ring slot action mode in the Buttons pane"), from: oldSlots, to: newSlots) {
                    self.settings.touchRingSlots = $0
                }
            }
        )
    }
    var slot3ActionBinding: Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(3) else { return .scroll }
                return self.settings.touchRingSlots[3].action
            },
            set: { newAction in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(3) else { return }
                var newSlots = oldSlots
                newSlots[3].setAction(newAction)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 4 Action", comment: "Undo action name: touch ring slot action mode in the Buttons pane"), from: oldSlots, to: newSlots) {
                    self.settings.touchRingSlots = $0
                }
            }
        )
    }

    // Pre-allocated touch ring slot speed bindings — one Binding per slot.
    // Eliminates per-call closure allocation during ~16 Hz liveButtons invalidations.
    var slot0SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(0) else { return 1.0 }
                return self.settings.touchRingSlots[0].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(0) else { return }
                var newSlots = oldSlots
                newSlots[0].speed = ControlSlot.clampedSpeed(newSpeed, for: newSlots[0].action)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 1 Speed", comment: "Undo action name: touch ring slot rotation speed in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot1SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(1) else { return 1.0 }
                return self.settings.touchRingSlots[1].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(1) else { return }
                var newSlots = oldSlots
                newSlots[1].speed = ControlSlot.clampedSpeed(newSpeed, for: newSlots[1].action)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 2 Speed", comment: "Undo action name: touch ring slot rotation speed in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot2SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(2) else { return 1.0 }
                return self.settings.touchRingSlots[2].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(2) else { return }
                var newSlots = oldSlots
                newSlots[2].speed = ControlSlot.clampedSpeed(newSpeed, for: newSlots[2].action)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 3 Speed", comment: "Undo action name: touch ring slot rotation speed in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }
    var slot3SpeedBinding: Binding<Double> {
        Binding(
            get: {
                guard self.settings.touchRingSlots.indices.contains(3) else { return 1.0 }
                return self.settings.touchRingSlots[3].speed
            },
            set: { newSpeed in
                let oldSlots = self.settings.touchRingSlots
                guard oldSlots.indices.contains(3) else { return }
                var newSlots = oldSlots
                newSlots[3].speed = ControlSlot.clampedSpeed(newSpeed, for: newSlots[3].action)
                self.settings.touchRingSlots = newSlots
                self.settings.recordToggle(String(localized: "Ring Slot 4 Speed", comment: "Undo action name: touch ring slot rotation speed in the Buttons pane"), from: oldSlots, to: newSlots) { self.settings.touchRingSlots = $0 }
            }
        )
    }

    var pen1Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton1Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton1Binding
                t.wrappedValue.penButton1Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Button 1"), from: oldValue, to: newValue) {
                    t.wrappedValue.penButton1Binding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    var pen2Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton2Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton2Binding
                t.wrappedValue.penButton2Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Button 2"), from: oldValue, to: newValue) {
                    t.wrappedValue.penButton2Binding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    var pen3Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton3Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton3Binding
                t.wrappedValue.penButton3Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Button 3"), from: oldValue, to: newValue) {
                    t.wrappedValue.penButton3Binding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    var pen4Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton4Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton4Binding
                t.wrappedValue.penButton4Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Button 4"), from: oldValue, to: newValue) {
                    t.wrappedValue.penButton4Binding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    var pen5Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton5Binding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.penButton5Binding
                t.wrappedValue.penButton5Binding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Button 5"), from: oldValue, to: newValue) {
                    t.wrappedValue.penButton5Binding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    var tipBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.tipBinding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.tipBinding
                t.wrappedValue.tipBinding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Tip Button", comment: "Undo action name: pen/tip/eraser/wheel button binding in the Buttons pane"), from: oldValue, to: newValue) {
                    t.wrappedValue.tipBinding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    var eraserBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.eraserBinding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.eraserBinding
                t.wrappedValue.eraserBinding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Eraser Button", comment: "Undo action name: pen/tip/eraser/wheel button binding in the Buttons pane"), from: oldValue, to: newValue) {
                    t.wrappedValue.eraserBinding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }
    var wheelBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.wheelBinding },
            set: { newValue in
                let t = self.activeToolBinding
                let oldValue = t.wrappedValue.wheelBinding
                t.wrappedValue.wheelBinding = newValue
                self.settings.objectWillChange.send()
                self.settings.recordToggle(String(localized: "Wheel", comment: "Undo action name: pen/tip/eraser/wheel button binding in the Buttons pane"), from: oldValue, to: newValue) {
                    t.wrappedValue.wheelBinding = $0
                    self.settings.objectWillChange.send()
                }
            }
        )
    }

    // MARK: - Touch ring slot helpers

    /// Array index → slot action binding (pre-allocated stored properties survive
    /// ~16 Hz liveButtons invalidations in touchRingSlotsSection).
    func slotBinding(at index: Int) -> Binding<ControlSlot.Action> {
        switch index {
        case 0: return slot0ActionBinding
        case 1: return slot1ActionBinding
        case 2: return slot2ActionBinding
        case 3: return slot3ActionBinding
        default: return Binding(get: { .scroll }, set: { _ in })
        }
    }

    /// Array index → pre-allocated speed binding for touch ring slot.
    func slotSpeedBinding(at index: Int) -> Binding<Double> {
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
    func slotBinding(for index: Int, direction: SlotDirection) -> Binding<ButtonBinding> {
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
    func slotCWBinding(at index: Int) -> Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot \(index + 1) CW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) {
                    self.settings.touchRingSlots = $0
                }
            }
        )
    }

    /// Array index → CCW rotation binding (used when action == .keyPress).
    func slotCCWBinding(at index: Int) -> Binding<ButtonBinding> {
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
                self.settings.recordToggle(String(localized: "Ring Slot \(index + 1) CCW", comment: "Undo action name: touch ring slot rotation binding in the Buttons pane"), from: oldSlots, to: newSlots) {
                    self.settings.touchRingSlots = $0
                }
            }
        )
    }
}
