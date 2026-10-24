// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import SwiftUI
import TabletKit

// The Display pane's Toggle and Span section: which displays the Toggle
// Display button cycles through, and the thumbnails for picking them.
extension DisplayView {
    var toggleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Displays")
                .appFont(.settingsLabel)
                .foregroundStyle(.secondary)
                .help("Click a thumbnail to toggle that display in or out of the rotation. ⌘-click to add individual displays; ⇧-click to select a range.")
                // After `.help`, so VoiceOver hears key names, not symbols.
                .accessibilityHint("Click a thumbnail to toggle that display in or out of the rotation. Command-click to add individual displays, or Shift-click to select a range.")

            HStack(spacing: 8) {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, info in
                    toggleThumbnail(at: index, info: info)
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(displays.count <= 1)
    }

    /// Buttons bound to `kind`, named as the Buttons pane names them.
    func buttonNames(boundTo kind: ButtonBinding.Kind) -> [String] {
        let ctx = tabletManager.context(forKey: instanceKey)
        let spec = productID.flatMap { ButtonsView.layoutSpec(productID: $0, context: ctx) }
        let tool = ctx.flatMap { ToolCatalog.spec(forToolCode: $0.lastKnownToolCode) }
        let isMouse = tool?.toolType == .mouse
        // A device or side ahead of a row label, e.g. "Pucky-Puck Key 1".
        let qualified: (String, String) -> String = { owner, label in
            String(localized: "\(owner) \(label)", comment: "Button name qualified by its device or side, e.g. 'Pucky-Puck Key 1' or 'Left Key 1'")
        }
        // Names resolve only for the rows that match.
        var rows: [(binding: ButtonBinding, name: () -> String)] = []

        let t = settings.activeTool
        if !isMouse {
            rows.append((t.tipBinding, { String(localized: "Tip", comment: "Pen tip button row label in Buttons tab") }))
            rows.append((t.eraserBinding, { String(localized: "Eraser", comment: "Eraser button row label in Buttons tab") }))
        }
        let penCount = ButtonsView.penButtonCount(tool: tool, device: spec)
        let penButtons = [t.penButton1Binding, t.penButton2Binding, t.penButton3Binding, t.penButton4Binding, t.penButton5Binding]
        rows += penButtons.prefix(penCount).enumerated().map { i, binding in
            (binding, { ButtonsView.penButtonLabel(i + 1, count: penCount, isMouse: isMouse) })
        }
        if tool?.hasWheel == true {
            rows.append((t.wheelBinding, { ButtonsView.wheelLabel(tool: tool) }))
        }

        let keys = settings.expressKeyBindings
        if ButtonsView.hasSplitPadLayout(spec) {
            rows += keys.enumerated().map { slot, binding in
                (binding, {
                    let key = ButtonsView.splitPadKeyLabel(slot: slot)
                    return qualified(key.side, key.label)
                })
            }
        } else {
            rows += keys.prefix(max(spec?.buttonCount ?? 8, 0)).enumerated().map { i, binding in
                (binding, { String(localized: "Key \(i + 1)", comment: "Express key N label, e.g. 'Key 1'") })
            }
        }
        rows += settings.bezelButtonBindings.prefix(max(spec?.bezelButtonCount ?? 0, 0)).enumerated().map { i, binding in
            (binding, { String(localized: "Bezel Button \(i + 1)", comment: "Bezel button N label, e.g. 'Bezel Button 1'") })
        }
        if spec?.hasMechanicalDial == true {
            rows.append((settings.touchRingButtonBinding, {
                String(localized: "Dial Toggle", comment: "Row label for the ExpressKey that cycles a mechanical dial's modes")
            }))
            if spec?.hasDualRings == true {
                rows.append((settings.touchRingButtonBinding2, {
                    String(localized: "Dial 2 Toggle", comment: "Undo action name: second dial toggle key binding in the Buttons pane")
                }))
            }
        } else if spec?.hasTouchRing == true {
            rows.append((settings.touchRingButtonBinding, {
                String(localized: "Touch Ring Button", comment: "Undo action name: touch ring center-click binding in the Buttons pane")
            }))
        }

        // Same-brand aux-only accessories (Quick Keys, ExpressKey Remote)
        // forward their toggle to this tablet; see toggleDisplayOnPenTablet.
        if let ctx, ctx.tabletDevice.map({ $0.spec.maxX > 0 }) ?? false {
            // Sorted so the first-named button doesn't shift between redraws.
            for aux in tabletManager.deviceContexts.values.sorted(by: { $0.productID < $1.productID })
            where aux.isConnected && aux.vendorID == ctx.vendorID && aux.tabletDevice?.spec.maxX == 0 {
                let auxSpec = TabletManager.staticSpec(forProductID: aux.productID)
                let device = registry.row(forKey: aux.instanceKey)?.nickname ?? auxSpec?.name ?? ""
                let auxKeys = aux.settings.expressKeyBindings
                if auxSpec?.format == .expressKeyRemote {
                    // Its firmware owns the ring button, so only keys count.
                    rows += (auxKeys + aux.settings.bezelButtonBindings.prefix(1)).enumerated().map { slot, binding in
                        (binding, { qualified(device, ButtonsView.remoteKeyLabel(slot: slot)) })
                    }
                } else {
                    let keyCount = QuickKeysSectionView.keyCount(auxSpec)
                    rows += auxKeys.prefix(keyCount + 1).enumerated().map { slot, binding in
                        (binding, { qualified(device, QuickKeysSectionView.keyLabel(slot: slot, keyCount: keyCount)) })
                    }
                    rows.append((aux.settings.touchRingButtonBinding, { qualified(device, QuickKeysSectionView.dialLabel) }))
                }
            }
        }
        return rows.filter { $0.binding.kind == kind }.map { $0.name() }
    }

    var displayToggleHintRow: some View {
        let names = buttonNames(boundTo: .displayToggle)
        // Name one button inline so the row stays one line; the tooltip lists all.
        let assignedLabel = names.first
        let pressLabel = { (buttons: String) in
            String(localized: "Press \(buttons) to switch displays", comment: "Label naming the buttons that switch the display toggle; %@ is an or-list of button names")
        }
        return HStack(spacing: 8) {
            if assignedLabel != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            Text(assignedLabel.map(pressLabel) ?? String(localized: "No button assigned to toggle", comment: "Label when no button is assigned to display toggle"))
                .foregroundStyle(assignedLabel != nil ? .secondary : .primary)
                .help(names.count > 1 ? pressLabel(names.formatted(.list(type: .or))) : "")
            Spacer()
            if assignedLabel == nil {
                Button("Set Up") {
                    if let wc = NSApp.keyWindow?.windowController as? SettingsWindowController {
                        wc.showTab(.buttons)
                    } else {
                        SettingsWindowManager.shared.showTab(.buttons)
                    }
                }
                .buttonStyle(.bordered)
                .appControlSize(.small)
                .help("Go to the Buttons tab to assign a button that triggers the display toggle.")
            }
        }
        .padding(.vertical, 2)
    }

    /// Shown while a Span Displays press is in effect.
    var spanRestoreHintRow: some View {
        let names = buttonNames(boundTo: .spanDisplaysToggle)
        let pressLabel = { (buttons: String) in
            String(localized: "Press \(buttons) to restore the previous setting", comment: "Label naming the buttons that end a temporary span; %@ is an or-list of button names")
        }
        return HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(names.first.map(pressLabel) ?? String(localized: "Spanned until the button is pressed again", comment: "Label while a temporary span is active and its button can't be named"))
                .foregroundStyle(.secondary)
                .help(names.count > 1 ? pressLabel(names.formatted(.list(type: .or))) : "")
            Spacer()
        }
        .padding(.vertical, 2)
    }

    func toggleThumbnail(at index: Int, info: DisplayInfo) -> some View {
        let included = isIncluded(info)
        let badgeFont = NSFont.systemFont(ofSize: AppFontRole.badgeTitle.baseSize * textScale, weight: .bold)
        // 76pt chip minus horizontal padding/insets around the badge text.
        let tier = info.labelTier(fitting: 76 - 12, font: badgeFont)
        let chipLabel: String = {
            switch tier {
            case .full: return info.name
            case .firstWord: return info.firstWord
            case .index: return "\(index + 1)"
            }
        }()

        // A real button, so Tab reaches it and Space toggles it.
        return Button { thumbnailClicked(at: index, info: info) } label: {
            ZStack {
                // Wallpaper or flat fill
                if let wp = info.wallpaper {
                    Image(nsImage: wp)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 48)
                        .clipped()
                        .opacity(included ? 0.65 : 0.20)
                } else {
                    Rectangle()
                        .fill(
                            included
                                ? accent.opacity(0.15)
                                : Color.secondary.opacity(0.07))
                }

                // Include / exclude icon
                Image(systemName: included ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .appFont(size: 18)
                    .foregroundStyle(included ? Color.green : Color.secondary)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .accessibilityHidden(true)

                // Display name badge
                VStack(spacing: 0) {
                    Spacer()
                    Text(chipLabel)
                        .appFont(.badgeTitle)
                        .bold()
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .padding(.bottom, 3)
                }
            }
            .frame(minWidth: 76, minHeight: 48)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        included ? accent : Color.secondary.opacity(0.35),
                        lineWidth: included ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(tier == .full ? "" : info.name)
        // The selected trait carries included or not.
        .accessibilityAddTraits(included ? .isSelected : [])
        .accessibilityLabel(info.name)
        .accessibilityHint(Text("Adds or removes this display from the rotation.", comment: "VoiceOver hint for a display thumbnail in the toggle-display picker"))
    }

    /// Shift extends a range; Command or a plain click toggles one display.
    func thumbnailClicked(at index: Int, info: DisplayInfo) {
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if flags.contains(.shift) {
            // Shift+click: range selection from rangeStart to current index
            if rangeStart < 0 {
                rangeStart = index
            } else {
                let start = min(rangeStart, index)
                let end = max(rangeStart, index)
                var ids = settings.toggleDisplayIDSet
                if ids.isEmpty { ids = Set(displays.map(\.id)) }
                // Include all displays in the range
                for i in start...end {
                    ids.insert(displays[i].id)
                }
                // Simplify back to empty (= all) when every display is included
                let oldIDs = settings.toggleDisplayIDSet
                let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
                settings.toggleDisplayIDSet = newIDs
                settings.recordToggle(String(localized: "Toggle Display Set", comment: "Undo action name: display calibration/mapping control in the Displays pane"), from: oldIDs, to: newIDs) { settings.toggleDisplayIDSet = $0 }
                rangeStart = -1
            }
        } else if flags.contains(.command) {
            // Cmd+click: toggle individual display
            toggleIncluded(info)
        } else {
            // Regular click: toggle individual display
            toggleIncluded(info)
            rangeStart = -1
        }
    }

    // MARK: - Toggle helpers

    func isIncluded(_ info: DisplayInfo) -> Bool {
        let ids = settings.toggleDisplayIDSet
        return ids.isEmpty || ids.contains(info.id)
    }

    func toggleIncluded(_ info: DisplayInfo) {
        let oldIDs = settings.toggleDisplayIDSet
        var ids = oldIDs
        if ids.isEmpty {
            // All included implicitly → make explicit so we can exclude one
            ids = Set(displays.map(\.id))
        }
        if ids.contains(info.id) {
            ids.remove(info.id)
            if ids.isEmpty { return }  // never exclude the last display
        } else {
            ids.insert(info.id)
        }
        // Simplify back to empty (= all) when every display is included
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        settings.toggleDisplayIDSet = newIDs
        // Register undo (and, via recordToggle, redo) for the toggle set change
        settings.recordToggle(String(localized: "Toggle Display Set", comment: "Undo action name: display calibration/mapping control in the Displays pane"), from: oldIDs, to: newIDs) {
            settings.toggleDisplayIDSet = $0
        }
    }

    /// The set to build a new selection from when the click starts outside
    /// Toggle/Span mode: just the single display currently targeted (Primary
    /// resolves to the first display), not every display. Falls back to "all"
    /// only when already in Toggle/Span (where an empty `toggleDisplayIDSet`
    /// already means "all" and should keep meaning that).
    func seedIDsForNewSelection() -> Set<CGDirectDisplayID> {
        let idx = settings.displayIndex
        if idx == modeToggle || idx == modeSpan {
            let ids = settings.toggleDisplayIDSet
            return ids.isEmpty ? Set(displays.map(\.id)) : ids
        }
        if let display = targetedDisplay {
            return [display.id]
        }
        // modeAll or no resolvable target: start from everything.
        return Set(displays.map(\.id))
    }

    /// Cmd+click on a canvas rectangle: builds the toggle/span selection
    /// additively. Starting from whatever's currently targeted (a single
    /// display, or the existing Toggle/Span set), the click adds or removes
    /// just the clicked display. Stays in the current mode when it's already
    /// Toggle or Span; otherwise defaults to Toggle.
    func canvasCmdClick(at index: Int) {
        guard displays.indices.contains(index) else { return }
        let info = displays[index]
        let oldIDs = settings.toggleDisplayIDSet
        let oldDisplayIndex = settings.targetDisplayIndex
        let targetMode = (oldDisplayIndex == modeToggle || oldDisplayIndex == modeSpan) ? oldDisplayIndex : modeToggle
        var ids = seedIDsForNewSelection()
        if ids.contains(info.id) {
            ids.remove(info.id)
            if ids.isEmpty { return }  // never exclude the last display
        } else {
            ids.insert(info.id)
        }
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        applyToggleDisplaySet(ids: newIDs, index: targetMode, undoIDs: oldIDs, undoIndex: oldDisplayIndex)
    }

    /// Shift+click range-select on a canvas rectangle, mirroring the
    /// thumbnails' range behavior: selects every display between
    /// `rangeStart` and `index`. Stays in the current mode when it's already
    /// Toggle or Span; otherwise defaults to Toggle. The range is added to
    /// whatever's currently targeted (a single display, or the existing
    /// Toggle/Span set) rather than starting from every display. Outside
    /// Toggle/Span, the very first Shift+click needs no priming click first —
    /// it anchors the range at the currently-targeted display (e.g. Primary),
    /// matching Finder's "Shift+click extends from the current selection".
    func canvasRangeClick(at index: Int) {
        guard displays.indices.contains(index) else { return }
        let oldDisplayIndex = settings.targetDisplayIndex
        if rangeStart < 0 {
            if oldDisplayIndex != modeToggle, oldDisplayIndex != modeSpan, let anchor = targetedDisplay,
                let anchorIndex = displays.firstIndex(where: { $0.id == anchor.id })
            {
                rangeStart = anchorIndex
            } else {
                rangeStart = index
                return
            }
        }
        let targetMode = (oldDisplayIndex == modeToggle || oldDisplayIndex == modeSpan) ? oldDisplayIndex : modeToggle
        let start = min(rangeStart, index)
        let end = max(rangeStart, index)
        let oldIDs = settings.toggleDisplayIDSet
        var ids = seedIDsForNewSelection()
        for i in start...end {
            ids.insert(displays[i].id)
        }
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        applyToggleDisplaySet(ids: newIDs, index: targetMode, undoIDs: oldIDs, undoIndex: oldDisplayIndex)
        rangeStart = -1
    }

    /// Self-recursive so this also redoes — see `applyDisplayReset`.
    func applyToggleDisplaySet(ids: Set<CGDirectDisplayID>, index: Int, undoIDs: Set<CGDirectDisplayID>, undoIndex: Int) {
        settings.toggleDisplayIDSet = ids
        settings.targetDisplayIndex = index
        settings.record(String(localized: "Toggle Display Set", comment: "Undo action name: display calibration/mapping control in the Displays pane")) {
            self.applyToggleDisplaySet(ids: undoIDs, index: undoIndex, undoIDs: ids, undoIndex: index)
        }
    }
}
