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
                    colorBinding: slotColorBinding(at: idx)
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
    private func slotColorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                let defaults = XencelabsControl.defaultSlotColors
                let d = defaults[((index % defaults.count) + defaults.count) % defaults.count]
                let c = settings.touchRingSlots.indices.contains(index)
                    ? settings.touchRingSlots[index].ledColor : nil
                let (r, g, b, a) = c.map { ($0.r, $0.g, $0.b, $0.a) } ?? (d.r, d.g, d.b, 255)
                return Color(
                    red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255,
                    opacity: Double(a) / 255)
            },
            set: { newValue in
                guard settings.touchRingSlots.indices.contains(index),
                      let rgb = NSColor(newValue).usingColorSpace(.sRGB)
                else { return }
                dialColorUndo.noteChange(settings: settings, before: settings.touchRingSlots)
                var updated = settings.touchRingSlots
                updated[index].ledColor = ControlSlot.LEDColor(
                    r: UInt8((rgb.redComponent * 255).rounded()),
                    g: UInt8((rgb.greenComponent * 255).rounded()),
                    b: UInt8((rgb.blueComponent * 255).rounded()),
                    a: UInt8((rgb.alphaComponent * 255).rounded()))
                settings.touchRingSlots = updated
            }
        )
    }
}
