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
    /// Sections only, for an ExpressKey Remote folded into its tablet's pane.
    var isEmbeddedRemote = false
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    var productID: Int? { instanceKey?.productID }

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isLiveResizing = false
    /// Bumped when the ring diagram's center is clicked, starting recording
    /// in the Center row's binding field — direct manipulation on the diagram.
    @State var centerRecordToken = 0
    /// Same for the pen diagram's parts: tip, eraser, buttons 1–3.
    @State var penRecordTokens = [0, 0, 0, 0, 0]

    /// Live button state, zeroed when this window is not key or is live-resizing.
    /// Zeroing during resize stops ~100 Hz tablet events from compounding the
    /// window-geometry invalidations that already occur every resize frame.
    private var liveButtons: LiveButtonState {
        guard controlActiveState == .key, !isLiveResizing else { return LiveButtonState() }
        return liveSource?.liveButtons ?? LiveButtonState()
    }

    /// This window's tablet when connected, else the active one, shown
    /// muffled so it doesn't read as this tablet working.
    private var liveSource: DeviceContext? {
        if let own = tabletManager.context(forKey: instanceKey), own.isConnected { return own }
        return tabletManager.activeContext
    }

    private var liveInputMuffled: Bool {
        instanceKey != nil && liveSource !== tabletManager.context(forKey: instanceKey)
    }

    // Not private: read from the ButtonMappingView extension in
    // ButtonMappingBindings.swift.
    var tool: ToolSettings { settings.activeTool }

    var spec: TabletSpec? {
        guard let pid = productID else { return nil }
        return Self.layoutSpec(productID: pid, context: tabletManager.context(forKey: instanceKey))
    }

    var activeToolSpec: ToolSpec? {
        guard let ctx = tabletManager.context(forKey: instanceKey) else { return nil }
        // Use the last-known tool, not just the currently-in-proximity one:
        // otherwise the button layout reverts to a generic default every
        // time the pen briefly lifts off, since activeToolCode goes back to
        // 0 on proximity exit.
        let tool = ToolCatalog.spec(forToolCode: ctx.lastKnownToolCode)
        // A flipped pen reports its eraser end as the tool. The pane shows the
        // pen it belongs to, so its buttons and drawing stay put.
        guard let eraser = tool, eraser.toolType == .eraser else { return tool }
        return Self.pen(forEraser: eraser) ?? eraser
    }

    /// The pen whose eraser end is `eraser`, or nil if none is listed.
    static func pen(forEraser eraser: ToolSpec) -> ToolSpec? {
        let pen = ToolCatalog.allTools.values.first { $0.eraserToolCode == eraser.toolCode }
            // Erasers set bit 3 of their pen's code.
            ?? ToolCatalog.allTools[eraser.toolCode & ~UInt16(0x0008)]
        guard let pen, pen.toolType != .eraser, pen.toolType != .mouse else { return nil }
        return pen
    }

    /// False only for a known pen the catalog lists without an eraser end,
    /// and only until one is seen: an eraser recorded for it wins.
    var penHasEraser: Bool {
        guard let pen = activeToolSpec, pen.toolType != .mouse, !pen.hasEraserVariant else { return true }
        return registry.allKnownTools.contains { known in
            guard let code = known.toolCode, code != pen.toolCode else { return false }
            if let eraser = ToolCatalog.spec(forToolCode: code) {
                return eraser.toolType == .eraser && Self.pen(forEraser: eraser)?.toolCode == pen.toolCode
            }
            return code & ~UInt16(0x0008) == pen.toolCode
        }
    }

    var hasTouchRing: Bool { spec?.hasTouchRing == true }
    var hasDualRings: Bool { spec?.hasDualRings == true }
    var hasTouchStrips: Bool { spec?.hasTouchStrips == true }
    /// True for PTK-470/670/870 (Intuos Pro gen 3): mechanical rotate-only
    /// dials rather than a capacitive touch ring. Drives the "Dial" vs.
    /// "Touch Ring" section label and hides the nonexistent center-click row
    /// — confirmed on real hardware 2026-09-16 that these dials have no
    /// press action at all; the mode-cycle function Wacom's own driver
    /// exposes lives on an ExpressKey ("Dial toggle"), not a ring center
    /// button. See `TabletSpec.hasMechanicalDial`'s doc comment.
    var hasMechanicalDial: Bool { spec?.hasMechanicalDial == true }

    /// Whether to draw the split left/right *pad* layout (three toggle buttons
    /// plus five express keys per side, sixteen fixed slots). That shape is a
    /// Cintiq 24HD trait, not a consequence of having two rings: the gen-3
    /// Intuos Pro also sets `hasDualRings` but has a single eight-key column.
    /// Keyed on the family rather than `buttonCount`, since the Cintiq itself
    /// declares `buttonCount: 8` while filling all sixteen slots — the
    /// dual-sided layout has never respected that field for anyone.
    var hasSplitPadLayout: Bool { Self.hasSplitPadLayout(spec) }
    /// What each ring or dial's modes do, for jump-to-mode labels.
    var ringModeNames: [[String]] { settings.rotaryModeNames }
    var bezelButtonCount: Int { spec?.bezelButtonCount ?? 0 }
    /// ExpressKey Remote: keys and a ring, no pen. Its firmware owns the
    /// ring's mode button, so that row is omitted.
    var isRemote: Bool { spec?.format == .expressKeyRemote }

    // MARK: - Companion peripheral (e.g. Xencelabs Quick Keys puck/dongle)

    /// PID of an aux-only companion peripheral for this tablet: the Quick
    /// Keys puck/dongle or an ExpressKey Remote. A live connection wins
    /// (`DeviceCompanions.connectedCompanion`); failing that, a
    /// companion seen earlier this session still resolves so its section
    /// stays visible — greyed via `companionIsConnected` — instead of
    /// vanishing while the accessory is detached (disable-vs-hide rule:
    /// disconnection is temporary state, not a capability change).
    var companionProductID: Int? {
        guard let pid = productID else { return nil }
        if let live = DeviceCompanions.connectedCompanion(
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

    var companionIsConnected: Bool {
        companionContext?.isConnected == true
    }

    var companionContext: DeviceContext? {
        companionProductID.flatMap { tabletManager.contexts[$0] }
    }

    var companionSpec: TabletSpec? {
        guard let pid = companionProductID, let ctx = companionContext else { return nil }
        return TabletManager.vendorDeviceSpec(forVendorID: ctx.vendorID, productID: pid)
    }

    /// Live button state for the companion, zeroed under the same
    /// not-key/live-resizing conditions as the tablet's own `liveButtons`.
    var companionLiveButtons: LiveButtonState {
        guard controlActiveState == .key, !isLiveResizing else { return LiveButtonState() }
        return companionContext?.liveButtons ?? LiveButtonState()
    }

    /// Number of express-key rows to display in the single-sided section.
    /// Driven by the active device spec so PTK-670/870 (8 keys — the dials
    /// themselves have no press action at all; their mode-cycle toggle is
    /// itself an ExpressKey function, not a separate control counted here)
    /// and DTU (4 keys) get the right row count instead of a hard-coded 8.
    /// Clamped to the storage limit of `expressKeyBindings` (16) for safety.
    var expressKeyCount: Int {
        let count = spec?.buttonCount ?? 8
        return min(max(count, 0), 16)
    }

    // MARK: - Body

    var body: some View {
        let _ = BodyCounter.note("Buttons")
        Group {
            if isEmbeddedRemote {
                singleSidedSection(lb: liveButtons)
            } else {
                pane
            }
        }
        .environment(\.liveInputMuffled, liveInputMuffled)
    }

    private var pane: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey, overrideKeys: AppOverrideBar.buttonKeys,
            onResetToDefaults: resetToDefaults,
            onResetAppOverride: { bundleID in
                companionContext?.settings.removeAppOverride(
                    bundleID: bundleID, keyScope: AppOverrideBar.buttonKeys)
                followChipSelection()
            }
        ) {
            // Aux-only devices (Quick Keys puck/dongle) have no pen digitizer,
            // so the pen-buttons section is structurally inapplicable — and
            // instead of the generic express-key/ring layout they get the
            // exact same QuickKeysSectionView that quickKeysSection folds into
            // a tablet's window, just fed from this window's own settings and
            // live state. One component, identical look and behavior (LED
            // color wells included) wherever the puck's controls appear.
            if spec?.format == .xencelabs && spec?.maxX == 0 {
                QuickKeysSectionView(
                    settings: settings, spec: spec, liveButtons: liveButtons,
                    isDeviceConnected: isSelfConnected,
                    nameLabel: DeviceNameLabel(
                        tabletManager: tabletManager, registry: registry, instanceKey: instanceKey))
            } else if isRemote {
                singleSidedSection(lb: liveButtons)
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
            followChipSelection()
        }
        .onChange(of: settings.activeAppOverride?.bundleID) { _ in followChipSelection() }
        .onChange(of: companionProductID) { _ in followChipSelection() }
    }

    /// The companion keeps its own per-app overrides. Its section here shows
    /// the one for the app chosen in this window's chip bar.
    private func followChipSelection() {
        let selected = settings.activeAppOverride
        companionContext?.settings.followAppOverride(
            bundleID: selected?.bundleID, appName: selected?.appName)
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
        expressKeys: [ButtonBinding], touchRingButton: ButtonBinding, touchRingButton2: ButtonBinding,
        touchRingSlots: [ControlSlot], touchRingActiveSlot: Int, touchRingActiveSlot2: Int,
        rotaries: RotarySet, reverseRingDirection: Bool
    )

    private func resetToDefaults() {
        let toolOld: ButtonToolState = (tool.tipBinding, tool.eraserBinding, tool.penButton1Binding, tool.penButton2Binding)
        let settingsOld: ButtonSettingsState = (
            settings.expressKeyBindings, settings.touchRingButtonBinding, settings.touchRingButtonBinding2,
            settings.touchRingSlots, settings.touchRingActiveSlotIndex, settings.touchRingActiveSlotIndex2,
            settings.rotaries, settings.reverseRingDirection
        )
        let isMouse = activeToolSpec?.toolType == .mouse
        let toolDefaults: ButtonToolState = (.leftClick, .eraser, .rightClick, isMouse ? .rightClick : .middleClick)
        let vendorID = tabletManager.context(forKey: instanceKey)?.vendorID ?? 0x056A
        let settingsDefaults: ButtonSettingsState = (
            TabletSettings.defaultExpressKeyBindings(vendorID: vendorID, splitPad: hasSplitPadLayout),
            ButtonBinding(kind: .ringCycle), ButtonBinding(kind: .ringCycle2),
            ControlSlot.defaults, 0, 0, settings.rotaries.resetToDefaults(slots: settings.defaultRingSlots), false
        )

        settings.undoManager?.beginUndoGrouping()
        applyButtonToolReset(toolDefaults, undoTo: toolOld)
        applyButtonSettingsReset(settingsDefaults, undoTo: settingsOld)

        // A connected companion puck/dongle (Quick Keys) keeps its own,
        // separate TabletSettings instance — see quickKeysSection's doc
        // comment. Without this, "Reset Pane to Defaults" only touched the
        // tablet's own bindings and silently left the companion's express
        // keys/dial exactly as the user had them, even though its rows are
        // folded into this same pane.
        if let companionSettings = companionContext?.settings {
            let companionSettingsOld: ButtonSettingsState = (
                companionSettings.expressKeyBindings, companionSettings.touchRingButtonBinding,
                companionSettings.touchRingButtonBinding2,
                companionSettings.touchRingSlots, companionSettings.touchRingActiveSlotIndex,
                companionSettings.touchRingActiveSlotIndex2,
                companionSettings.rotaries, companionSettings.reverseRingDirection
            )
            let companionVendorID = companionContext?.vendorID ?? vendorID
            let companionSettingsDefaults: ButtonSettingsState = (
                TabletSettings.defaultExpressKeyBindings(vendorID: companionVendorID),
                ButtonBinding(kind: .ringCycle), ButtonBinding(kind: .ringCycle2),
                ControlSlot.defaults, 0, 0, companionSettings.rotaries.resetToDefaults(), false
            )
            applyButtonSettingsReset(
                companionSettingsDefaults, undoTo: companionSettingsOld, on: companionSettings)
        }

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
    /// `on` defaults to the pane's own tablet settings; the companion
    /// puck/dongle reset (see `resetToDefaults`) passes its own instance so
    /// undo/redo replays against the correct device's storage.
    private func applyButtonSettingsReset(
        _ new: ButtonSettingsState, undoTo old: ButtonSettingsState, on target: TabletSettings? = nil
    ) {
        let target = target ?? settings
        target.expressKeyBindings = new.expressKeys
        target.touchRingButtonBinding = new.touchRingButton
        target.touchRingButtonBinding2 = new.touchRingButton2
        target.touchRingSlots = new.touchRingSlots
        target.touchRingActiveSlotIndex = new.touchRingActiveSlot
        target.touchRingActiveSlotIndex2 = new.touchRingActiveSlot2
        target.rotaries = new.rotaries
        target.reverseRingDirection = new.reverseRingDirection
        settings.record(String(localized: "Reset to Defaults", comment: "Undo action name: restoring a pane's controls to their defaults")) {
            self.applyButtonSettingsReset(old, undoTo: new, on: target)
        }
    }

    // MARK: - Touch ring / strip slots section

    /// The mode block for a ring or strip: label row, then the mode list,
    /// with the clickable ring diagram when `showsDiagram` is set.
    ///
    /// `ring` picks the control: `.primary` for a single ring, a strip, or
    /// the left ring or dial; `.secondary` for the right one.
    enum RingIdentity { case primary, secondary }

    @ViewBuilder
    func touchRingSlotsSection(
        _ label: String, isActive: Bool, showsDiagram: Bool = false,
        showsModeBadge: Bool = false,
        ring: RingIdentity = .primary,
        onCenterTap: (() -> Void)? = nil,
        centerBinding: Binding<ButtonBinding>? = nil
    ) -> some View {
        // Label row — shows "Touch Ring", "Left", or "Right" with live-active indicator.
        HStack(spacing: 6) {
            activeIndicator(isActive)
            labelText(label, isActive: isActive)
            Spacer(minLength: 0)
        }

        // Show only as many slots as the spec declares (default 4); model always stores 4.
        let ringSlotCount = spec?.ringSlotCount ?? 4
        let control: RotaryIndex = ring == .primary ? .first : .second
        let rotary = settings.rotary(control)
        let activeIndex = rotary.activeSlotIndex
        TouchRingModeListView(
            slots: rotary.slots,
            shownSlotCount: min(rotary.slots.count, ringSlotCount),
            ringSlotCount: ringSlotCount,
            isRingActive: isActive,
            activeSlotIndex: activeIndex,
            // No physical center action on mechanical-dial hardware (see
            // `hasMechanicalDial`), so the diagram's center dot never lights
            // regardless of whatever `touchRingButtonDown` happens to read.
            centerDown: hasMechanicalDial ? false : liveButtons.touchRingButtonDown,
            showsDiagram: showsDiagram,
            showsModeBadge: showsModeBadge,
            actionBinding: { self.slotActionBinding(control: control, at: $0) },
            speedBinding: { self.slotSpeedBinding(control: control, at: $0) },
            cwBinding: { self.slotBinding(control: control, for: $0, direction: .cw) },
            ccwBinding: { self.slotBinding(control: control, for: $0, direction: .ccw) },
            onCenterTap: onCenterTap,
            centerBinding: centerBinding
        )
    }

    // buttonRow / activeIndicator / labelText now live in
    // UI/Components/ButtonRow.swift, shared with QuickKeysSectionView.

}

// Touch ring slot rows, the shortcut-recorder control, and the live-resize
// detector used above all live in UI/Components/ now — see
// TouchRingSlotRow.swift, ButtonBindingControl.swift, and
// LiveResizeDetector.swift.

#Preview("ExpressKey Remote") {
    let key = DeviceInstanceKey(productID: 0x0331, instance: "preview")
    ButtonMappingView(
        settings: TabletSettings(instanceKey: key), tabletManager: .shared,
        registry: .shared, instanceKey: key)
        .frame(width: 620, height: 900)
}

// MARK: - Shared row labels

/// Static so the Display pane's toggle hint names each button as this pane does.
extension ButtonMappingView {
    /// The spec that decides this pane's layout.
    static func layoutSpec(productID pid: Int, context ctx: DeviceContext?) -> TabletSpec? {
        // Most devices are in the registry keyed by their own PID.
        // The ACK-40401 wireless dongle's own registry entry is a
        // name-only placeholder (maxX/maxY/buttonCount all 0) — skip it
        // and fall back to the paired tablet's PID reported over the RF
        // link instead of showing an empty Buttons pane.
        if let s = WacomDeviceRegistry.spec(for: pid), s.maxX > 0 || s.isAuxOnly { return s }
        guard let ctx else { return nil }
        if ctx.pairedProductID > 0 { return WacomDeviceRegistry.spec(for: ctx.pairedProductID) }
        // Non-Wacom drivable devices (Xencelabs) aren't in WacomDeviceRegistry
        // at all — synthesize the same spec shape TabletManager attached the
        // live driver with.
        return TabletManager.vendorDeviceSpec(forVendorID: ctx.vendorID, productID: pid)
    }

    static func hasSplitPadLayout(_ spec: TabletSpec?) -> Bool {
        spec?.hasDualRings == true && spec?.format == .cintiqV1
    }

    /// Mice show all 5 HID-path button slots: `buttonCount` describes only
    /// the digitizer path. `tool` is nil until a pen first reports in; 3
    /// covers the Xencelabs 3 Button Pen until then.
    static func penButtonCount(tool: ToolSpec?, device: TabletSpec?) -> Int {
        tool?.toolType == .mouse ? 5 : (tool?.buttonCount ?? (device?.format == .xencelabs ? 3 : 2))
    }

    /// Label for pen or mouse button `n`, counting from 1.
    static func penButtonLabel(_ n: Int, count: Int, isMouse: Bool) -> String {
        if isMouse {
            switch n {
            case 1: return String(localized: "Button 1", comment: "Pen button row label: mouse button 1")
            case 2: return String(localized: "Button 2", comment: "Pen button row label: mouse button 2")
            case 3: return String(localized: "Button 3", comment: "Pen button row label: mouse button 3")
            case 4: return String(localized: "Button 4", comment: "Pen button row label: mouse button 4")
            default: return String(localized: "Button 5", comment: "Pen button row label: mouse button 5")
            }
        }
        switch n {
        case 1 where count == 1: return String(localized: "Side button", comment: "Pen button row label: single side button")
        case 1: return String(localized: "Side button 1", comment: "Pen button row label: first side button")
        case 2: return String(localized: "Side button 2", comment: "Pen button row label: second side button")
        case 3: return String(localized: "Side button 3", comment: "Pen button row label: third side button")
        case 4: return String(localized: "Side button 4", comment: "Pen button row label: fourth side button")
        default: return String(localized: "Side button 5", comment: "Pen button row label: fifth side button")
        }
    }

    static func wheelLabel(tool: ToolSpec?) -> String {
        tool?.toolType == .airbrush
            ? String(localized: "Fingerwheel", comment: "Airbrush fingerwheel row label")
            : String(localized: "Scroll Wheel", comment: "Mouse scroll wheel row label")
    }

    /// Split-pad slots per side: three toggle buttons, then five express keys.
    static func splitPadKeyLabel(slot: Int) -> (side: String, label: String) {
        let side = slot < 8
            ? String(localized: "Left", comment: "Left touch strip row label")
            : String(localized: "Right", comment: "Right touch strip row label")
        let i = slot % 8
        let label = i < 3
            ? String(localized: "Button \(i + 1)", comment: "Toggle button N label, e.g. 'Button 1'")
            : String(localized: "Key \(i - 2)", comment: "Express key N label, e.g. 'Key 1'")
        return (side, label)
    }

    // ExpressKey Remote slots in hardware order. Indices follow libwacom's
    // layout (wire bit N+1 → key N; bit 0 is the ring toggle). Slot 16
    // arrives past the 16 express-key slots, in bezel binding 0.
    static let remoteRingKeySlots = [1, 2, 0, 3, 4]
    static let remoteOuterLeftSlots = [5, 8, 11, 15]
    static let remoteOuterRightSlots = [7, 10, 13, 16]
    static let remoteInnerSlots = [6, 9, 12, 14]

    static func remoteKeyLabel(slot: Int) -> String {
        switch slot {
        case 0: return String(localized: "Left", comment: "Left touch strip row label")
        case 1: return String(localized: "Top Left", comment: "ExpressKey Remote key position")
        case 2: return String(localized: "Top Right", comment: "ExpressKey Remote key position")
        case 3: return String(localized: "Right", comment: "Right touch strip row label")
        case 4: return String(localized: "Bottom", comment: "ExpressKey Remote key position")
        default: break
        }
        if let n = remoteOuterLeftSlots.firstIndex(of: slot) {
            return String(localized: "Left \(n + 1)", comment: "ExpressKey Remote outer key, left column, top to bottom")
        }
        if let n = remoteOuterRightSlots.firstIndex(of: slot) {
            return String(localized: "Right \(n + 1)", comment: "ExpressKey Remote outer key, right column, top to bottom")
        }
        let n = remoteInnerSlots.firstIndex(of: slot) ?? 0
        return String(localized: "Key \(n + 1)", comment: "Express key N label, e.g. 'Key 1'")
    }
}
