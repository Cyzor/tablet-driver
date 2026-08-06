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
    /// Whether the puck is reachable right now. Only the Hardware section
    /// reads this: the binding rows above it are software and stay editable
    /// while detached, but rotation/brightness/sleep write to puck firmware
    /// and have nowhere to go. Both call sites pass it — the folded one from
    /// the companion's context, the standalone window from its own.
    var isDeviceConnected = true
    /// The dot-and-name caption both headers carry, matching every other
    /// section header in the Buttons pane ("Express Keys", "Pen Buttons").
    /// Built by the caller because only it knows which instance key to point
    /// at — the companion's when folded into a tablet's window, this
    /// window's own when the puck stands alone. Both headers show the same
    /// label: they configure one physical device.
    var nameLabel: DeviceNameLabel?

    /// Bumped when the dial diagram's center is clicked, starting recording
    /// in the Dial row's binding field — direct manipulation on the diagram.
    @State private var dialRecordToken = 0

    /// Direction for slotBinding(at:direction:).
    private enum SlotDirection { case cw, ccw }

    var body: some View {
        Group {
            bindingsSection
            hardwareSection
        }
    }

    private var bindingsSection: some View {
        let lb = liveButtons
        let keyCount = min(max(spec?.buttonCount ?? 8, 0) - 1, 16)

        return Section {
            ForEach(0..<max(keyCount, 0), id: \.self) { i in
                buttonRow(
                    String(localized: "Key \(i + 1)", comment: "Quick Keys express key N label"),
                    isActive: lb.expressKeys[i],
                    binding: settings.recordingBinding(
                        String(localized: "Quick Keys Key \(i + 1)", comment: "Undo action name: Quick Keys binding in the Buttons pane"),
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
                    String(localized: "Quick Keys Mode Button", comment: "Undo action name: Quick Keys binding in the Buttons pane"),
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
                    String(localized: "Quick Keys Dial Button", comment: "Undo action name: Quick Keys binding in the Buttons pane"),
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
                // The dial reports one discrete ±1 click per detent (not a
                // continuous position like a Wacom ring), so a single click
                // only crosses dispatchRingDelta's chunk-event threshold —
                // and gets the same anti-clamp treatment — if the per-click
                // multiplier itself is high enough. See maxSpeed's doc comment
                // on TouchRingModeListView.
                maxSpeed: 20.0,
                ledEditor: slotLEDWell(at:),
                onCenterTap: { dialRecordToken += 1 }
            )
        } header: {
            // The caption's gray dot and "No device connected" name replace
            // the trailing "Not connected" text this header used to carry —
            // same information, in the shape every other section uses.
            PaneSectionHeader("Quick Keys") { nameLabel }
        }
    }

    // MARK: - Hardware

    /// Settings the puck stores in its own firmware, kept apart from the
    /// binding rows above: those are MockTab's, these live on the device and
    /// survive being unplugged. All three park on a `-1` sentinel — the
    /// control shows a plausible value but writes nothing until the user
    /// picks one, so MockTab never clobbers what the puck already has (the
    /// same contract `displayBrightness` has in the Displays pane).
    ///
    /// Header is "Hardware", not "Quick Keys Hardware": folded into a
    /// tablet's window this already sits under the "Quick Keys" header, and
    /// in the puck's own window the whole window is the puck.
    private var hardwareSection: some View {
        Section {
            HStack {
                Image(systemName: "rotate.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Rotation", comment: "Quick Keys rotation row label")
                Spacer()
                // Apple's Displays pane spells this exact control
                // "Rotation: Standard / 90° / 180° / 270°" — borrowed
                // wholesale. Bare degrees also claim no direction, which is
                // as much as the protocol notes actually establish.
                Picker("Rotation", selection: settings.recordingBinding(
                    String(localized: "Quick Keys Rotation", comment: "Undo action name: Quick Keys hardware setting in the Buttons pane"),
                    get: { settings.quickKeysOrientation >= 0 ? settings.quickKeysOrientation : 0 },
                    set: { settings.quickKeysOrientation = $0 })) {
                    Text("Standard", comment: "Quick Keys rotation: unrotated").tag(0)
                    Text("90°", comment: "Quick Keys rotation").tag(1)
                    Text("180°", comment: "Quick Keys rotation").tag(2)
                    Text("270°", comment: "Quick Keys rotation").tag(3)
                }
                .labelsHidden()
                .fixedSize()
            }
            .help("Which way up the Quick Keys reads, for holding it rotated or left-handed.")

            HStack {
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("OLED Brightness", comment: "Quick Keys OLED brightness row label")
                Spacer()
                Picker("OLED Brightness", selection: settings.recordingBinding(
                    String(localized: "Quick Keys OLED Brightness", comment: "Undo action name: Quick Keys hardware setting in the Buttons pane"),
                    get: { settings.quickKeysOledBrightness >= 0 ? settings.quickKeysOledBrightness : 3 },
                    set: { settings.quickKeysOledBrightness = $0 })) {
                    Text("Off", comment: "Quick Keys screen brightness level").tag(0)
                    Text("Dim", comment: "Quick Keys screen brightness level").tag(1)
                    Text("Medium", comment: "Quick Keys screen brightness level").tag(2)
                    Text("Bright", comment: "Quick Keys screen brightness level").tag(3)
                }
                .labelsHidden()
                .fixedSize()
            }
            .help("Brightness of the Quick Keys OLED. Off blanks it — the keys and dial keep working.")

            HStack {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Sleep Timer", comment: "Quick Keys auto-sleep timer row label")
                Spacer()
                // Tags are literal minutes, matching the wire value
                // sleepTimerPayload sends (0 = never sleep) — no index
                // mapping in between to get wrong.
                Picker("Sleep After", selection: settings.recordingBinding(
                    String(localized: "Quick Keys Sleep Timer", comment: "Undo action name: Quick Keys hardware setting in the Buttons pane"),                    get: { settings.quickKeysSleepMinutes >= 0 ? settings.quickKeysSleepMinutes : 60 },
                    set: { settings.quickKeysSleepMinutes = $0 })) {
                    Text("30 minutes", comment: "Quick Keys sleep timer choice").tag(30)
                    Text("60 minutes", comment: "Quick Keys sleep timer choice").tag(60)
                    Text("90 minutes", comment: "Quick Keys sleep timer choice").tag(90)
                    Text("120 minutes", comment: "Quick Keys sleep timer choice").tag(120)
                    Text("Never", comment: "Quick Keys sleep timer choice: no auto-sleep").tag(0)
                }
                .labelsHidden()
                .fixedSize()
            }
            .help("How long the Quick Keys waits before sleeping. Press any key to wake it.")
        } header: {
            PaneSectionHeader("Hardware") { nameLabel }
        }
        .disabled(!isDeviceConnected)
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
                settings.recordToggle(String(localized: "Dial Slot \(index + 1) Action", comment: "Undo action name: Quick Keys dial slot binding in the Buttons pane"), from: oldSlots, to: updated) {
                    settings.touchRingSlots = $0
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
                settings.recordToggle(String(localized: "Dial Slot \(index + 1) Speed", comment: "Undo action name: Quick Keys dial slot binding in the Buttons pane"), from: oldSlots, to: updated) {
                    settings.touchRingSlots = $0
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
                // Two localized literals, not one interpolated string — an
                // embedded "CW"/"CCW" fragment inside \() would bake raw
                // English into the middle of every translation.
                let actionName =
                    direction == .cw
                    ? String(localized: "Dial Slot \(index + 1) CW", comment: "Undo action name: Quick Keys dial slot rotation binding, clockwise")
                    : String(localized: "Dial Slot \(index + 1) CCW", comment: "Undo action name: Quick Keys dial slot rotation binding, counterclockwise")
                settings.record(actionName) {
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
