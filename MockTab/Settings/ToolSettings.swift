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

    // MARK: - Settings

    @Published var pressureCurve: BezierCurve = .linear {
        didSet { savePressureCurve() }
    }

    @Published var smoothingStrength: Double = 0.0 {
        didSet { persist("smoothingStrength", smoothingStrength) }
    }

    @Published private var pen1Raw: String = "" {
        didSet { persist("penButton1Binding", pen1Raw) }
    }

    @Published private var pen2Raw: String = "" {
        didSet { persist("penButton2Binding", pen2Raw) }
    }

    var penButton1Binding: ButtonBinding {
        get { ButtonBinding.decode(pen1Raw) ?? .rightClick }
        set { pen1Raw = newValue.encoded }
    }

    var penButton2Binding: ButtonBinding {
        get { ButtonBinding.decode(pen2Raw) ?? .middleClick }
        set { pen2Raw = newValue.encoded }
    }

    // MARK: - Init

    private let ud = UserDefaults.standard
    private var isLoading = false

    init(prefix: String, fallbackPrefix: String? = nil) {
        self.prefix = prefix
        self.fallbackPrefix = fallbackPrefix
        reload()
    }

    /// Re-reads all values from UserDefaults (called after storage prefix changes).
    func reload() {
        isLoading = true
        smoothingStrength = loadDouble("smoothingStrength", default: 0.0)
        pen1Raw           = loadString("penButton1Binding", default: "")
        pen2Raw           = loadString("penButton2Binding", default: "")
        loadPressureCurve()
        isLoading = false
    }

    // MARK: - Persistence

    private func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        ud.set(value, forKey: prefix + key)
    }

    private func loadDouble(_ key: String, default d: Double) -> Double {
        if ud.object(forKey: prefix + key) != nil     { return ud.double(forKey: prefix + key) }
        if let fb = fallbackPrefix,
           ud.object(forKey: fb + key) != nil         { return ud.double(forKey: fb + key) }
        return d
    }

    private func loadString(_ key: String, default d: String) -> String {
        if let v = ud.string(forKey: prefix + key)    { return v }
        if let fb = fallbackPrefix,
           let v  = ud.string(forKey: fb + key)       { return v }
        return d
    }

    private func savePressureCurve() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(pressureCurve) else { return }
        ud.set(data, forKey: prefix + "pressureCurve")
    }

    private func loadPressureCurve() {
        let data = ud.data(forKey: prefix + "pressureCurve")
            ?? fallbackPrefix.flatMap { ud.data(forKey: $0 + "pressureCurve") }
            ?? ud.data(forKey: "pressureCurve")  // legacy unprefixed key
        guard let data,
              let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
        else { return }
        pressureCurve = curve
    }
}
