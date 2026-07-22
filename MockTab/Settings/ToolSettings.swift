// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

/// Per-tool pressure curve, smoothing, and pen-button bindings.
///
/// Each physical pen body gets its own instance, keyed by serial number.
/// Reads fall through to `fallbackPrefix` (the device-level namespace) when
/// no tool-specific value has been stored, so existing device settings are
/// inherited automatically without migration.
///
/// Storage namespaces:
///   Default tool (serial = 0): "device-0x0357."          (same as devicePrefix)
///   Per-serial tool:           "device-0x0357.tool-0x21801D4E."
@MainActor
final class ToolSettings: ObservableObject {

    // MARK: - Identity

    /// Primary UserDefaults prefix for this tool's own overrides.
    let prefix: String

    /// Device-level prefix used as the fallback when no tool-specific value exists.
    /// Nil for the device-default ToolSettings (it IS the fallback).
    let fallbackPrefix: String?

    /// True when this tool is a cordless mouse rather than a stylus.
    /// Changes penButton2's factory default from middleClick to rightClick.
    let isMouse: Bool

    // MARK: - Settings

    @Published var pressureCurve: BezierCurve = .linear {
        didSet {
            savePressureCurve()
            pressureLUT = pressureCurve.buildLookupTable()
        }
    }

    /// 256-entry precomputed lookup table for `pressureCurve`.
    /// Rebuilt whenever `pressureCurve` changes (including on load from UserDefaults).
    /// Consumed by `InputInjector.inject()` — replaces per-report bisection with one array index.
    private(set) var pressureLUT: [Double] = BezierCurve.linear.buildLookupTable()

    @Published var smoothingStrength: Double = 0.0 {
        didSet { persist("smoothingStrength", smoothingStrength) }
    }

    @Published var pressureSmoothingStrength: Double = 0.0 {
        didSet { persist("pressureSmoothingStrength", pressureSmoothingStrength) }
    }

    /// Multiplier applied to Scroll Drag pan deltas (0.25 = slow, 1.0 = 1:1,
    /// 3.0 = fast). Per-tool so a heavy inking pen and a light sketching pen
    /// can pan at different rates.
    @Published var panScrollSpeed: Double = 1.0 {
        didSet { persist("panScrollSpeed", panScrollSpeed) }
    }

    /// When true, real tilt is suppressed and barrel rotation is sent as synthetic tilt
    /// instead — a "bait and switch" so Photoshop's Pen Tilt brush dynamics respond to
    /// barrel twist. Intended as a per-app opt-in (e.g. Adobe Photoshop); real tilt is
    /// sacrificed while this is enabled.
    @Published var useRotationAsTilt: Bool = false {
        didSet { persist("useRotationAsTilt", useRotationAsTilt) }
    }

    /// Offset (degrees) applied to barrel rotation before mapping to synthetic tilt.
    /// Lets users align "neutral" pen orientation with a desired brush angle.
    @Published var rotationTiltOffsetDegrees: Double = 0.0 {
        didSet { persist("rotationTiltOffsetDegrees", rotationTiltOffsetDegrees) }
    }

    /// Magnitude (0.0–1.0) of the synthetic tilt vector derived from rotation.
    /// Lower values reduce effective tilt range; 1.0 = full unit circle.
    @Published var rotationTiltMagnitude: Double = 0.8 {
        didSet { persist("rotationTiltMagnitude", rotationTiltMagnitude) }
    }

    @Published private var tipRaw: String = "" {
        didSet {
            persist("tipBinding", tipRaw)
            _tipBinding = ButtonBinding.decode(tipRaw) ?? .leftClick
        }
    }

    @Published private var eraserRaw: String = "" {
        didSet {
            persist("eraserBinding", eraserRaw)
            _eraserBinding = ButtonBinding.decode(eraserRaw) ?? .eraser
        }
    }

    private var _tipBinding: ButtonBinding = .leftClick
    private var _eraserBinding: ButtonBinding = .eraser

    var tipBinding: ButtonBinding {
        get { _tipBinding }
        set { tipRaw = newValue.encoded }
    }

    var eraserBinding: ButtonBinding {
        get { _eraserBinding }
        set { eraserRaw = newValue.encoded }
    }

    @Published private var pen1Raw: String = "" {
        didSet {
            persist("penButton1Binding", pen1Raw)
            _pen1Binding = ButtonBinding.decode(pen1Raw) ?? .rightClick
        }
    }

    @Published private var pen2Raw: String = "" {
        didSet {
            persist("penButton2Binding", pen2Raw)
            _pen2Binding = ButtonBinding.decode(pen2Raw) ?? (isMouse ? .rightClick : .middleClick)
        }
    }

    private var _pen1Binding: ButtonBinding = .rightClick
    private var _pen2Binding: ButtonBinding = .middleClick

    var penButton1Binding: ButtonBinding {
        get { _pen1Binding }
        set { pen1Raw = newValue.encoded }
    }

    var penButton2Binding: ButtonBinding {
        get { _pen2Binding }
        set { pen2Raw = newValue.encoded }
    }

    @Published private var pen3Raw: String = "" {
        didSet {
            persist("penButton3Binding", pen3Raw)
            _pen3Binding = ButtonBinding.decode(pen3Raw) ?? (isMouse ? .middleClick : .none)
        }
    }

    @Published private var pen4Raw: String = "" {
        didSet {
            persist("penButton4Binding", pen4Raw)
            _pen4Binding = ButtonBinding.decode(pen4Raw) ?? .none
        }
    }

    @Published private var pen5Raw: String = "" {
        didSet {
            persist("penButton5Binding", pen5Raw)
            _pen5Binding = ButtonBinding.decode(pen5Raw) ?? .none
        }
    }

    @Published private var wheelRaw: String = "" {
        didSet {
            persist("wheelBinding", wheelRaw)
            _wheelBinding = ButtonBinding.decode(wheelRaw) ?? .none
        }
    }

    private var _pen3Binding: ButtonBinding = .none
    private var _pen4Binding: ButtonBinding = .none
    private var _pen5Binding: ButtonBinding = .none
    private var _wheelBinding: ButtonBinding = .none

    var penButton3Binding: ButtonBinding {
        get { _pen3Binding }
        set { pen3Raw = newValue.encoded }
    }

    var penButton4Binding: ButtonBinding {
        get { _pen4Binding }
        set { pen4Raw = newValue.encoded }
    }

    var penButton5Binding: ButtonBinding {
        get { _pen5Binding }
        set { pen5Raw = newValue.encoded }
    }

    var wheelBinding: ButtonBinding {
        get { _wheelBinding }
        set { wheelRaw = newValue.encoded }
    }

    // MARK: - Override routing

    /// When non-nil, persist() and savePressureCurve() write here instead of
    /// the tool's own prefix.  Set by TabletSettings when an app override is active.
    var overridePrefix: String? = nil

    /// Called after a key is written to overridePrefix so TabletSettings can
    /// mark the key as overridden in the active AppOverride.
    var onOverrideKeyWritten: ((String) -> Void)? = nil

    // MARK: - Init

    private let ud = UserDefaults.standard
    var isLoading = false

    /// Set when the last load of `pressureCurve` found data but couldn't parse
    /// it — e.g. this is an older build than whatever wrote it. Blocks
    /// `savePressureCurve()` from clobbering that data. See TabletSettings'
    /// equivalent `*LoadFailed` flags.
    var pressureCurveLoadFailed = false

    /// Undo manager shared with the owning `TabletSettings` instance (see
    /// its `undoManager` for why this is the device's own manager, not
    /// something each window creates).
    weak var undoManager: UndoManager?

    init(prefix: String, fallbackPrefix: String? = nil, isMouse: Bool = false) {
        self.prefix = prefix
        self.fallbackPrefix = fallbackPrefix
        self.isMouse = isMouse
        reload()
    }

    /// Re-reads all values from UserDefaults (called after storage prefix changes).
    func reload() {
        isLoading = true
        smoothingStrength = loadDouble("smoothingStrength", default: 0.0)
        pressureSmoothingStrength = loadDouble("pressureSmoothingStrength", default: 0.0)
        panScrollSpeed = loadDouble("panScrollSpeed", default: 1.0)
        useRotationAsTilt = loadBool("useRotationAsTilt", default: false)
        rotationTiltOffsetDegrees = loadDouble("rotationTiltOffsetDegrees", default: 0.0)
        rotationTiltMagnitude = loadDouble("rotationTiltMagnitude", default: 0.8)
        tipRaw = loadString("tipBinding", default: "")
        eraserRaw = loadString("eraserBinding", default: "")
        pen1Raw = loadString("penButton1Binding", default: "")
        pen2Raw = loadString("penButton2Binding", default: "")
        pen3Raw = loadString("penButton3Binding", default: "")
        pen4Raw = loadString("penButton4Binding", default: "")
        pen5Raw = loadString("penButton5Binding", default: "")
        wheelRaw = loadString("wheelBinding", default: "")
        loadPressureCurve()
        isLoading = false
    }

    // MARK: - Persistence

    /// Reads `key` directly from UserDefaults, respecting the full lookup chain:
    /// active app override → tool-specific prefix → device-level fallback.
    /// Used by button-binding getters so values are always consistent with where
    /// `persist()` writes — both routes check `overridePrefix` first.
    private func freshString(_ key: String) -> String? {
        if let op = overridePrefix, let v = ud.string(forKey: op + key) { return v }
        if let v = ud.string(forKey: prefix + key) { return v }
        if let fb = fallbackPrefix, let v = ud.string(forKey: fb + key) { return v }
        return nil
    }

    private func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        if let op = overridePrefix {
            ud.set(value, forKey: op + key)
            onOverrideKeyWritten?(key)
        } else {
            ud.set(value, forKey: prefix + key)
        }
    }

    private func loadDouble(_ key: String, default d: Double) -> Double {
        if let op = overridePrefix, ud.object(forKey: op + key) != nil {
            return ud.double(forKey: op + key)
        }
        if ud.object(forKey: prefix + key) != nil { return ud.double(forKey: prefix + key) }
        if let fb = fallbackPrefix,
            ud.object(forKey: fb + key) != nil
        {
            return ud.double(forKey: fb + key)
        }
        return d
    }

    private func loadBool(_ key: String, default d: Bool) -> Bool {
        if let op = overridePrefix, ud.object(forKey: op + key) != nil {
            return ud.bool(forKey: op + key)
        }
        if ud.object(forKey: prefix + key) != nil { return ud.bool(forKey: prefix + key) }
        if let fb = fallbackPrefix,
            ud.object(forKey: fb + key) != nil
        {
            return ud.bool(forKey: fb + key)
        }
        return d
    }

    private func loadString(_ key: String, default d: String) -> String {
        return freshString(key) ?? d
    }

    /// Applies externally-resolved values (from a profile or app override) without
    /// triggering persistence writes.  Called by TabletSettings.reloadAll() so that
    /// PenFeel — which observes activeTool — stays in sync.
    func applyExternalValues(
        pressureCurve: BezierCurve, smoothingStrength: Double,
        pressureSmoothingStrength: Double
    ) {
        isLoading = true
        self.pressureCurve = pressureCurve
        self.smoothingStrength = smoothingStrength
        self.pressureSmoothingStrength = pressureSmoothingStrength
        self.useRotationAsTilt = false
        self.rotationTiltOffsetDegrees = 0.0
        self.rotationTiltMagnitude = 0.8
        isLoading = false
    }

    private func savePressureCurve() {
        guard !isLoading else { return }
        guard !pressureCurveLoadFailed else {
            settingsLogger.error("Refusing to save pressureCurve: last load couldn't parse existing data")
            return
        }
        guard let data = try? JSONEncoder().encode(pressureCurve) else { return }
        if let op = overridePrefix {
            ud.set(data, forKey: op + "pressureCurve")
            onOverrideKeyWritten?("pressureCurve")
        } else {
            ud.set(data, forKey: prefix + "pressureCurve")
        }
    }

    private func loadPressureCurve() {
        let data =
            overridePrefix.flatMap { ud.data(forKey: $0 + "pressureCurve") }
            ?? ud.data(forKey: prefix + "pressureCurve")
            ?? fallbackPrefix.flatMap { ud.data(forKey: $0 + "pressureCurve") }
            ?? ud.data(forKey: "pressureCurve")  // legacy unprefixed key
        guard let data else {
            pressureCurveLoadFailed = false
            return
        }
        guard let curve = try? JSONDecoder().decode(BezierCurve.self, from: data) else {
            // Data exists but this build can't parse it — likely a newer
            // version's format. Don't let a later save clobber it.
            pressureCurveLoadFailed = true
            settingsLogger.error("Tool pressureCurve data exists but failed to decode; blocking overwrite")
            return
        }
        pressureCurveLoadFailed = false
        pressureCurve = curve
    }

    // MARK: - Undo/Redo support

    /// Registers an undo action with the shared undoManager.
    /// See `TabletSettings.record` — same redo-via-re-registration mechanism.
    func record(_ actionName: String, undo: @escaping () -> Void) {
        guard let um = undoManager else { return }
        um.setActionName(actionName)
        um.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            undo()
        }
    }

    /// See `TabletSettings.recordToggle` — same single-value undo/redo shorthand.
    func recordToggle<T>(_ actionName: String, from oldValue: T, to newValue: T, apply: @escaping (T) -> Void) {
        record(actionName) { [weak self] in
            apply(oldValue)
            self?.recordToggle(actionName, from: newValue, to: oldValue, apply: apply)
        }
    }
}
