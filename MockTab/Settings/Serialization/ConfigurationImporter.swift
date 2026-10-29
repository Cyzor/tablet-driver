// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "importer")

/// Parses and decodes JSON backup data into structured ImportPlan.
struct ConfigurationImporter {

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

            var presets: [ImportPlan.ProfileEntry] = []
            if let profilesRaw = tabletDict["profiles"] as? [[String: Any]] {
                for p in profilesRaw {
                    guard let name = p["name"] as? String else { continue }
                    let settingsDict = p["settings"] as? [String: Any] ?? [:]
                    presets.append(ImportPlan.ProfileEntry(name: name, values: decodeStoredSettings(settingsDict)))
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
                        values: decodeToolSettings(settingsDict)))
                }
            }

            entries.append(ImportPlan.TabletEntry(
                productID: pid,
                modelName: modelName,
                nickname: nickname,
                resolvedProfileName: nickname,
                profileValues: values,
                isKnown: isKnown,
                profiles: presets,
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
            } else if let v = area["orientation"] as? String, let o = decodeOrientation(v) {
                values["tabletOrientation"] = o
            }
        }
        if let v = s["display"] {
            values["targetDisplayIndex"] = decodeDisplay(v)
            values["targetDisplayUUID"] = decodeDisplayUUID(v)
            if let ids = decodeDisplaySet(v) { values["toggleDisplayIDs"] = ids }
        }
        // Absent in files exported before tablet-driver#15 — leaving these
        // unset here means TabletSettings.reloadAll()'s defaults (0,0,1,1,
        // i.e. full display) apply, which matches every build's behavior
        // before this feature existed.
        if let region = s["displayRegion"] as? [String: Any] {
            if let v = region["x"] as? Double, v.isFinite, v >= 0, v <= 1 { values["displayRegionX"] = v }
            if let v = region["y"] as? Double, v.isFinite, v >= 0, v <= 1 { values["displayRegionY"] = v }
            if let v = region["width"] as? Double, v.isFinite, v > 0, v <= 1 { values["displayRegionWidth"] = v }
            if let v = region["height"] as? Double, v.isFinite, v > 0, v <= 1 { values["displayRegionHeight"] = v }
        }
        if let v = s["smoothing"] as? Double, v.isFinite, v >= 0, v <= 1 { values["smoothingStrength"] = v }
        if let v = s["doubleClickDistance"] as? Double, v.isFinite, v > 0, v <= 200 { values["doubleClickDistance"] = v }
        if let v = s["invertRotation"] as? Bool { values["invertRotation"] = v }
        if let v = s["relativeCursorMovement"] as? Bool { values["relativeCursorMovement"] = v }
        if let v = s["requireContact"] as? Int { values["requireContact"] = v }
        if let v = ButtonBinding.importedValue(key: s["penButton1Key"] as? String, label: s["penButton1"] as? String) {
            values["penButton1Binding"] = v
        }
        if let v = ButtonBinding.importedValue(key: s["penButton2Key"] as? String, label: s["penButton2"] as? String) {
            values["penButton2Binding"] = v
        }
        if let v = ButtonBinding.importedValue(key: s["touchRingButtonKey"] as? String, label: s["touchRingButton"] as? String) {
            values["touchRingButtonBinding"] = v
        }
        if let v = ButtonBinding.importedValue(key: s["touchRingButton2Key"] as? String, label: nil) {
            values["touchRingButtonBinding2"] = v
        }
        if let v = s["reverseRingDirection"] as? Bool { values["reverseRingDirection"] = v }
        if let v = s["touchRingActiveSlotIndex"] as? Int { values["touchRingActiveSlotIndex"] = v }
        if let v = s["touchRingActiveSlotIndex2"] as? Int { values["touchRingActiveSlotIndex2"] = v }
        if let v = s["touchRingSlots"], let data = decodeSlotsData(v) {
            values["touchRingSlotsJSON"] = data
        }
        if let v = s["rotaries"], let data = decodeRotariesData(v) {
            values["rotariesJSON"] = data
        }
        if let v = s["touchRingKey"] as? String {
            values["touchRingMode"] = (TouchRingMode(rawValue: v) ?? .off).rawValue
        } else if let v = s["touchRing"] as? String, let mode = decodeTouchRingMode(v) {
            values["touchRingMode"] = mode
        }
        if let v = s["touchStrip1Key"] as? String {
            values["touchStrip1Mode"] = (TouchRingMode(rawValue: v) ?? .off).rawValue
        } else if let v = s["touchStrip1"] as? String, let mode = decodeTouchRingMode(v) {
            values["touchStrip1Mode"] = mode
        }
        if let v = s["touchStrip2Key"] as? String {
            values["touchStrip2Mode"] = (TouchRingMode(rawValue: v) ?? .off).rawValue
        } else if let v = s["touchStrip2"] as? String, let mode = decodeTouchRingMode(v) {
            values["touchStrip2Mode"] = mode
        }
        if let v = s["expressKeysKey"] as? [String] {
            if let keys = decodeExpressKeysFromKeys(v) { values["expressKeyBindings"] = keys }
        } else if let v = s["expressKeys"] as? [String], let keys = decodeExpressKeys(v) {
            values["expressKeyBindings"] = keys
        }
        if let v = s["pressureCurve"] as? [String: Any], let data = decodeCurveData(v) {
            values["pressureCurve"] = data
        }
    }

    /// Decodes a tool's "settings" dict. Files before storage-key names wrote
    /// `smoothing`, `tip`, `eraser`, `penButton1`, and `penButton2`, as labels
    /// only; those are renamed, and a label naming no action is skipped
    /// rather than imported as None.
    static func decodeToolSettings(_ s: [String: Any]) -> [String: Any] {
        var renamed = s
        if renamed["smoothingStrength"] == nil, let v = s["smoothing"] { renamed["smoothingStrength"] = v }
        let legacyBindings = [
            ("tip", "tipBinding"), ("eraser", "eraserBinding"),
            ("penButton1", "penButton1Binding"), ("penButton2", "penButton2Binding"),
        ]
        for (old, new) in legacyBindings where renamed[new] == nil {
            if let label = s[old] { renamed[new] = label }
        }
        return decodeStoredSettings(renamed)
    }

    /// Decodes a profile/app-override/tool "settings" dict — as produced by
    /// `ConfigurationExporter.readUDValue` — into UserDefaults-ready key/value pairs.
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
                 "displayRegionX", "displayRegionY", "displayRegionWidth", "displayRegionHeight",
                 "smoothingStrength", "doubleClickDistance",
                 "pressureSmoothingStrength", "pressureThreshold", "panScrollSpeed":
                if let v = rawValue as? Double, v.isFinite { values[key] = v }

            case "proportionalMapping", "invertRotation", "relativeCursorMovement", "reverseRingDirection",
                 "panScrollMomentum":
                if let v = rawValue as? Bool { values[key] = v }

            case "targetDisplayIndex":
                values[key] = decodeDisplay(rawValue)

            case "targetDisplayUUID":
                if let v = rawValue as? String { values[key] = v }

            case "toggleDisplayIDs":
                if let arr = rawValue as? [String] { values[key] = arr.joined(separator: ",") }

            case "tabletOrientation":
                if let v = s["tabletOrientationKey"] as? Int {
                    values[key] = v
                } else if let v = rawValue as? String, let o = decodeOrientation(v) {
                    values[key] = o
                }

            case "penButton1Binding", "penButton2Binding", "penButton3Binding", "penButton4Binding",
                 "penButton5Binding", "wheelBinding",
                 "touchRingButtonBinding", "touchRingButtonBinding2", "tipBinding", "eraserBinding":
                if let v = ButtonBinding.importedValue(key: s[key + "Key"] as? String, label: rawValue as? String) {
                    values[key] = v
                }

            case "expressKeyBindings":
                if let v = s["expressKeyBindingsKey"] as? [String] {
                    if let keys = decodeExpressKeysFromKeys(v) { values[key] = keys }
                } else if let v = rawValue as? [String], let keys = decodeExpressKeys(v) {
                    values[key] = keys
                }

            case "touchRingMode", "touchStrip1Mode", "touchStrip2Mode":
                if let v = s[key + "Key"] as? String {
                    values[key] = (TouchRingMode(rawValue: v) ?? .off).rawValue
                } else if let v = rawValue as? String, let mode = decodeTouchRingMode(v) {
                    values[key] = mode
                }

            case "pressureCurve":
                if let d = rawValue as? [String: Any], let data = decodeCurveData(d) {
                    values[key] = data
                }

            // Stored as Data, which the app reads with `data(forKey:)`.
            case "touchRingSlotsJSON":
                if let data = decodeSlotsData(rawValue) { values[key] = data }

            case "rotariesJSON":
                if let data = decodeRotariesData(rawValue) { values[key] = data }

            case "calibrationJSON":
                if let v = rawValue as? String { values[key] = v }

            case "touchRingActiveSlotIndex", "touchRingActiveSlotIndex2", "requireContact":
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
    /// Nil for a label in another language, so the import leaves it unset.
    static func decodeOrientation(_ label: String) -> Int? {
        switch label {
        case "Landscape": return 0
        case "Portrait": return 1
        case "Landscape Flipped": return 2
        case "Portrait Flipped": return 3
        default: return nil
        }
    }

    static func decodeDisplay(_ value: Any) -> Int {
        if let s = value as? String {
            switch s {
            case "primary": return 0
            case "all": return TabletSettings.displayModeAll
            case "toggle": return TabletSettings.displayModeToggle
            case "span": return TabletSettings.displayModeSpan
            default:
                if s.hasPrefix("display-"), let n = Int(s.dropFirst(8)) { return n }
                return 0
            }
        }
        if let d = value as? [String: Any], let mode = d["mode"] as? String {
            if mode == "toggle" { return TabletSettings.displayModeToggle }
            if mode == "span" { return TabletSettings.displayModeSpan }
            if mode == "display", let n = d["index"] as? Int, n > 0 { return n }
        }
        return 0
    }

    /// The recorded display of a `{"mode": "display"}` value; "" otherwise,
    /// so an older `display-N` import falls back to list position.
    static func decodeDisplayUUID(_ value: Any) -> String {
        guard let d = value as? [String: Any], d["mode"] as? String == "display",
            let uuid = d["uuid"] as? String
        else { return "" }
        return uuid
    }

    /// Toggle or Span displays as stored UUIDs. Older exports wrote
    /// session-only display numbers, which can't be matched and are skipped.
    static func decodeDisplaySet(_ value: Any) -> String? {
        guard let d = value as? [String: Any], let arr = d["displays"] as? [String] else { return nil }
        let uuids = arr.filter { $0.contains("-") }
        return uuids.isEmpty ? nil : uuids.joined(separator: ",")
    }

    /// English-only, label-based decode — kept for files exported before
    /// `touchRingKey`/`touchStrip*Key` existed. New exports carry the
    /// locale-independent `TouchRingMode.rawValue` and prefer it. Nil for a
    /// label in another language, so the import leaves it unset.
    static func decodeTouchRingMode(_ label: String) -> String? {
        switch label {
        case "Scroll": return TouchRingMode.scroll.rawValue
        case "Off": return TouchRingMode.off.rawValue
        default: return nil
        }
    }

    /// English-only, label-based decode — kept for files exported before
    /// `expressKeysKey` existed. New exports carry each binding's encoded
    /// `ButtonBinding` form and prefer it (`decodeExpressKeysFromKeys`). Nil
    /// when any label names no action, as one in another language does: the
    /// keys share one stored list, so the import leaves the whole list unset.
    static func decodeExpressKeys(_ labels: [String]) -> String? {
        var bindings: [ButtonBinding] = []
        for label in labels {
            if label.isEmpty { bindings.append(.none); continue }
            guard let binding = ButtonBinding.recognizedLabel(label) else { return nil }
            bindings.append(binding)
        }
        while bindings.count < 16 { bindings.append(.none) }
        return encodeBindingArray(bindings)
    }

    /// Locale-independent express-key decode: each entry is an encoded
    /// `ButtonBinding` (from `ButtonBinding.encoded`), not a display label.
    /// An action from another build decodes and survives. Nil when an entry
    /// doesn't decode at all: kept as written it would make the whole stored
    /// list unreadable, so the import leaves the list unset instead.
    static func decodeExpressKeysFromKeys(_ keys: [String]) -> String? {
        var bindings: [ButtonBinding] = []
        for key in keys {
            if key.isEmpty { bindings.append(.none); continue }
            guard let binding = ButtonBinding.decode(key) else { return nil }
            bindings.append(binding)
        }
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

    /// Mode lists arrive as embedded JSON, or as a JSON string in the shape
    /// older code expected. Kept only if they decode, so a malformed entry
    /// can't block the app from saving over it later.
    static func decodeSlotsData(_ value: Any) -> Data? {
        guard let data = jsonData(value),
              (try? JSONDecoder().decode([ControlSlot].self, from: data)) != nil
        else { return nil }
        return data
    }

    static func decodeRotariesData(_ value: Any) -> Data? {
        guard let data = jsonData(value),
              (try? JSONDecoder().decode(RotarySet.self, from: data)) != nil
        else { return nil }
        return data
    }

    private static func jsonData(_ value: Any) -> Data? {
        if let s = value as? String { return s.data(using: .utf8) }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
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
