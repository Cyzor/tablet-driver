
import AppKit
import CoreGraphics

/// Parses and decodes JSON backup data into structured ImportPlan.
struct PresetImporter {

    enum ParseError: LocalizedError {
        case notJSON
        case wrongVersion(Int?)
        case noTablets

        var errorDescription: String? {
            switch self {
            case .notJSON:
                return "Not a valid JSON file."
            case .wrongVersion(let v):
                if let v {
                    return "Unsupported profile version (\(v)). Expected version 2."
                }
                return "File is missing a version field."
            case .noTablets:
                return "No tablet data found in this file."
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
            let isKnown = registry.knownTablets.contains { $0.id == pid }

            var values: [String: Any] = [:]
            if let s = tabletDict["settings"] as? [String: Any] {
                decodeDeviceSettings(s, into: &values)
            }

            entries.append(ImportPlan.TabletEntry(
                productID: pid,
                modelName: modelName,
                nickname: nickname,
                resolvedProfileName: nickname,
                profileValues: values,
                isKnown: isKnown,
            ))
        }

        if entries.isEmpty { throw ParseError.noTablets }
        return ImportPlan(sourceDate: sourceDate, entries: entries)
    }

    // MARK: - Decoders

    static func decodeDeviceSettings(_ s: [String: Any], into values: inout [String: Any]) {
        if let area = s["tabletArea"] as? [String: Any] {
            if let v = area["x"] as? Double { values["activeAreaX"] = v }
            if let v = area["y"] as? Double { values["activeAreaY"] = v }
            if let v = area["width"] as? Double { values["activeAreaWidth"] = v }
            if let v = area["height"] as? Double { values["activeAreaHeight"] = v }
            if let v = area["proportionalMapping"] as? Bool { values["proportionalMapping"] = v }
            if let v = area["orientation"] as? String { values["tabletOrientation"] = decodeOrientation(v) }
        }
        if let v = s["display"] { values["targetDisplayIndex"] = decodeDisplay(v) }
        if let v = s["smoothing"] as? Double { values["smoothingStrength"] = v }
        if let v = s["doubleClickDistance"] as? Double { values["doubleClickDistance"] = v }
        if let v = s["invertRotation"] as? Bool { values["invertRotation"] = v }
        if let v = s["relativeCursorMovement"] as? Bool { values["relativeCursorMovement"] = v }
        if let v = s["penButton1"] as? String { values["penButton1Binding"] = ButtonBinding.fromDisplayLabel(v).encoded }
        if let v = s["penButton2"] as? String { values["penButton2Binding"] = ButtonBinding.fromDisplayLabel(v).encoded }
        if let v = s["touchRingButton"] as? String { values["touchRingButtonBinding"] = ButtonBinding.fromDisplayLabel(v).encoded }
        if let v = s["touchRing"] as? String { values["touchRingMode"] = decodeTouchRingMode(v) }
        if let v = s["touchStrip1"] as? String { values["touchStrip1Mode"] = decodeTouchRingMode(v) }
        if let v = s["touchStrip2"] as? String { values["touchStrip2Mode"] = decodeTouchRingMode(v) }
        if let v = s["expressKeys"] as? [String] { values["expressKeyBindings"] = decodeExpressKeys(v) }
        if let v = s["pressureCurve"] as? [String: Any], let data = decodeCurveData(v) {
            values["pressureCurve"] = data
        }
    }

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

    static func decodeTouchRingMode(_ label: String) -> String {
        switch label {
        case "Scroll": return TouchRingMode.scroll.rawValue
        default: return TouchRingMode.off.rawValue
        }
    }

    static func decodeExpressKeys(_ labels: [String]) -> String {
        var bindings = labels.map { ButtonBinding.fromDisplayLabel($0) }
        while bindings.count < 16 { bindings.append(.none) }
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
