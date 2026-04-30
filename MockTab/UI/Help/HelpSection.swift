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

import Foundation

/// One entry in the help panel sidebar, matching the app's tab order.
///
/// Each case carries a localized title, a system image name, and a body
/// returned as `AttributedString` parsed from a Markdown source string.
/// All body strings go through `String(localized:comment:)` so Xcode picks
/// them up in Localizable.xcstrings automatically — add translations there
/// to localize help content into additional languages.
enum HelpSection: String, CaseIterable, Identifiable {
    case tabletArea
    case penFeel
    case buttons
    case display
    case devices
    case profiles
    case scratchpad
    case info

    var id: String { rawValue }

    /// Index into `SettingsWindowController.tabLabels` / tab bar.
    var tabIndex: Int { HelpSection.allCases.firstIndex(of: self)! }

    var title: String {
        switch self {
        case .tabletArea: String(localized: "Tablet Area",  comment: "Help section title")
        case .penFeel:    String(localized: "Pen Feel",     comment: "Help section title")
        case .buttons:    String(localized: "Buttons",      comment: "Help section title")
        case .display:    String(localized: "Display",      comment: "Help section title")
        case .devices:    String(localized: "Devices",      comment: "Help section title")
        case .profiles:   String(localized: "Profiles",     comment: "Help section title")
        case .scratchpad: String(localized: "Scratchpad",   comment: "Help section title")
        case .info:       String(localized: "Info",         comment: "Help section title")
        }
    }

    var systemImage: String {
        switch self {
        case .tabletArea: "rectangle.dashed"
        case .penFeel:    "scribble.variable"
        case .buttons:    "square.grid.2x2.fill"
        case .display:    "display"
        case .devices:    "rectangle.on.rectangle"
        case .profiles:   "star.circle"
        case .scratchpad: "pencil.and.outline"
        case .info:       "info.circle"
        }
    }

    /// Localized Markdown source for the help body.
    ///
    /// Keep each string key stable — translators map to these keys in
    /// Localizable.xcstrings. The comment describes translator expectations.
    var markdownSource: String {
        switch self {
        case .tabletArea:
            String(
                localized: """
                    ## Active Area

                    The active area is the region of the tablet surface that maps to your screen. \
                    Pen input outside this rectangle is ignored.

                    **Resizing** — Drag any handle in the preview to reposition or resize the active \
                    area. Hold **Shift** while dragging a corner to lock the aspect ratio to your \
                    display's proportions. Exact dimensions can also be typed into the Width and \
                    Height fields.

                    **Lock Aspect Ratio** — Keeps the tablet-to-screen ratio proportional so the \
                    cursor travels equal distances horizontally and vertically. Disable it if you \
                    want to deliberately stretch or compress the mapping.

                    **Reset to Full** — Restores the active area to the entire tablet surface. \
                    This action is undoable (⌘Z).

                    ## Calibration (Pen Displays)

                    The **Calibrate** button opens a full-screen overlay where you tap crosshair \
                    targets with your pen tip. This corrects the parallax gap between the pen tip \
                    and the on-screen cursor caused by the display glass.

                    After calibrating, use **Manual Fine-Tune** if a small constant offset \
                    remains — for example, when parallax shifts slightly depending on your \
                    viewing angle.
                    """,
                comment: "Help body for the Tablet Area pane. Uses Markdown. ##-headings become section titles, **text** becomes bold. Do not translate the keyboard shortcut ⌘Z.")

        case .penFeel:
            String(
                localized: """
                    ## Pressure Curve

                    The pressure curve controls how pen pressure maps to output \
                    pressure. A concave curve (pulled up) makes light strokes register \
                    heavier; a convex curve (pushed down) requires more force for the same effect.

                    **Tip Feel presets** — Soft, Medium, Firm, and Custom. Choosing a preset \
                    sets the curve; adjusting a curve point switches to Custom automatically.

                    ## Smoothing

                    Smoothing reduces high-frequency jitter in the input signal. Higher values \
                    produce cleaner strokes at the cost of a small lag at the start and end of \
                    each stroke. For fast, gestural work, lower values feel more immediate.

                    ## Double-Click Distance

                    Sets how close two taps must be to register as a double-click. Increase it \
                    if double-clicks are not registering; decrease it if accidental double-clicks \
                    occur during normal drawing.
                    """,
                comment: "Help body for the Pen Feel pane. Uses Markdown. Do not translate preset names (Soft, Medium, Firm, Custom).")

        case .buttons:
            String(
                localized: """
                    ## Pen Diagram

                    The diagram at the top shows your pen's buttons. Press any button \
                    while the window is open to see it highlight — useful for identifying \
                    which physical button maps to which assignment slot.

                    ## Assignment Types

                    - **Mouse buttons** — Left, Right, Middle click, or Double-click
                    - **Keyboard shortcuts** — click the shortcut field and press any key combination
                    - **Modifier holds** — ⌘ ⌥ ⇧ ⌃ held for as long as the button is pressed
                    - **Special actions** — Display Toggle, Eraser, Touch Ring mode selection

                    ## Touch Ring

                    The ring supports multiple mode slots. Each slot has its own clockwise \
                    and counter-clockwise action (scroll, zoom, or a key repeat). \
                    Assign **Ring Cycle** to a button to step through modes, or **Ring: Slot N** \
                    to jump directly to a specific slot. The **speed multiplier** controls how \
                    fast actions fire per degree of rotation.

                    ## Eraser

                    The eraser tip has its own binding, configured in the pen section. \
                    Most drawing apps switch to their eraser tool automatically when they \
                    receive eraser proximity events — no special binding is required unless \
                    you want to override that behavior.

                    ## Per-App Overrides

                    The app override bar at the top lets you assign different buttons for a \
                    specific application. Overrides activate automatically when that app moves \
                    to the foreground. Global settings apply everywhere else.
                    """,
                comment: "Help body for the Button Mapping pane. Uses Markdown. Do not translate keyboard symbols (⌘ ⌥ ⇧ ⌃) or action names (Ring Cycle, Ring: Slot N, Display Toggle).")

        case .display:
            String(
                localized: """
                    ## Display Mapping

                    Display mapping controls which screen the tablet active area maps to.

                    **All Displays** — the tablet spans your entire desktop, proportionally. \
                    Use this when you work across multiple monitors.

                    **Single Display** — the active area maps to one specific display. \
                    Choose a display from the list; the preview updates to show the mapping.

                    **Display Toggle** — assign the Display Toggle action to an express key or \
                    barrel button to cycle through connected displays without opening settings.
                    """,
                comment: "Help body for the Display Mapping pane. Uses Markdown. Do not translate action name (Display Toggle).")

        case .devices:
            String(
                localized: """
                    ## Connected Devices

                    The Devices pane lists every tablet and pen tool that MockTab has seen. \
                    Each row shows the device name, connection type (USB or Bluetooth), and \
                    current status.

                    ## Tool Registry

                    When a pen is detected, MockTab records its tool code. If a tool code is \
                    unrecognized, it appears as "Unknown tool" in the registry. You can assign \
                    a name and tip binding to unknown tools manually.

                    ## Conflict Detection

                    If another tablet driver (such as the official Wacom driver) is running, \
                    MockTab detects the conflict and shows a warning. Both drivers competing for \
                    the same HID device can cause erratic behavior; quit the conflicting driver \
                    before using MockTab.
                    """,
                comment: "Help body for the Devices pane. Uses Markdown. Do not translate: MockTab, Wacom, HID.")

        case .profiles:
            String(
                localized: """
                    ## Profiles

                    A profile is a saved snapshot of all your tablet settings — active area, \
                    pressure curve, button assignments, and display mapping. Switching profiles \
                    applies all settings instantly.

                    **Auto-restore** — enable the toggle on a profile to have MockTab \
                    automatically activate it when this tablet is connected.

                    ## Creating and Renaming

                    Click **Save as New Profile** to capture the current settings. \
                    Double-click a profile name to rename it.

                    ## Per-App Overrides in Profiles

                    Per-app overrides are stored as part of the active profile. When you \
                    switch profiles, the per-app overrides switch with it.

                    ## Import / Export

                    Drag a profile card to Finder to export it as a JSON file. \
                    Drag a JSON file onto the profile list to import it. Exported files can \
                    be shared between machines or used as backups.
                    """,
                comment: "Help body for the Profiles pane. Uses Markdown. Do not translate: MockTab, JSON, Finder.")

        case .scratchpad:
            String(
                localized: """
                    ## Scratchpad

                    The scratchpad is a pressure-sensitive test canvas. Draw on it to verify \
                    that your pen is registering pressure, tilt, and stroke position correctly \
                    before using a drawing application.

                    Stroke opacity and width both respond to tip pressure. Tilt affects the \
                    stroke angle when the pen supports it.

                    **Clear** — removes all strokes from the canvas. This cannot be undone.
                    """,
                comment: "Help body for the Scratchpad pane. Uses Markdown.")

        case .info:
            String(
                localized: """
                    ## Live Input

                    The Info pane displays real-time values from your pen: X/Y position, \
                    pressure, tilt, rotation, hover distance, and button state. These values \
                    update continuously while the pen is in range.

                    This is useful for diagnosing unexpected behavior — for example, checking \
                    whether pressure is reaching its maximum value, or whether tilt is being \
                    reported at all.

                    ## Diagnostics

                    The **Copy Diagnostics** button produces a text snapshot of the current \
                    driver state — app version, macOS version, connected devices, and input \
                    statistics. Paste it into a bug report or support request.

                    ## Collect Device Data

                    **Collect Device Data** runs a guided capture session that records the raw \
                    HID reports your tablet sends. The result is a compact JSON file you can \
                    attach to a feature request to add or improve support for your device.
                    """,
                comment: "Help body for the Info pane. Uses Markdown. Do not translate: MockTab, HID, JSON, X/Y.")
        }
    }

    /// Parsed `AttributedString` from the localized Markdown source.
    /// Falls back to plain text if Markdown parsing fails.
    var body: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdownSource, options: options))
            ?? AttributedString(markdownSource)
    }
}
