// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wacom's function codes and what each is in MockTab. Each table serves both
// directions: reading looks a code up, writing looks a MockTab value up, so
// the two can't drift apart. Keystrokes (codes 8 and 9) carry their keys in
// other fields and are read in WacomPrefs.swift.

/// Button, ExpressKey, and pen button functions (`ButtonFunction`).
enum ButtonCodes {
    struct Row {
        let code: Int
        /// Wacom's name for it, as the report shows it.
        let wacom: String
        /// The `ButtonBinding.Kind` raw values it stands for; reading gives the
        /// first. Empty when MockTab has no equivalent.
        let kinds: [String]
        let confidence: Confidence
    }

    static let keystroke = 8
    static let modifier = 9
    static let panel = 61

    /// The usage history Wacom keeps per button names each code. Code 0
    /// never appears alone in one, so it stays unverified.
    static let rows: [Row] = [
        Row(code: 0, wacom: "disabled", kinds: ["none"], confidence: .unverified),
        Row(code: 1, wacom: "click", kinds: ["leftClick"], confidence: .exact),
        Row(code: 2, wacom: "middle click", kinds: ["middleClick"], confidence: .exact),
        Row(code: 3, wacom: "right click", kinds: ["rightClick"], confidence: .exact),
        Row(code: 4, wacom: "double click", kinds: ["doubleClick"], confidence: .exact),
        Row(code: 7, wacom: "click lock", kinds: ["clickLock"], confidence: .exact),
        Row(code: 14, wacom: "erase", kinds: ["eraser"], confidence: .exact),
        Row(code: 15, wacom: "Wacom function 15", kinds: [], confidence: .exact),
        Row(code: 31, wacom: "display toggle", kinds: ["displayToggle"], confidence: .exact),
        Row(code: 33, wacom: "pan/scroll", kinds: ["scrollDrag"], confidence: .exact),
        Row(code: 40, wacom: "help", kinds: [], confidence: .exact),
        Row(code: 41, wacom: "radial menu", kinds: [], confidence: .exact),
        Row(code: 42, wacom: "precision mode", kinds: [], confidence: .exact),
        Row(code: 43, wacom: "touch on/off", kinds: [], confidence: .exact),
        Row(code: panel, wacom: "on-screen panel", kinds: [], confidence: .exact),
        Row(code: 104, wacom: "Wacom settings", kinds: [], confidence: .exact),
        // The second dial's key cycles that dial's modes; the key's position
        // tells them apart.
        Row(code: 108, wacom: "ring mode toggle", kinds: ["ringCycle", "ringCycle2"], confidence: .exact),
    ]

    private static let byCode = Dictionary(uniqueKeysWithValues: rows.map { ($0.code, $0) })

    static func row(_ code: Int) -> Row? { byCode[code] }

    /// The code to write for a MockTab kind, when one is sure.
    static func code(for kind: String) -> Int? {
        rows.first { $0.kinds.contains(kind) && $0.confidence != .unverified }?.code
    }
}

/// Ring and dial modes (`TouchStripFunction`).
enum RingCodes {
    struct Row {
        let code: Int
        let wacom: String
        let mode: RingMode
        let confidence: Confidence
        /// The row to write when several read as the same mode.
        let writes: Bool
    }

    static let keystrokes = 8

    static let rows: [Row] = [
        // Wacom's menu offers Disabled where it once had Skip.
        Row(code: 0, wacom: "disabled", mode: .off, confidence: .exact, writes: true),
        Row(code: 44, wacom: "auto scroll and zoom", mode: .scroll, confidence: .approximate, writes: false),
        Row(code: 45, wacom: "scroll", mode: .scroll, confidence: .exact, writes: true),
        Row(code: 47, wacom: "skip", mode: .skip, confidence: .exact, writes: true),
        Row(code: 51, wacom: "rotate", mode: .rotate, confidence: .exact, writes: true),
    ]

    private static let byCode = Dictionary(uniqueKeysWithValues: rows.map { ($0.code, $0) })

    static func row(_ code: Int) -> Row? { byCode[code] }

    /// The code to write for a mode other than keystrokes.
    static func code(for mode: RingMode) -> Int? {
        rows.first { $0.mode == mode && $0.writes }?.code
    }
}
