// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - TouchRingMode

/// What the touch ring / scroll ring produces when turned.
enum TouchRingMode: String, Codable, CaseIterable {
    /// Emit scroll-wheel events (default).
    case scroll
    /// Do nothing.
    case off

    var displayLabel: String {
        switch self {
        case .scroll:
            return String(localized: "Scroll", comment: "Touch ring mode: scroll wheel output")
        case .off: return String(localized: "Off", comment: "Touch ring mode: disabled")
        }
    }
}

// MARK: - ControlSlot

/// A named configuration for the touch ring (or shared strip controls).
/// Rings and strips share a single active slot index, so they always move together.
/// Stored as a JSON array under the key "touchRingSlotsJSON".
struct ControlSlot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Human-readable label shown in the UI (e.g. "Scroll", "Zoom", "Brush Size").
    var label: String = ""
    /// What the ring/strip does when rotated.
    var action: Action = .scroll
    /// Key binding for clockwise rotation (used when action == .keyPress).
    var cwBinding: ButtonBinding = .none
    /// Key binding for counter-clockwise rotation (used when action == .keyPress).
    var ccwBinding: ButtonBinding = .none
    /// Speed multiplier applied to ring/strip delta before scroll/key dispatch.
    /// 1.0 = native one-line-per-detent; 0.25 = slowest; 3.0 = fastest.
    var speed: Double = 1.0
    /// Custom dial-LED color for this mode slot (Xencelabs Quick Keys only;
    /// ignored by Wacom hardware, whose LEDs are single-color). nil = the
    /// factory per-mode palette. Raw sRGB bytes (no LED calibration — modes
    /// stay tellable apart); the color panel's opacity is kept separately so
    /// the picked hue round-trips intact.
    var ledColor: LEDColor?

    /// Fields a future app version added that this build doesn't know about.
    /// Preserved verbatim on re-encode — see TabletSettings.Profile.unknownFields.
    private var unknownFields: [String: JSONValue] = [:]

    init(
        id: UUID = UUID(), label: String = "", action: Action = .scroll,
        cwBinding: ButtonBinding = .none, ccwBinding: ButtonBinding = .none,
        speed: Double = 1.0, ledColor: LEDColor? = nil
    ) {
        self.id = id
        self.label = label
        self.action = action
        self.cwBinding = cwBinding
        self.ccwBinding = ccwBinding
        self.speed = speed
        self.ledColor = ledColor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, action, cwBinding, ccwBinding, speed, ledColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        action = try c.decode(Action.self, forKey: .action)
        cwBinding = try c.decode(ButtonBinding.self, forKey: .cwBinding)
        ccwBinding = try c.decode(ButtonBinding.self, forKey: .ccwBinding)
        speed = try c.decode(Double.self, forKey: .speed)
        ledColor = try c.decodeIfPresent(LEDColor.self, forKey: .ledColor)
        unknownFields = try UnknownFieldsCodec.captureUnknown(
            from: decoder, knownKeys: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(action, forKey: .action)
        try c.encode(cwBinding, forKey: .cwBinding)
        try c.encode(ccwBinding, forKey: .ccwBinding)
        try c.encode(speed, forKey: .speed)
        try c.encodeIfPresent(ledColor, forKey: .ledColor)
        try UnknownFieldsCodec.encodeUnknown(unknownFields, to: encoder)
    }

    /// Sets `action`, resetting `speed` to that action's default if it
    /// defines one (see `Action.defaultSpeedOnSwitch`) and the action is
    /// actually changing. The single mutation point for every "change this
    /// slot's action" call site — direct `slot.action = newValue` bypasses
    /// this and risks carrying an out-of-range speed across action changes
    /// with different ranges (e.g. Zoom's 0...8 into Rotate's 0...1).
    mutating func setAction(_ newAction: Action) {
        guard newAction != action else { return }
        action = newAction
        if let defaultSpeed = newAction.defaultSpeedOnSwitch {
            speed = defaultSpeed
        }
    }

    static func == (lhs: ControlSlot, rhs: ControlSlot) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label && lhs.action == rhs.action
            && lhs.cwBinding == rhs.cwBinding && lhs.ccwBinding == rhs.ccwBinding
            && lhs.speed == rhs.speed && lhs.ledColor == rhs.ledColor
    }

    struct LEDColor: Codable, Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        /// Brightness, from the color panel's opacity slider (255 = full).
        /// The LED has no brightness register — the vendor stack scales it
        /// into the RGB bytes, so this is premultiplied at send time.
        var a: UInt8

        init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            r = try c.decode(UInt8.self, forKey: .r)
            g = try c.decode(UInt8.self, forKey: .g)
            b = try c.decode(UInt8.self, forKey: .b)
            // Colors saved before brightness existed are full-strength.
            a = try c.decodeIfPresent(UInt8.self, forKey: .a) ?? 255
        }
    }

    /// Four-slot default used on init, reset, and legacy migration.
    /// Matches Wacom's standard 4-LED toggle ring layout; unused slots default to Off.
    static let defaults: [ControlSlot] = [
        ControlSlot(label: String(localized: "Scroll", comment: "Default ring slot label"), action: .scroll),
        ControlSlot(label: String(localized: "Off",    comment: "Default ring slot label"), action: .off),
        ControlSlot(label: String(localized: "Off",    comment: "Default ring slot label"), action: .off),
        ControlSlot(label: String(localized: "Off",    comment: "Default ring slot label"), action: .off),
    ]

    /// Declaration order is the Action picker's display order (via
    /// `allCases`) — Scroll, Zoom, Rotate, Key, Off, Skip. Raw-value coding
    /// means reordering these cases doesn't affect persisted data.
    enum Action: String, Codable, CaseIterable {
        case scroll
        /// Analog pinch-zoom, synthesized the same way a real trackpad pinch
        /// is (`InputInjector.postTouchMagnify`) — smooth continuous zoom,
        /// not the stepped ⌥/⌘+wheel fallback `.scroll` uses under a
        /// modifier. See `Notes/Scratch/ring-dial-analog-zoom-rotate-design.md`.
        case zoom
        /// Analog rotate, synthesized like a real trackpad two-finger twist
        /// (`InputInjector.postTouchRotate`). Same design doc as `.zoom`.
        case rotate
        case keyPress
        case off
        /// Left out of the mode rotation entirely — the mode button passes
        /// over this slot (Wacom's native way to shorten the cycle when only
        /// one or two modes matter). Behaves like `off` if somehow active.
        case skip

        var displayLabel: String {
            switch self {
            case .scroll: return String(localized: "Scroll", comment: "Ring/strip action: scroll")
            case .keyPress: return String(localized: "Key", comment: "Ring/strip action: key press")
            case .off: return String(localized: "Off", comment: "Ring/strip action: disabled")
            case .skip:
                return String(
                    localized: "Skip",
                    comment: "Ring/strip action: slot left out of the mode cycle")
            case .zoom: return String(localized: "Zoom", comment: "Ring/strip action: analog pinch-zoom")
            case .rotate: return String(localized: "Rotate", comment: "Ring/strip action: analog rotate")
            }
        }

        /// Speed to land on when a slot is freshly switched *to* this
        /// action, for actions whose speed range isn't the shared
        /// `.scroll`/`.keyPress` multiplier — without this, switching a
        /// slot from Zoom (range 0...8) to Rotate (range 0...1) would carry
        /// over an out-of-range `speed`, silently running rotate far past
        /// its 1:1 ceiling. `nil` means "keep whatever speed was already
        /// set" (the `.scroll`/`.keyPress` multiplier has no natural
        /// ceiling to overflow). Both values land in the "Medium" bucket of
        /// `TouchRingModeList.bucketedSpeedLabel` (fraction 0.25) and are
        /// exact multiples of the UI's 0.25 snap step.
        var defaultSpeedOnSwitch: Double? {
            switch self {
            case .zoom: return 2.0
            case .rotate: return 0.25
            case .scroll, .keyPress, .off, .skip: return nil
            }
        }
    }
}
