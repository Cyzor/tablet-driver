
import AppKit
import CoreGraphics

/// Serializes tablet profiles and settings to JSON for backup/restore.
@MainActor
final class PresetExporter {
    let registry: DeviceRegistry
    let tabletManager: TabletManager

    init(registry: DeviceRegistry, tabletManager: TabletManager) {
        self.registry = registry
        self.tabletManager = tabletManager
    }

    /// Builds a complete JSON backup of all known tablets and their settings.
    func export() -> Data? {
        let tablets = registry.knownTablets.map { exportTablet($0) }
        let iso = ISO8601DateFormatter()
        let envelope: [String: Any] = [
            "version": 2,
            "exportedAt": iso.string(from: Date()),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "tablets": tablets
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else { return nil }
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    /// Exports a single tablet's full configuration.
    func exportTablet(_ tablet: DeviceRegistry.KnownTablet) -> [String: Any] {
        let pid = tablet.id
        let hexPID = "0x\(String(pid, radix: 16, uppercase: true))"
        let devicePrefix = "device-\(hexPID)."
        let ts: TabletSettings = tabletManager.contexts[pid]?.settings ?? TabletSettings(productID: pid)

        var d: [String: Any] = [
            "productID": hexPID,
            "modelName": tablet.modelName,
            "nickname": tablet.nickname,
            "settings": exportDeviceSettings(ts, devicePrefix: devicePrefix)
        ]

        if let serial = tablet.usbSerial, !serial.isEmpty {
            d["usbSerial"] = serial
        }

        let overrides = ts.appOverrides.map { exportAppOverride($0, devicePrefix: devicePrefix, filter: nil) }
        if !overrides.isEmpty { d["appOverrides"] = overrides }

        let presets = ts.profiles.map { exportPreset($0, activeID: ts.activeProfile?.id, devicePrefix: devicePrefix) }
        if !presets.isEmpty { d["profiles"] = presets }

        let tools = registry.tools(forDevice: pid).map { exportTool($0, ts: ts, devicePrefix: devicePrefix) }
        if !tools.isEmpty { d["tools"] = tools }

        return d
    }

    /// Exports device-level settings as UserDefaults-ready key-value pairs.
    func exportDeviceSettings(_ s: TabletSettings, devicePrefix: String) -> [String: Any] {
        var d: [String: Any] = [:]
        d["tabletArea"] = [
            "x": roundFrac(s.activeAreaX),
            "y": roundFrac(s.activeAreaY),
            "width": roundFrac(s.activeAreaWidth),
            "height": roundFrac(s.activeAreaHeight),
            "proportionalMapping": s.proportionalMapping,
            "orientation": s.tabletOrientation.label
        ] as [String: Any]
        d["display"] = exportDisplay(s.targetDisplayIndex, toggleIDs: s.toggleDisplayIDSet)
        d["pressureCurve"] = exportCurve(s.pressureCurve)
        d["smoothing"] = s.smoothingStrength
        d["doubleClickDistance"] = s.doubleClickDistance
        d["invertRotation"] = s.invertRotation
        d["relativeCursorMovement"] = s.relativeCursorMovement
        d["penButton1"] = s.penButton1Binding.displayLabel
        d["penButton2"] = s.penButton2Binding.displayLabel
        d["touchRing"] = s.touchRingSlots.indices.contains(s.touchRingActiveSlotIndex) ? s.touchRingSlots[s.touchRingActiveSlotIndex].action.displayLabel : "Scroll"
        d["touchRingButton"] = s.touchRingButtonBinding.displayLabel
        d["touchStrip1"] = d["touchRing"]
        d["touchStrip2"] = d["touchRing"]
        let expressKeys = s.expressKeyBindings.map(\.displayLabel)
        if expressKeys.contains(where: { $0 != "None" }) {
            d["expressKeys"] = expressKeys
        }
        return d
    }

    /// Exports a single tool's settings.
    func exportTool(_ tool: DeviceRegistry.KnownTool, ts: TabletSettings, devicePrefix: String) -> [String: Any] {
        let t = ts.toolSettings(forID: tool.id)
        var d: [String: Any] = [
            "id": tool.displayID,
            "kind": tool.kind,
            "nickname": tool.nickname,
            "settings": [
                "pressureCurve": exportCurve(t.pressureCurve),
                "smoothing": t.smoothingStrength,
                "tip": t.tipBinding.displayLabel,
                "eraser": t.eraserBinding.displayLabel,
                "penButton1": t.penButton1Binding.displayLabel,
                "penButton2": t.penButton2Binding.displayLabel
            ] as [String: Any]
        ]

        // Tool-level app overrides: filter to tool-specific keys.
        let toolKeys: Set<String> = [
            "pressureCurve", "smoothingStrength",
            "tipBinding", "eraserBinding", "penButton1Binding", "penButton2Binding"
        ]
        let toolOverrides = ts.appOverrides
            .filter { !$0.overriddenKeys.intersection(toolKeys).isEmpty }
            .map { exportAppOverride($0, devicePrefix: devicePrefix, filter: toolKeys) }
        if !toolOverrides.isEmpty { d["appOverrides"] = toolOverrides }

        return d
    }

    /// Exports a named profile's overridden keys by reading UserDefaults directly.
    func exportPreset(_ preset: TabletSettings.Profile, activeID: UUID?, devicePrefix: String) -> [String: Any] {
        let presetPrefix = "\(devicePrefix)preset-\(preset.id.uuidString)."
        var settings: [String: Any] = [:]
        for key in preset.overriddenKeys.sorted() {
            if let v = readUDValue(key: key, prefix: presetPrefix) {
                settings[key] = v
            }
        }
        var d: [String: Any] = ["name": preset.name, "active": preset.id == activeID]
        if !settings.isEmpty { d["settings"] = settings }
        return d
    }

    /// Exports an app override's overridden keys.
    func exportAppOverride(
        _ override: TabletSettings.AppOverride,
        devicePrefix: String,
        filter: Set<String>?
    ) -> [String: Any] {
        let prefix = "\(devicePrefix)appOverride-\(override.bundleID)."
        let keys = filter.map { override.overriddenKeys.intersection($0) } ?? override.overriddenKeys
        var settings: [String: Any] = [:]
        for key in keys.sorted() {
            if let v = readUDValue(key: key, prefix: prefix) {
                settings[key] = v
            }
        }
        var d: [String: Any] = ["app": override.appName, "bundleID": override.bundleID]
        if !settings.isEmpty { d["settings"] = settings }
        return d
    }

    // MARK: - Helpers

    /// Reads one UserDefaults value and returns it in a JSON-friendly, human-readable form.
    private func readUDValue(key: String, prefix: String) -> Any? {
        let ud = UserDefaults.standard
        switch key {
        case "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
             "smoothingStrength", "doubleClickDistance":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return roundFrac(ud.double(forKey: prefix + key))

        case "proportionalMapping", "invertRotation", "relativeCursorMovement":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return ud.bool(forKey: prefix + key)

        case "targetDisplayIndex":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return exportDisplayIndex(ud.integer(forKey: prefix + key))

        case "toggleDisplayIDs":
            guard let raw = ud.string(forKey: prefix + key), !raw.isEmpty else { return nil }
            return raw.split(separator: ",")
                .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
                .map { String($0) }

        case "tabletOrientation":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return TabletOrientation(rawValue: ud.integer(forKey: prefix + key))?.label

        case "penButton1Binding", "penButton2Binding",
             "touchRingButtonBinding", "tipBinding", "eraserBinding":
            guard let raw = ud.string(forKey: prefix + key) else { return nil }
            return ButtonBinding.decode(raw)?.displayLabel ?? raw

        case "expressKeyBindings":
            guard let raw = ud.string(forKey: prefix + key),
                  let data = raw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([ButtonBinding].self, from: data)
            else { return nil }
            return arr.map(\.displayLabel)

        case "touchRingMode", "touchStrip1Mode", "touchStrip2Mode":
            guard let raw = ud.string(forKey: prefix + key) else { return nil }
            return TouchRingMode(rawValue: raw)?.displayLabel ?? raw

        case "pressureCurve":
            guard let data = ud.data(forKey: prefix + key),
                  let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
            else { return nil }
            return exportCurve(curve)

        default:
            return nil
        }
    }

    private func exportCurve(_ c: BezierCurve) -> [String: Any] {
        [
            "p1": [roundFrac(c.p1.x), roundFrac(c.p1.y)],
            "p2": [roundFrac(c.p2.x), roundFrac(c.p2.y)]
        ]
    }

    private func exportDisplay(_ idx: Int, toggleIDs: Set<CGDirectDisplayID>) -> Any {
        switch idx {
        case 0: return "primary"
        case TabletSettings.displayModeAll: return "all"
        case TabletSettings.displayModeToggle:
            guard !toggleIDs.isEmpty else { return "toggle" }
            return ["mode": "toggle", "displays": toggleIDs.sorted().map { String($0) }] as [String: Any]
        default: return "display-\(idx)"
        }
    }

    private func exportDisplayIndex(_ idx: Int) -> Any {
        switch idx {
        case 0: return "primary"
        case TabletSettings.displayModeAll: return "all"
        case TabletSettings.displayModeToggle: return "toggle"
        default: return "display-\(idx)"
        }
    }

    /// Round to 4 decimal places to suppress floating-point noise in the output.
    private func roundFrac(_ v: Double) -> Double {
        (v * 10000).rounded() / 10000
    }
}
