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

    /// Clamps a candidate speed to `action.fixedSpeedCeiling`, if that
    /// action has one — a no-op for `.scroll`/`.keyPress`/`.off`/`.skip`,
    /// whose ceiling is UI-configurable (`maxSpeed`) rather than fixed.
    /// Shared write-side guard used by every "set this slot's speed"
    /// binding (`ButtonMappingBindings`'s slot0-3SpeedBinding,
    /// `ButtonMappingQuickKeys.slotSpeedBinding`), so a stored `speed` can
    /// never exceed its action's actual range regardless of which binding
    /// wrote it — see `Action.fixedSpeedCeiling`'s doc comment for the bug
    /// this (and the matching read-side clamp in `slotSpeedBinding`) fixed.
    static func clampedSpeed(_ speed: Double, for action: Action) -> Double {
        guard let ceiling = action.fixedSpeedCeiling else { return speed }
        return min(speed, ceiling)
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
        /// ceiling to overflow).
        ///
        /// Both values are the *center* notch of their slider — half of
        /// `fixedSpeedCeiling` — so a freshly switched slot starts at
        /// "Medium" with the thumb dead center. Keep these two facts
        /// together: "Medium is the default" and "Medium is centered" are
        /// both true only while this stays at the midpoint.
        var defaultSpeedOnSwitch: Double? {
            switch self {
            case .zoom: return 4.0
            case .rotate: return 0.5
            case .scroll, .keyPress, .off, .skip: return nil
            }
        }

        /// Fixed speed-slider ceiling for actions whose range isn't the
        /// shared, UI-configurable `maxSpeed` multiplier — `nil` for those
        /// (`.scroll`/`.keyPress`/`.off`/`.skip`), which take their ceiling
        /// from the caller instead (see `TouchRingModeList.speedRange(for:)`).
        /// The single source of truth for both the UI slider's range
        /// (`TouchRingModeList.speedRange(for:)` defers to this) and every
        /// binding's stored-value clamp (`ButtonMappingQuickKeys.
        /// slotSpeedBinding`, `ButtonMappingBindings`'s slot0-3SpeedBinding)
        /// — before this existed, `slotSpeedBinding`'s getter clamped to a
        /// stale scroll-only constant regardless of action, silently
        /// capping `.zoom`'s displayed/effective speed at 3.0 out of its
        /// intended 0...8 while the slider's thumb (and the speed label,
        /// reading the unclamped stored value) disagreed with each other —
        /// confirmed on hardware (Xencelabs puck, 2026-09): slider looked
        /// pinned around 37.5% of its travel yet read "Max".
        ///
        /// `.zoom`: hardware feedback (PTH-860, 2026-09) found the old
        /// shared 3x ceiling too low for a comfortable feel;
        /// `dialGestureZoomScale` (InputInjector+CGEvents.swift) has no
        /// physical 1:1 anchor to derive a ceiling from, so 8x is an
        /// empirical choice matching what felt right, with headroom above it.
        ///
        /// `.rotate`: `dialGestureRotateScale` is calibrated so 1x already
        /// means one full physical revolution of the capacitive ring = one
        /// full 360° canvas rotation — the ceiling is *derived*, not
        /// chosen, and identical across both ring-slot mechanisms (see that
        /// constant's doc comment for why the mechanical dial's own,
        /// different steps-per-revolution is handled by a device-specific
        /// scale, not by raising this ceiling).
        var fixedSpeedCeiling: Double? {
            switch self {
            case .zoom: return 8.0
            case .rotate: return 1.0
            case .scroll, .keyPress, .off, .skip: return nil
            }
        }

        /// Number of intervals on this action's speed slider — one fewer
        /// than the notch count (4 intervals = 5 notches). `nil` means a
        /// continuous slider (`.scroll`/`.keyPress`, whose speed is an
        /// open-ended multiplier read out as a number).
        ///
        /// Four is not a tidiness choice, it's forced by two constraints:
        ///
        /// 1. **Medium must sit at the visual center.** A notch lands on
        ///    the midpoint only when the interval count is *even*.
        /// 2. **Every notch must have a name.** These sliders read out a
        ///    qualitative label (Off/Low/Medium/High/Max) rather than a
        ///    number, and that vocabulary is exactly five words — the same
        ///    label also fills the collapsed mode-summary row, so it can
        ///    never be blank. More notches than labels would force the
        ///    readout to either repeat itself across adjacent notches
        ///    (which is the off-center bug this replaced, restated) or go
        ///    empty while the thumb visibly moves.
        ///
        /// Five labels + "even" ⇒ five notches. macOS's own sliders take
        /// the other branch of this fork — many notches, no moving readout,
        /// just end-caps ("Slow"…"Fast") — which isn't open to us while the
        /// summary row needs a word.
        ///
        /// This costs nothing in feel: smoothness comes from the hardware's
        /// per-tick resolution (`dialGestureRotateScale` et al.), not from
        /// the number of speed presets. The capacitive ring's 72 ticks/rev
        /// stay 5°/tick at full speed regardless of what's chosen here.
        ///
        /// **Deliberately `nil` for `.scroll`/`.keyPress`**, which keep a
        /// numeric readout. Those sliders still get tick marks (see
        /// `speedNotchStep`) — the visual treatment is shared; only the
        /// readout differs. Named levels don't extend to them because their
        /// number carries meaning a word would destroy: `speed` 1.0 is the
        /// native one-line-per-detent mapping, so any even-interval scheme
        /// over `maxSpeed`'s 0...3 either makes 1.0 unreachable (4 intervals
        /// ⇒ 0.75 steps) or labels it "Low" (6 intervals) — presenting the
        /// natural 1:1 default as the second-weakest setting. "2×" also
        /// simply tells a user more than "High" when the quantity is a
        /// multiplier they can reason about, which is not true of zoom's
        /// scale factor.
        var speedNotchIntervals: Int? {
            switch self {
            case .zoom, .rotate: return 4
            case .scroll, .keyPress, .off, .skip: return nil
            }
        }

        /// Distance between notches on this action's speed slider, for
        /// `Slider(value:in:step:)`. Rotate lands on clean quarter-turns
        /// (0.25 ⇒ 0/90/180/270/360° per ring revolution).
        ///
        /// `.scroll`/`.keyPress` return a flat 0.25 rather than dividing a
        /// ceiling: their range is the caller's `maxSpeed`, and 0.25 is the
        /// step their binding already snapped to invisibly — surfacing it as
        /// real tick marks makes the existing resolution legible and matches
        /// `PenFeelView`'s Pan Speed slider, which ships the same
        /// `0.25...3.0` range and 0.25 step. Every action returning a step
        /// means one `Slider(…step:)` branch serves them all.
        ///
        /// Note these two keep a *numeric* readout while `.zoom`/`.rotate`
        /// read out named levels — see `speedNotchIntervals` on why the
        /// named scheme can't extend here (it would land "Low" on 1.0×, the
        /// native one-line-per-detent mapping).
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
