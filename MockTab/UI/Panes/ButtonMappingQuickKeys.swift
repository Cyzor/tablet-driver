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
    let settings: TabletSettings
    let spec: WacomDeviceSpec?
    let liveButtons: LiveButtonState

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
                ))
            // Dial rotation (CW/CCW detents) — same ControlSlot model used
            // by a real touch ring.
            let ringSlotCount = spec?.ringSlotCount ?? 4
            let slotCount = min(settings.touchRingSlots.count, ringSlotCount)
            ForEach(
                Array(settings.touchRingSlots.prefix(slotCount).enumerated()),
                id: \.element.id
            ) { idx, slot in
                TouchRingSlotRowView(
                    slot: slot,
                    idx: idx,
                    isActiveSlot: false,
                    ringSlotCount: ringSlotCount,
                    actionBinding: slotActionBinding(at: idx),
                    speedBinding: slotSpeedBinding(at: idx),
                    cwBinding: slotBinding(at: idx, direction: .cw),
                    ccwBinding: slotBinding(at: idx, direction: .ccw),
                    ledWell: slotLEDWell(at: idx)
                )
                .equatable()
            }
            touchRingDiagramRow(ringSlotCount: ringSlotCount, centerDown: lb.touchRingButtonDown)
        }
    }

    private func touchRingDiagramRow(ringSlotCount: Int, centerDown: Bool) -> some View {
        TouchRingDiagramView(
            activeSlotIndex: settings.touchRingActiveSlotIndex,
            centerDown: centerDown,
            slotCount: ringSlotCount
        )
        .equatable()
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 140)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private func slotActionBinding(at index: Int) -> Binding<ControlSlot.Action> {
        Binding(
            get: {
                guard settings.touchRingSlots.indices.contains(index) else { return .scroll }
                return settings.touchRingSlots[index].action
            },
            set: { newValue in
                guard settings.touchRingSlots.indices.contains(index) else { return }
                var updated = settings.touchRingSlots
                updated[index].action = newValue
                settings.touchRingSlots = updated
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
                guard settings.touchRingSlots.indices.contains(index) else { return }
                var updated = settings.touchRingSlots
                updated[index].speed = newValue
                settings.touchRingSlots = updated
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
                guard settings.touchRingSlots.indices.contains(index) else { return }
                var updated = settings.touchRingSlots
                if direction == .cw { updated[index].cwBinding = newValue }
                else { updated[index].ccwBinding = newValue }
                settings.touchRingSlots = updated
            }
        )
    }

    /// The shared light editor for one mode slot's dial LED, in compact well
    /// form (a color dot opening the swatch/brightness popover). Undo
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
