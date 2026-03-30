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
        didSet { savePressureCurve() }
    }

    @Published var smoothingStrength: Double = 0.0 {
        didSet { persist("smoothingStrength", smoothingStrength) }
    }

    @Published private var tipRaw: String = "" {
        didSet { persist("tipBinding", tipRaw) }
    }

    @Published private var eraserRaw: String = "" {
        didSet { persist("eraserBinding", eraserRaw) }
    }

    var tipBinding: ButtonBinding {
        get { ButtonBinding.decode(freshString("tipBinding") ?? "") ?? .leftClick }
        set { tipRaw = newValue.encoded }
    }

    var eraserBinding: ButtonBinding {
        get { ButtonBinding.decode(freshString("eraserBinding") ?? "") ?? .rightClick }
        set { eraserRaw = newValue.encoded }
    }

    @Published private var pen1Raw: String = "" {
        didSet { persist("penButton1Binding", pen1Raw) }
    }

    @Published private var pen2Raw: String = "" {
        didSet { persist("penButton2Binding", pen2Raw) }
    }

    var penButton1Binding: ButtonBinding {
        get { ButtonBinding.decode(freshString("penButton1Binding") ?? "") ?? .rightClick }
        set { pen1Raw = newValue.encoded }
    }

    var penButton2Binding: ButtonBinding {
        get {
            let defaultBinding: ButtonBinding = isMouse ? .rightClick : .middleClick
            return ButtonBinding.decode(freshString("penButton2Binding") ?? "") ?? defaultBinding
        }
        set { pen2Raw = newValue.encoded }
    }

    // MARK: - Init

    private let ud = UserDefaults.standard
    private var isLoading = false

    /// Suppresses undo registration when replaying undo/redo actions.
    var isUndoing = false

    /// Undo manager shared with TabletSettings, passed from SettingsWindowController.
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
        tipRaw = loadString("tipBinding", default: "")
        eraserRaw = loadString("eraserBinding", default: "")
        pen1Raw = loadString("penButton1Binding", default: "")
        pen2Raw = loadString("penButton2Binding", default: "")
        loadPressureCurve()
        isLoading = false
    }

    // MARK: - Persistence

    /// Reads `key` directly from UserDefaults, respecting the two-level fallback chain,
    /// without relying on the in-memory `@Published` cache.  Used by button-binding
    /// getters so that per-serial ToolSettings instances pick up device-default changes
    /// made in the UI without requiring an explicit `reload()`.
    private func freshString(_ key: String) -> String? {
        if let v = ud.string(forKey: prefix + key) { return v }
        if let fb = fallbackPrefix, let v = ud.string(forKey: fb + key) { return v }
        return nil
    }

    private func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        ud.set(value, forKey: prefix + key)
    }

    private func loadDouble(_ key: String, default d: Double) -> Double {
        if ud.object(forKey: prefix + key) != nil { return ud.double(forKey: prefix + key) }
        if let fb = fallbackPrefix,
            ud.object(forKey: fb + key) != nil
        {
            return ud.double(forKey: fb + key)
        }
        return d
    }

    private func loadString(_ key: String, default d: String) -> String {
        if let v = ud.string(forKey: prefix + key) { return v }
        if let fb = fallbackPrefix,
            let v = ud.string(forKey: fb + key)
        {
            return v
        }
        return d
    }

    private func savePressureCurve() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(pressureCurve) else { return }
        ud.set(data, forKey: prefix + "pressureCurve")
    }

    private func loadPressureCurve() {
        let data =
            ud.data(forKey: prefix + "pressureCurve")
            ?? fallbackPrefix.flatMap { ud.data(forKey: $0 + "pressureCurve") }
            ?? ud.data(forKey: "pressureCurve")  // legacy unprefixed key
        guard let data,
            let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
        else { return }
        pressureCurve = curve
    }

    // MARK: - Undo/Redo support

    /// Registers an undo action with the shared undoManager.
    /// Guards against registration during undo replay to prevent infinite loops.
    func record(_ actionName: String, undo: @escaping () -> Void) {
        guard let um = undoManager, !isUndoing else { return }
        um.setActionName(actionName)
        um.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            self.isUndoing = true
            undo()
            self.isUndoing = false
        }
    }
}
