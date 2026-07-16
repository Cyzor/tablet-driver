// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TabletKit

/// The Quick Keys UI: express keys, mode button, dial center-click, and the
/// dial's mode slots (action, speed, key bindings, LED color). Renders
/// identically whether it's folded into a tablet's Buttons pane as a
/// companion section (`ButtonMappingView.quickKeysSection`) or shown as the
/// puck/dongle's own standalone window (`ButtonMappingView.body`'s aux-only
/// path) — only which settings/spec/live-state it's fed changes.
///
/// Bindings read/write `settings` directly, whichever `TabletSettings`
/// instance the caller passes in — the companion's own (keyed by its own
/// PID) when folded into a tablet's window, or this window's own when the
/// puck has its own window. Each physical device keeps its own independent
/// binding storage regardless of where its controls are drawn.
struct QuickKeysSectionView: View {
    /// Observed, not just referenced: when folded into a tablet's window,
    /// this is the companion's own settings object, which no enclosing view
    /// observes — without the subscription its edits (and undo replays)
    /// would persist but never re-render these rows.
    @ObservedObject var settings: TabletSettings
    let spec: WacomDeviceSpec?
    let liveButtons: LiveButtonState

    /// Bumped when the dial diagram's center is clicked, starting recording
    /// in the Dial row's binding field — direct manipulation on the diagram.
    @State private var dialRecordToken = 0

    /// Direction for slotBinding(at:direction:).
    private enum SlotDirection { case cw, ccw }

    var body: some View {
        let lb = liveButtons
        let keyCount = min(max(spec?.buttonCount ?? 8, 0) - 1, 16)

        Section("Quick Keys") {
            ForEach(0..<max(keyCount, 0), id: \.self) { i in
                buttonRow(
                    String(localized: "Key \(i + 1)", comment: "Quick Keys express key N label"),
                    isActive: lb.expressKeys[i],
                    binding: settings.recordingBinding(
                        "Quick Keys Key \(i + 1)",
                        get: { settings.expressKeyBindings[i] },
                        set: { newValue in
                            var updated = settings.expressKeyBindings
                            updated[i] = newValue
                            settings.expressKeyBindings = updated
                        }
                    ))
            }
            // The bottom mode button rides the same indexed express-key
            // array as the last slot (buttons[8] in AuxButtons — see
            // XencelabsDecoder.decodeAux).
            buttonRow(
                String(localized: "Mode", comment: "Quick Keys bottom mode button label"),
                isActive: lb.expressKeys[keyCount],
                binding: settings.recordingBinding(
                    "Quick Keys Mode Button",
                    get: { settings.expressKeyBindings[keyCount] },
                    set: { newValue in
                        var updated = settings.expressKeyBindings
                        updated[keyCount] = newValue
                        settings.expressKeyBindings = updated
                    }
                ))
            // Dial center click — reuses the touch-ring center-button
            // slot, mirroring how XencelabsDecoder reports it via
            // AuxButtons.touchRingButtonDown rather than an indexed key.
            buttonRow(
                String(localized: "Dial", comment: "Quick Keys dial center-click row label"),
                isActive: lb.touchRingButtonDown,
                binding: settings.recordingBinding(
                    "Quick Keys Dial Button",
                    get: { settings.touchRingButtonBinding },
                    set: { settings.touchRingButtonBinding = $0 }
                ),
                recordRequestToken: dialRecordToken)
            // Dial rotation (CW/CCW detents) — same ControlSlot model used
            // by a real touch ring. Summary list + per-mode editor, with
            // the clickable dial diagram beneath.
            let ringSlotCount = spec?.ringSlotCount ?? 4
            TouchRingModeListView(
                slots: settings.touchRingSlots,
                shownSlotCount: min(settings.touchRingSlots.count, ringSlotCount),
                ringSlotCount: ringSlotCount,
                isRingActive: true,
                activeSlotIndex: settings.touchRingActiveSlotIndex,
                centerDown: lb.touchRingButtonDown,
                showsDiagram: true,
                actionBinding: slotActionBinding(at:),
                speedBinding: slotSpeedBinding(at:),
                cwBinding: { slotBinding(at: $0, direction: .cw) },
                ccwBinding: { slotBinding(at: $0, direction: .ccw) },
                ledEditor: slotLEDWell(at:),
                onCenterTap: { dialRecordToken += 1 }
            )
        }
    }

    private func slotActionBinding(at index: Int) -> Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard settings.touchRingSlots.indices.contains(index) else { return .scroll }
                return settings.touchRingSlots[index].action
            },
            set: { newValue in
                let oldSlots = settings.touchRingSlots
                guard oldSlots.indices.contains(index) else { return }
                var updated = oldSlots
                updated[index].action = newValue
                settings.touchRingSlots = updated
                settings.record("Dial Slot \(index + 1) Action") {
                    settings.touchRingSlots = oldSlots
                }
            }
        )
    }

    private func slotSpeedBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard settings.touchRingSlots.indices.contains(index) else { return 1.0 }
                return settings.touchRingSlots[index].speed
            },
            set: { newValue in
                let oldSlots = settings.touchRingSlots
                guard oldSlots.indices.contains(index) else { return }
                var updated = oldSlots
                updated[index].speed = newValue
                settings.touchRingSlots = updated
                settings.record("Dial Slot \(index + 1) Speed") {
                    settings.touchRingSlots = oldSlots
                }
            }
        )
    }

    private func slotBinding(at index: Int, direction: SlotDirection) -> Binding<ButtonBinding> {
        Binding(
            get: {
                guard settings.touchRingSlots.indices.contains(index) else { return .none }
                let slot = settings.touchRingSlots[index]
                return direction == .cw ? slot.cwBinding : slot.ccwBinding
            },
            set: { newValue in
                let oldSlots = settings.touchRingSlots
                guard oldSlots.indices.contains(index) else { return }
                var updated = oldSlots
                if direction == .cw { updated[index].cwBinding = newValue }
                else { updated[index].ccwBinding = newValue }
                settings.touchRingSlots = updated
                settings.record(
                    "Dial Slot \(index + 1) \(direction == .cw ? "CW" : "CCW")"
                ) {
                    settings.touchRingSlots = oldSlots
                }
            }
        )
    }

    /// The shared light editor for one mode slot's dial LED: a compact well
    /// in the mode's expanded editor, opening the swatch/brightness popover
    /// — the full inline swatch row overloaded the editor visually. Undo
    /// coalescing lives inside LEDColorControl; the binding just reads and
    /// writes the slot's stored color (nil = factory palette default).
    private func slotLEDWell(at index: Int) -> LEDColorControl {
        let defaults = XencelabsControl.defaultSlotColors
        let d = defaults[((index % defaults.count) + defaults.count) % defaults.count]
        return LEDColorControl(
            style: .well,
            color: Binding(
                get: {
                    guard settings.touchRingSlots.indices.contains(index) else { return nil }
                    return settings.touchRingSlots[index].ledColor
                },
                set: { newValue in
                    guard settings.touchRingSlots.indices.contains(index) else { return }
                    var updated = settings.touchRingSlots
                    updated[index].ledColor = newValue
                    settings.touchRingSlots = updated
                }),
            defaultWire: d,
            undoLabel: "Dial Color",
            settings: settings)
    }
}
