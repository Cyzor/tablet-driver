// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "importer")

/// Parses and decodes JSON backup data into structured ImportPlan.
struct PresetImporter {

    enum ParseError: LocalizedError {
        case notJSON
        case wrongVersion(Int?)
        case noTablets

        var errorDescription: String? {
            switch self {
            case .notJSON:
                return String(localized: "Not a valid JSON file.", comment: "Import error — file could not be parsed as JSON")
            case .wrongVersion(let v):
                if let v {
                    return String(localized: "error.import.wrongVersion \(v)", comment: "Import error — incompatible backup format version")
                }
                return String(localized: "File is missing a version field.", comment: "Import error — no version key in backup file")
            case .noTablets:
                return String(localized: "No tablet data found in this file.", comment: "Import error — backup file has no tablet entries")
            }
        }
    }

    /// Parses JSON backup data into an ImportPlan.
    @MainActor
    static func parse(_ data: Data, registry: DeviceRegistry) throws -> ImportPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let version = root["version"] as? Int
        guard version == 2 else { throw ParseError.wrongVersion(version) }
        let sourceDate = root["exportedAt"] as? String ?? ""
        guard let tabletsRaw = root["tablets"] as? [[String: Any]], !tabletsRaw.isEmpty else {
            throw ParseError.noTablets
        }

        var entries: [ImportPlan.TabletEntry] = []
        for tabletDict in tabletsRaw {
            guard let pidStr = tabletDict["productID"] as? String,
                  let pid = Int(pidStr.dropFirst(2), radix: 16) else { continue }
            let modelName = tabletDict["modelName"] as? String ?? pidStr
            let nickname = tabletDict["nickname"] as? String ?? modelName
            let isKnown = registry.knownTablets.contains { $0.productID == pid }

            var values: [String: Any] = [:]
            if let s = tabletDict["settings"] as? [String: Any] {
                decodeDeviceSettings(s, into: &values)
            }

            var presets: [ImportPlan.PresetEntry] = []
            if let profilesRaw = tabletDict["profiles"] as? [[String: Any]] {
                for p in profilesRaw {
                    guard let name = p["name"] as? String else { continue }
                    let settingsDict = p["settings"] as? [String: Any] ?? [:]
                    presets.append(ImportPlan.PresetEntry(name: name, values: decodeStoredSettings(settingsDict)))
                }
            }

            // Device-level appOverrides only — the per-tool copies nested inside
            // "tools" are a filtered subset of the same bundleIDs and would
            // either double-process or drop non-tool keys if read as well.
            var overrides: [ImportPlan.OverrideEntry] = []
            if let overridesRaw = tabletDict["appOverrides"] as? [[String: Any]] {
                for o in overridesRaw {
                    guard let bundleID = o["bundleID"] as? String, !bundleID.isEmpty else { continue }
                    let appName = o["app"] as? String ?? bundleID
                    let settingsDict = o["settings"] as? [String: Any] ?? [:]
                    overrides.append(ImportPlan.OverrideEntry(
                        bundleID: bundleID, appName: appName,
                        values: decodeStoredSettings(settingsDict)))
                }
            }

            var toolEntries: [ImportPlan.ToolEntry] = []
            if let toolsRaw = tabletDict["tools"] as? [[String: Any]] {
                for t in toolsRaw {
                    guard let toolID = t["id"] as? String else { continue }
                    let kind = t["kind"] as? String ?? toolID
                    let settingsDict = t["settings"] as? [String: Any] ?? [:]
                    toolEntries.append(ImportPlan.ToolEntry(
                        toolID: toolID, kind: kind,
                        values: decodeStoredSettings(settingsDict)))
                }
            }

            entries.append(ImportPlan.TabletEntry(
                productID: pid,
                modelName: modelName,
                nickname: nickname,
                resolvedProfileName: nickname,
                profileValues: values,
                isKnown: isKnown,
                presets: presets,
                overrides: overrides,
                toolSettings: toolEntries,
            ))
        }

        if entries.isEmpty { throw ParseError.noTablets }
        return ImportPlan(sourceDate: sourceDate, entries: entries)
    }

    // MARK: - Decoders

    static func decodeDeviceSettings(_ s: [String: Any], into values: inout [String: Any]) {
        if let area = s["tabletArea"] as? [String: Any] {
            if let v = area["x"] as? Double, v.isFinite, v >= 0, v <= 1 { values["activeAreaX"] = v }
            if let v = area["y"] as? Double, v.isFinite, v >= 0, v <= 1 { values["activeAreaY"] = v }
            if let v = area["width"] as? Double, v.isFinite, v > 0, v <= 1 { values["activeAreaWidth"] = v }
            if let v = area["height"] as? Double, v.isFinite, v > 0, v <= 1 { values["activeAreaHeight"] = v }
            if let v = area["proportionalMapping"] as? Bool { values["proportionalMapping"] = v }
            if let v = area["orientationKey"] as? Int {
                values["tabletOrientation"] = v
            } else if let v = area["orientation"] as? String {
                values["tabletOrientation"] = decodeOrientation(v)
            }
        }
        if let v = s["display"] { values["targetDisplayIndex"] = decodeDisplay(v) }
        if let v = s["smoothing"] as? Double, v.isFinite, v >= 0, v <= 1 { values["smoothingStrength"] = v }
        if let v = s["doubleClickDistance"] as? Double, v.isFinite, v > 0, v <= 200 { values["doubleClickDistance"] = v }
        if let v = s["invertRotation"] as? Bool { values["invertRotation"] = v }
        if let v = s["relativeCursorMovement"] as? Bool { values["relativeCursorMovement"] = v }
        if let v = s["penButton1Key"] as? String, !v.isEmpty {
            values["penButton1Binding"] = (ButtonBinding.decode(v) ?? .none).encoded
        } else if let v = s["penButton1"] as? String, !v.isEmpty {
            values["penButton1Binding"] = ButtonBinding.fromDisplayLabel(v).encoded
        }
        if let v = s["penButton2Key"] as? String, !v.isEmpty {
            values["penButton2Binding"] = (ButtonBinding.decode(v) ?? .none).encoded
        } else if let v = s["penButton2"] as? String, !v.isEmpty {
            values["penButton2Binding"] = ButtonBinding.fromDisplayLabel(v).encoded
        }
        if let v = s["touchRingButtonKey"] as? String, !v.isEmpty {
            values["touchRingButtonBinding"] = (ButtonBinding.decode(v) ?? .none).encoded
        } else if let v = s["touchRingButton"] as? String, !v.isEmpty {
            values["touchRingButtonBinding"] = ButtonBinding.fromDisplayLabel(v).encoded
        }
        if let v = s["touchRingKey"] as? String {
            values["touchRingMode"] = (TouchRingMode(rawValue: v) ?? .off).rawValue
        } else if let v = s["touchRing"] as? String {
            values["touchRingMode"] = decodeTouchRingMode(v)
        }
        if let v = s["touchStrip1Key"] as? String {
            values["touchStrip1Mode"] = (TouchRingMode(rawValue: v) ?? .off).rawValue
        } else if let v = s["touchStrip1"] as? String {
            values["touchStrip1Mode"] = decodeTouchRingMode(v)
        }
        if let v = s["touchStrip2Key"] as? String {
            values["touchStrip2Mode"] = (TouchRingMode(rawValue: v) ?? .off).rawValue
        } else if let v = s["touchStrip2"] as? String {
            values["touchStrip2Mode"] = decodeTouchRingMode(v)
        }
        if let v = s["expressKeysKey"] as? [String] {
            values["expressKeyBindings"] = decodeExpressKeysFromKeys(v)
        } else if let v = s["expressKeys"] as? [String] {
            values["expressKeyBindings"] = decodeExpressKeys(v)
        }
        if let v = s["pressureCurve"] as? [String: Any], let data = decodeCurveData(v) {
            values["pressureCurve"] = data
        }
    }

    /// Decodes a preset/app-override/tool "settings" dict — as produced by
    /// `PresetExporter.readUDValue` — into UserDefaults-ready key/value pairs.
    ///
    /// Unlike `decodeDeviceSettings` (which maps friendlier export-only key
    /// names like "orientation"/"penButton1" to their storage keys), this
    /// dict is already keyed by the literal storage key names
    /// ("tabletOrientation", "penButton1Binding", "touchRingMode", ...),
    /// since it comes straight from `readUDValue`. Each binding/enum field
    /// prefers its locale-independent "...Key" sibling when present, falling
    /// back to the (English-only) label for files exported before that
    /// existed — same dual-path pattern as `decodeDeviceSettings`.
    static func decodeStoredSettings(_ s: [String: Any]) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in s.keys where !key.hasSuffix("Key") {
            let rawValue = s[key] as Any
            switch key {
            case "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
                 "smoothingStrength", "doubleClickDistance":
                if let v = rawValue as? Double, v.isFinite { values[key] = v }

            case "proportionalMapping", "invertRotation", "relativeCursorMovement":
                if let v = rawValue as? Bool { values[key] = v }

            case "targetDisplayIndex":
                values[key] = decodeDisplay(rawValue)

            case "toggleDisplayIDs":
                if let arr = rawValue as? [String] { values[key] = arr.joined(separator: ",") }

            case "tabletOrientation":
                if let v = s["tabletOrientationKey"] as? Int {
                    values[key] = v
                } else if let v = rawValue as? String {
                    values[key] = decodeOrientation(v)
                }

            case "penButton1Binding", "penButton2Binding",
                 "touchRingButtonBinding", "tipBinding", "eraserBinding":
                if let v = s[key + "Key"] as? String, !v.isEmpty {
                    values[key] = (ButtonBinding.decode(v) ?? .none).encoded
                } else if let v = rawValue as? String, !v.isEmpty {
                    values[key] = ButtonBinding.fromDisplayLabel(v).encoded
                }

            case "expressKeyBindings":
                if let v = s["expressKeyBindingsKey"] as? [String] {
                    values[key] = decodeExpressKeysFromKeys(v)
                } else if let v = rawValue as? [String] {
                    values[key] = decodeExpressKeys(v)
                }

            case "touchRingMode", "touchStrip1Mode", "touchStrip2Mode":
                if let v = s[key + "Key"] as? String {
                    values[key] = (TouchRingMode(rawValue: v) ?? .off).rawValue
                } else if let v = rawValue as? String {
                    values[key] = decodeTouchRingMode(v)
                }

            case "pressureCurve":
                if let d = rawValue as? [String: Any], let data = decodeCurveData(d) {
                    values[key] = data
                }

            case "touchRingSlotsJSON", "calibrationJSON":
                if let v = rawValue as? String { values[key] = v }

            case "touchRingActiveSlotIndex":
                if let v = rawValue as? Int { values[key] = v }

            default:
                break
            }
        }
        return values
    }

    /// English-only, label-based orientation decode — kept for files exported
    /// before `orientationKey` existed. New exports carry the locale-independent
    /// `orientationKey` (the raw `TabletOrientation` value) and prefer it.
    static func decodeOrientation(_ label: String) -> Int {
        switch label {
        case "Portrait": return 1
        case "Landscape Flipped": return 2
        case "Portrait Flipped": return 3
        default: return 0
        }
    }

    static func decodeDisplay(_ value: Any) -> Int {
        if let s = value as? String {
            switch s {
            case "primary": return 0
            case "all": return TabletSettings.displayModeAll
            case "toggle": return TabletSettings.displayModeToggle
            default:
                if s.hasPrefix("display-"), let n = Int(s.dropFirst(8)) { return n }
                return 0
            }
        }
        if let d = value as? [String: Any], (d["mode"] as? String) == "toggle" {
            return TabletSettings.displayModeToggle
        }
        return 0
    }

    /// English-only, label-based decode — kept for files exported before
    /// `touchRingKey`/`touchStrip*Key` existed. New exports carry the
    /// locale-independent `TouchRingMode.rawValue` and prefer it.
    static func decodeTouchRingMode(_ label: String) -> String {
        switch label {
        case "Scroll": return TouchRingMode.scroll.rawValue
        default: return TouchRingMode.off.rawValue
        }
    }

    /// English-only, label-based decode — kept for files exported before
    /// `expressKeysKey` existed. New exports carry each binding's encoded
    /// `ButtonBinding` form and prefer it (`decodeExpressKeysFromKeys`).
    static func decodeExpressKeys(_ labels: [String]) -> String {
        var bindings = labels.map { $0.isEmpty ? ButtonBinding.none : ButtonBinding.fromDisplayLabel($0) }
        while bindings.count < 16 { bindings.append(.none) }
        return encodeBindingArray(bindings)
    }

    /// Locale-independent express-key decode: each entry is an encoded
    /// `ButtonBinding` (from `ButtonBinding.encoded`), not a display label.
    static func decodeExpressKeysFromKeys(_ keys: [String]) -> String {
        var bindings = keys.map { $0.isEmpty ? ButtonBinding.none : (ButtonBinding.decode($0) ?? .none) }
        while bindings.count < 16 { bindings.append(.none) }
        return encodeBindingArray(bindings)
    }

    private static func encodeBindingArray(_ bindings: [ButtonBinding]) -> String {
        let arr = Array(bindings.prefix(16))
        guard let data = try? JSONEncoder().encode(arr), let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s
    }

    static func decodeCurveData(_ d: [String: Any]) -> Data? {
        guard let p1arr = d["p1"] as? [Double], p1arr.count == 2,
              let p2arr = d["p2"] as? [Double], p2arr.count == 2 else { return nil }
        let curve = BezierCurve(
            p1: CGPoint(x: p1arr[0], y: p1arr[1]),
            p2: CGPoint(x: p2arr[0], y: p2arr[1])
        )
        return try? JSONEncoder().encode(curve)
    }
}
