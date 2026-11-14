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
    var action: Action = .scroll {
        didSet { unrecognizedAction = nil }
    }
    /// Key binding for clockwise rotation (used when action == .keyPress).
    var cwBinding: ButtonBinding = .none
    /// Key binding for counter-clockwise rotation (used when action == .keyPress).
    var ccwBinding: ButtonBinding = .none
    /// Speed multiplier applied to ring/strip delta before scroll/key dispatch.
    /// 1.0 = native one-line-per-detent; 0.25 = slowest; 3.0 = fastest.
    var speed: Double = 1.0
    /// Dial LED color for this mode (Xencelabs Quick Keys only; Wacom LEDs
    /// are single-color). nil uses the factory palette. Raw sRGB bytes,
    /// uncalibrated so modes stay distinct; brightness is kept in `a`.
    var ledColor: LEDColor?

    /// Fields a future app version added that this build doesn't know about.
    /// Preserved verbatim on re-encode — see TabletSettings.Profile.unknownFields.
    private var unknownFields: [String: JSONValue] = [:]

    /// An action from a newer build. It acts as `.off` here but is written
    /// back unchanged, so the slot keeps it for the newer build. Cleared when
    /// the user picks another action.
    private var unrecognizedAction: String?

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
        let rawAction = try c.decode(String.self, forKey: .action)
        action = Action(rawValue: rawAction) ?? .off
        unrecognizedAction = Action(rawValue: rawAction) == nil ? rawAction : nil
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
        try c.encode(unrecognizedAction ?? action.rawValue, forKey: .action)
        try c.encode(cwBinding, forKey: .cwBinding)
        try c.encode(ccwBinding, forKey: .ccwBinding)
        try c.encode(speed, forKey: .speed)
        try c.encodeIfPresent(ledColor, forKey: .ledColor)
        try UnknownFieldsCodec.encodeUnknown(unknownFields, to: encoder)
    }

    /// Limits `speed` to the action's fixed ceiling, if it has one. Every
    /// binding that writes a slot's speed goes through this, so a stored
    /// speed never exceeds its action's range.
    static func clampedSpeed(_ speed: Double, for action: Action) -> Double {
        guard let ceiling = action.fixedSpeedCeiling else { return speed }
        return min(speed, ceiling)
    }

    /// Changes the action, resetting `speed` to the new action's default if
    /// it has one, and the label to the action's name, since a slot has no
    /// rename UI. Use this rather than setting `action` directly, which can
    /// carry an out-of-range speed (Zoom's 0...8 into Rotate's 0...1) or a
    /// stale label.
    mutating func setAction(_ newAction: Action) {
        guard newAction != action || unrecognizedAction != nil else { return }
        action = newAction
        label = newAction.displayLabel
        if let defaultSpeed = newAction.defaultSpeedOnSwitch {
            speed = defaultSpeed
        }
    }

    static func == (lhs: ControlSlot, rhs: ControlSlot) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label && lhs.action == rhs.action
            && lhs.unrecognizedAction == rhs.unrecognizedAction
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

    /// What this mode does, in a word or two: its action, or its keys for a
    /// key mode.
    var functionName: String {
        guard action == .keyPress, cwBinding.kind != .none || ccwBinding.kind != .none else {
            return action.displayLabel
        }
        return "\(cwBinding.displayLabel) / \(ccwBinding.displayLabel)"
    }

    /// Cintiq 24HD rings: three modes, each with its own key beside the ring.
    /// The 21UX2's strips start with the same modes.
    static let splitPadDefaults: [ControlSlot] = [
        ControlSlot(label: String(localized: "Scroll", comment: "Default ring slot label"), action: .scroll),
        ControlSlot(label: String(localized: "Zoom", comment: "Ring/strip action: analog pinch-zoom"), action: .zoom),
        ControlSlot(label: String(localized: "Rotate", comment: "Ring/strip action: analog rotate"), action: .rotate),
        ControlSlot(label: String(localized: "Off", comment: "Default ring slot label"), action: .off),
    ]

    /// Declaration order is the Action picker's display order (via
    /// `allCases`) — Scroll, Zoom, Rotate, Key, Off, Skip. Raw-value coding
    /// means reordering these cases doesn't affect persisted data.
    enum Action: String, Codable, CaseIterable {
        case scroll
        /// Analog pinch-zoom, posted like a trackpad pinch
        /// (`InputInjector.postTouchMagnify`), not the stepped
        /// modifier-plus-wheel zoom `.scroll` uses.
        case zoom
        /// Analog rotate, posted like a trackpad twist
        /// (`InputInjector.postTouchRotate`).
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

        /// Glyph for the dial-mode badge (`TouchRingModeList`'s stand-in for
        /// the mode LED this hardware doesn't have).
        ///
        /// `.rotate`'s symbol postdates our macOS 13 floor, so it carries a
        /// fallback the badge resolves at runtime — see
        /// `TouchRingModeList.resolvedSymbol`. `crop.rotate` is the same
        /// gesture drawn on a crop frame, which reads as "straighten a photo"
        /// rather than "turn the canvas"; it stands in only where the better
        /// glyph doesn't exist.
        ///
        /// `nil` for `.skip`: a skipped slot is passed over by the mode cycle,
        /// so it can never be the active mode the badge reports.
        var symbolName: String? {
            switch self {
            case .scroll: return "arrow.up.arrow.down"
            case .zoom: return "square.arrowtriangle.4.outward"
            case .rotate: return "rectangle.landscape.rotate"
            case .keyPress: return "keyboard"
            case .off: return "circle.dashed"
            case .skip: return nil
            }
        }

        /// Stand-in for `symbolName` where it doesn't exist yet; nil when the
        /// preferred glyph ships on every system we run on.
        var symbolFallbackName: String? {
            switch self {
            case .rotate: return "crop.rotate"
            case .zoom: return "arrow.up.left.and.arrow.down.right"
            default: return nil
            }
        }

        /// The speed a slot gets when switched to this action, for actions
        /// with their own range. Without it, Zoom's speed (0...8) would carry
        /// into Rotate (0...1). `nil` keeps the current speed.
        ///
        /// Each value is half of `fixedSpeedCeiling`, so a switched slot
        /// starts at Medium with the thumb centered. Keep it at the midpoint.
        var defaultSpeedOnSwitch: Double? {
            switch self {
            case .zoom: return 4.0
            case .rotate: return 0.5
            case .scroll, .keyPress, .off, .skip: return nil
            }
        }

        /// The speed slider's ceiling for actions with a fixed range; `nil`
        /// for those that use the shared `maxSpeed`. The slider's range and
        /// every binding's clamp read this, so the thumb and its label agree.
        ///
        /// Zoom has no physical 1:1 to derive from, so 8 is chosen by feel,
        /// with headroom. Rotate's 1 means one ring revolution turns the
        /// canvas once, so its ceiling is derived, not chosen.
        var fixedSpeedCeiling: Double? {
            switch self {
            case .zoom: return 8.0
            case .rotate: return 1.0
            case .scroll, .keyPress, .off, .skip: return nil
            }
        }

        /// Intervals on the speed slider (4 intervals = 5 notches); `nil`
        /// for a continuous slider.
        ///
        /// Four is forced: Medium must sit at the center, which needs an even
        /// count, and every notch needs one of five names (Off, Low, Medium,
        /// High, Max), which the collapsed summary row also shows. Smoothness
        /// comes from the hardware's per-tick resolution, not the number of
        /// presets.
        ///
        /// Scroll and Key keep a numeric readout: 1.0 is the native one line
        /// per detent, and no even split of 0...3 both reaches 1.0 and avoids
        /// calling it "Low".
        var speedNotchIntervals: Int? {
            switch self {
            case .zoom, .rotate: return 4
            case .scroll, .keyPress, .off, .skip: return nil
            }
        }

        /// Distance between notches, for `Slider(value:in:step:)`. Rotate
        /// lands on quarter turns. Scroll and Key use 0.25, the step their
        /// binding already snapped to, matching the Pan Speed slider.
        var speedNotchStep: Double? {
            switch self {
            case .scroll, .keyPress, .off, .skip:
                return 0.25
            case .zoom, .rotate:
                guard let ceiling = fixedSpeedCeiling,
                      let intervals = speedNotchIntervals, intervals > 0
                else { return nil }
                return ceiling / Double(intervals)
            }
        }
    }
}
