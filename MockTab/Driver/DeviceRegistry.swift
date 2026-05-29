// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "registry")

/// Persistent registry of tablets and tools the user has ever connected.
///
/// Tablets are stored globally (one entry per product ID).
/// Tools are stored per-device under the device-scoped UserDefaults namespace,
/// and are loaded/swapped when the active device changes.
///
/// Called by TabletManager on device connection and on each tool-enter event.
@MainActor
final class DeviceRegistry: ObservableObject {

    static let shared = DeviceRegistry()

    struct KnownTablet: Identifiable, Codable, Equatable {
        let id: Int  // productID — immutable unique key
        var nickname: String  // user-editable; defaults to modelName
        let modelName: String  // set at first-seen time (e.g. "PTH-860")
        var usbSerial: String?  // USB serial number from device firmware; nil if absent

        /// Best available identifier string for display.
        /// Prefers the firmware USB serial number; falls back to product ID hex.
        var displayID: String {
            if let s = usbSerial, !s.isEmpty { return s }
            return "0x\(String(format: "%04X", id))"
        }
    }

    struct KnownTool: Identifiable, Codable, Equatable {
        /// Serial-scoped ID: "0x{HEX8}" for tip, "eraser-0x{HEX8}" for eraser end.
        /// Falls back to "stylus" / "eraser" for IntuosV1 devices with no serial.
        let id: String
        var nickname: String  // user-editable; defaults to kind on first creation
        var kind: String  // human-readable name, refreshed on load
        var serial: UInt32?  // nil for old persisted entries without serial support
        var toolCode: UInt16?  // nil for old persisted entries
        /// User-forced tool code override. When set, the driver reports this tool code
        /// instead of the actual HID-reported tool code. Useful for working around
        /// decoding issues or testing tool compatibility.
        var forcedToolCode: UInt16?  // nil = use actual HID tool code
        var isSupported: Bool = true  // true if tool is fully supported on this device

        /// Best available identifier string for display.
        /// Prefers the HID-reported pen serial; falls back to tool code hex; then "—".
        var displayID: String {
            if let s = serial, s != 0 { return "0x\(String(format: "%08X", s))" }
            if let tc = toolCode { return "0x\(String(format: "%04X", tc))" }
            return "—"
        }
    }

    @Published var knownTablets: [KnownTablet] = []
    @Published var knownTools: [KnownTool] = []
    /// All tools seen across every known tablet, deduplicated by tool ID.
    /// A pen used on multiple tablets appears once (first tablet wins for
    /// nickname if the user has renamed it differently per device).
    @Published var allKnownTools: [KnownTool] = []

    private let ud = UserDefaults.standard

    private init() { loadTablets() }

    // MARK: - Pen model lookup

    /// Full name for a Wacom tool code, including "(Eraser)" suffix when appropriate.
    /// Delegates to WacomToolCatalog for the authoritative name table.
    static func penName(forToolCode toolCode: UInt16) -> String {
        return WacomToolCatalog.name(forToolCode: toolCode)
    }

    /// Fallback used for IntuosV1 devices that don't report a tool code.
    static func penName(forProductID productID: Int, isEraser: Bool) -> String {
        let base: String
        switch productID {
        case 0x0358, 0x0357: base = "Pro Pen 2"
        case 0x0317: base = "Grip Pen"
        case 0x00B5: base = "Grip Pen"
        case 0x00F4: base = "Grip Pen"
        default: base = "Stylus"
        }
        return isEraser ? "\(base) (Eraser)" : base
    }

    // MARK: - Recording

    /// Called when a tablet connects.  Adds it to the global tablet list if
    /// it has not been seen before, then loads the per-device tool list.
    /// `usbSerial` is the firmware-reported USB serial number (may be nil).
    func recordTablet(productID: Int, usbSerial: String?) {
        let modelName = TabletManager.deviceName(forProductID: productID)
        if let idx = knownTablets.firstIndex(where: { $0.id == productID }) {
            // Backfill serial if we now have it and didn't before.
            if knownTablets[idx].usbSerial == nil, let s = usbSerial, !s.isEmpty {
                knownTablets[idx].usbSerial = s
                saveTablets()
            }
        } else {
            knownTablets.append(
                KnownTablet(
                    id: productID,
                    nickname: modelName,
                    modelName: modelName,
                    usbSerial: usbSerial))
            saveTablets()
        }
        loadTools(forDevice: productID)
    }

    /// Called when a new tool enters proximity on an IntuosV2 device (serial known).
    /// Also called for IntuosV1 devices with serial = 0 (generic stylus/eraser).
    /// Returns the actual tool ID assigned (may have counter suffix for multi-pen IntuosV1 devices).
    @discardableResult
    func recordTool(identity: ToolIdentity, forDevice deviceID: Int) -> String {
        var toolID = Self.toolID(for: identity)
        // For IntuosV1 (serial=0): prefer toolCode-based name if available, fall back to productID-based.
        let kind: String
        if identity.serial != 0 {
            kind = Self.penName(forToolCode: identity.toolCode)
        } else if identity.toolCode != 0 && identity.toolCode != 0x0001 {
            // Try toolCode first for known pen types (0x0832, 0x0842, etc.)
            let toolCodeName = Self.penName(forToolCode: identity.toolCode)
            // If toolCode returns a non-generic name, use it; otherwise fall back to productID-based.
            kind =
                (!toolCodeName.hasPrefix("Unknown") && toolCodeName != "Stylus")
                ? toolCodeName
                : Self.penName(forProductID: deviceID, isEraser: identity.isEraser)
        } else {
            kind = Self.penName(forProductID: deviceID, isEraser: identity.isEraser)
        }

        // Refresh kind on existing entry (model name table may have improved).
        if let idx = knownTools.firstIndex(where: { $0.id == toolID }) {
            if knownTools[idx].kind != kind {
                knownTools[idx].kind = kind
                knownTools[idx].nickname = kind  // Update nickname to match kind
                if knownTools[idx].toolCode == nil {
                    knownTools[idx].toolCode = identity.toolCode
                    knownTools[idx].serial = identity.serial
                }
                saveTools(forDevice: deviceID)
            }
            return toolID
        }

        // Migration: when the real serial arrives, remove the old generic entry.
        if identity.serial != 0 {
            let genericID = identity.isEraser ? "eraser" : "stylus"
            if let oldIdx = knownTools.firstIndex(where: { $0.id == genericID }) {
                knownTools.remove(at: oldIdx)
            }
        }

        // For serial=0 (IntuosV1) devices: if multiple pens with the same toolCode are recorded,
        // append a counter to distinguish them (e.g., "stylus-0x0832-1", "stylus-0x0832-2").
        if identity.serial == 0 {
            let baseID = toolID
            var counter = 1
            while knownTools.contains(where: { $0.id == toolID }) {
                toolID = "\(baseID)-\(counter)"
                counter += 1
            }
        }

        // Check tool support for this device family
        let deviceSpec = WacomDeviceRegistry.spec(for: deviceID)
        let family = deviceSpec?.family ?? "universal"
        let caps = WacomToolCatalog.capabilities(forToolCode: identity.toolCode, family: family)

        knownTools.append(
            KnownTool(
                id: toolID,
                nickname: kind,
                kind: kind,
                serial: identity.serial,
                toolCode: identity.toolCode,
                isSupported: caps.isSupported))
        saveTools(forDevice: deviceID)
        rebuildAllTools()
        return toolID
    }

    /// Record the hardware serial number returned from a WACOM_REPORT_USB (Report ID 0x03)
    /// feature report query. Used for device unification: same physical tablet connecting
    /// via USB, BT, or wireless dongle returns the same serial.
    ///
    /// Stores a serial → canonicalProductID mapping in UserDefaults under "_hardwareSerials"
    /// (JSON dict). This allows BT-only connections to look up their canonical PID when
    /// querying Report ID 0x03 is not possible.
    ///
    /// Silently ignores serial = 0 (query failed or device does not support Report ID 0x03).
    func recordHardwareSerial(_ serial: UInt32, forDevice canonicalProductID: Int) {
        guard serial != 0 else { return }

        var serialMap = hardwareSerialMap()
        let serialHex = String(format: "%08X", serial)
        let pidHex = String(canonicalProductID, radix: 16, uppercase: true)

        // Check if this serial is already mapped to a different PID (shouldn't happen).
        if let existingPID = serialMap[serialHex], existingPID != canonicalProductID {
            logger.warning("DeviceRegistry: hardware serial remapped from 0x\(String(existingPID, radix: 16, uppercase: true), privacy: .public) to 0x\(pidHex, privacy: .public)")
        }

        serialMap[serialHex] = canonicalProductID
        saveHardwareSerialMap(serialMap)
        logger.info("DeviceRegistry: stored hardware serial → canonical PID 0x\(pidHex, privacy: .public)")
    }

    /// Looks up the canonical product ID for a given hardware serial, if known.
    /// Returns nil if the serial has not been recorded.
    func canonicalProductID(forHardwareSerial serial: UInt32) -> Int? {
        guard serial != 0 else { return nil }
        let serialHex = String(format: "%08X", serial)
        return hardwareSerialMap()[serialHex]
    }

    private func hardwareSerialMap() -> [String: Int] {
        guard let data = ud.data(forKey: "_hardwareSerials"),
            let map = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return map
    }

    private func saveHardwareSerialMap(_ map: [String: Int]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        ud.set(data, forKey: "_hardwareSerials")
    }

    // MARK: - Renaming

    func renameTablet(id: Int, to name: String) {
        guard let idx = knownTablets.firstIndex(where: { $0.id == id }) else { return }
        knownTablets[idx].nickname = name
        saveTablets()
    }

    func renameTool(id: String, to name: String, forDevice deviceID: Int) {
        guard let idx = knownTools.firstIndex(where: { $0.id == id }) else { return }
        knownTools[idx].nickname = name
        saveTools(forDevice: deviceID)
    }

    /// Forces the driver to report a specific tool code for this tool, ignoring the
    /// actual HID-reported tool code. Useful for working around decoding issues
    /// or testing tool compatibility. Pass nil to clear the override.
    func setForcedToolCode(_ code: UInt16?, forToolID id: String, deviceID: Int) {
        guard let idx = knownTools.firstIndex(where: { $0.id == id }) else { return }
        knownTools[idx].forcedToolCode = code
        saveTools(forDevice: deviceID)
    }

    /// Returns the forced tool code override for a tool, if set.
    /// Returns nil if no override is set.
    func forcedToolCode(forToolID id: String, deviceID: Int) -> UInt16? {
        guard let tool = knownTools.first(where: { $0.id == id }) else { return nil }
        return tool.forcedToolCode
    }

    /// Captured state needed to reverse a tool removal. Opaque to callers;
    /// pass back to `restoreTool(_:)` to undo.
    struct ToolRemovalSnapshot {
        let tool: KnownTool
        let originDeviceID: Int  // device the user invoked removal from
        let perDeviceBlobs: [Int: Data]  // toolsKey blob per affected device (pre-removal)
    }

    /// Removes a tool from one tablet's persisted list. Returns a snapshot
    /// that callers can pass to `restoreTool(_:)` to undo.
    @discardableResult
    func forgetTool(id: String, forDevice deviceID: Int) -> ToolRemovalSnapshot? {
        guard let tool = knownTools.first(where: { $0.id == id }) else { return nil }
        let originalBlob = ud.data(forKey: toolsKey(deviceID))
        knownTools.removeAll { $0.id == id }
        saveTools(forDevice: deviceID)
        rebuildAllTools()
        return ToolRemovalSnapshot(
            tool: tool,
            originDeviceID: deviceID,
            perDeviceBlobs: originalBlob.map { [deviceID: $0] } ?? [:])
    }

    /// Removes a tool from every tablet's persisted list. Returns a snapshot
    /// that callers can pass to `restoreTool(_:)` to undo.
    @discardableResult
    func forgetToolEverywhere(id: String) -> ToolRemovalSnapshot? {
        let tool = knownTools.first(where: { $0.id == id })
        var blobs: [Int: Data] = [:]
        for tablet in knownTablets {
            guard let data = ud.data(forKey: toolsKey(tablet.id)),
                var list = try? JSONDecoder().decode([KnownTool].self, from: data)
            else { continue }
            let before = list.count
            list.removeAll { $0.id == id }
            guard list.count != before,
                let saved = try? JSONEncoder().encode(list)
            else { continue }
            blobs[tablet.id] = data  // pre-removal blob
            ud.set(saved, forKey: toolsKey(tablet.id))
        }
        knownTools.removeAll { $0.id == id }
        rebuildAllTools()
        guard let tool, !blobs.isEmpty else { return nil }
        return ToolRemovalSnapshot(tool: tool, originDeviceID: 0, perDeviceBlobs: blobs)
    }

    /// Reverses a prior `forgetTool` or `forgetToolEverywhere`.
    func restoreTool(_ snapshot: ToolRemovalSnapshot) {
        for (deviceID, blob) in snapshot.perDeviceBlobs {
            ud.set(blob, forKey: toolsKey(deviceID))
        }
        // Refresh in-memory list if the origin device is currently loaded
        loadTools(forDevice: snapshot.originDeviceID)
        rebuildAllTools()
    }

    // MARK: - Tablet removal

    /// Captured state needed to reverse a tablet removal.
    struct TabletRemovalSnapshot {
        let tablet: KnownTablet
        let tabletIndex: Int
        let snapshotKV: [String: Data]  // every UserDefaults key under "device-0x<HEX>." that held a value
        let serialMapEntries: [String: Int]  // _hardwareSerials entries pointing at this id
    }

    /// Removes a tablet entry plus all device-scoped persisted state
    /// (tool list, settings, profiles, app overrides). Returns a snapshot
    /// suitable for `restoreTablet(_:)`. Caller must ensure the tablet is
    /// not currently connected.
    @discardableResult
    func removeTablet(id: Int) -> TabletRemovalSnapshot? {
        guard let idx = knownTablets.firstIndex(where: { $0.id == id }) else { return nil }
        let tablet = knownTablets[idx]
        let hex = String(id, radix: 16, uppercase: true)
        let prefix = "device-0x\(hex)."

        // Snapshot every device-scoped key
        var kv: [String: Data] = [:]
        for (k, v) in ud.dictionaryRepresentation() where k.hasPrefix(prefix) {
            // We only persist via UserDefaults.set(Any) which stores plist-encodable values.
            // Use propertyList encoding so we can round-trip arbitrary value types.
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: v, format: .binary, options: 0)
            {
                kv[k] = data
            }
        }

        // Snapshot serial-map entries pointing at this id
        let serialEntries = hardwareSerialMap().filter { $0.value == id }

        // Remove tablet entry
        knownTablets.remove(at: idx)
        saveTablets()

        // Remove device-scoped keys
        for k in kv.keys { ud.removeObject(forKey: k) }

        // Remove serial-map entries
        if !serialEntries.isEmpty {
            var map = hardwareSerialMap()
            for k in serialEntries.keys { map.removeValue(forKey: k) }
            saveHardwareSerialMap(map)
        }

        // Clear in-memory tool list if it was showing this device
        knownTools.removeAll()
        rebuildAllTools()

        return TabletRemovalSnapshot(
            tablet: tablet, tabletIndex: idx, snapshotKV: kv, serialMapEntries: serialEntries)
    }

    /// Reverses a prior `removeTablet`.
    func restoreTablet(_ snapshot: TabletRemovalSnapshot) {
        // Restore tablet entry at its original position (clamp if list shrank elsewhere)
        let idx = min(snapshot.tabletIndex, knownTablets.count)
        knownTablets.insert(snapshot.tablet, at: idx)
        saveTablets()

        // Restore device-scoped keys
        for (k, data) in snapshot.snapshotKV {
            if let v = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
            {
                ud.set(v, forKey: k)
            }
        }

        // Restore serial-map entries
        if !snapshot.serialMapEntries.isEmpty {
            var map = hardwareSerialMap()
            for (k, v) in snapshot.serialMapEntries { map[k] = v }
            saveHardwareSerialMap(map)
        }

        rebuildAllTools()
    }

    // MARK: - Device switch

    /// Loads the tool list for `deviceID` into `knownTools`.
    /// The `kind` field is refreshed on load so that improved model names
    /// are picked up automatically.  Called by `recordTablet` and when the
    /// user selects a different tablet in DevicesView.
    func loadTools(forDevice deviceID: Int) {
        guard let data = ud.data(forKey: toolsKey(deviceID)),
            var list = try? JSONDecoder().decode([KnownTool].self, from: data)
        else {
            knownTools = []
            return
        }

        var changed = false
        let deviceSpec = WacomDeviceRegistry.spec(for: deviceID)
        let family = deviceSpec?.family ?? "universal"
        for i in list.indices {
            let freshKind: String
            if let tc = list[i].toolCode {
                freshKind = Self.penName(forToolCode: tc)
            } else {
                let isEraser = list[i].id == "eraser" || list[i].id.hasPrefix("eraser-")
                freshKind = Self.penName(forProductID: deviceID, isEraser: isEraser)
            }
            if list[i].kind != freshKind {
                list[i].kind = freshKind
                changed = true
            }
            // Refresh support status
            if let tc = list[i].toolCode {
                let caps = WacomToolCatalog.capabilities(forToolCode: tc, family: family)
                if list[i].isSupported != caps.isSupported {
                    list[i].isSupported = caps.isSupported
                    changed = true
                }
            }
        }
        knownTools = list
        if changed { saveTools(forDevice: deviceID) }
        rebuildAllTools()
    }

    // MARK: - Helpers

    /// Rebuilds `allKnownTools` by reading every per-tablet tool list from
    /// UserDefaults and merging them in tablet order, skipping duplicate IDs.
    private func rebuildAllTools() {
        var seen = Set<String>()
        var merged = [KnownTool]()
        for tablet in knownTablets {
            guard let data = ud.data(forKey: toolsKey(tablet.id)),
                let list = try? JSONDecoder().decode([KnownTool].self, from: data)
            else { continue }
            for tool in list where seen.insert(tool.id).inserted {
                merged.append(tool)
            }
        }
        allKnownTools = merged
    }

    /// Returns the saved tool list for `productID` without mutating `knownTools`.
    /// Safe to call for any known or unknown device — returns empty array if not found.
    func tools(forDevice productID: Int) -> [KnownTool] {
        guard let data = ud.data(forKey: toolsKey(productID)),
              let list = try? JSONDecoder().decode([KnownTool].self, from: data)
        else { return [] }
        return list
    }

    /// Canonical tool ID string for a ToolIdentity.
    static func toolID(for identity: ToolIdentity) -> String {
        if identity.serial == 0 {
            if identity.isMouse { return "mouse" }
            return identity.isEraser ? "eraser" : "stylus"
        }
        let hex = String(format: "%08X", identity.serial)
        return identity.isEraser ? "eraser-0x\(hex)" : "0x\(hex)"
    }

    // MARK: - Persistence

    private let tabletsKey = "_knownTablets"

    private func loadTablets() {
        guard let data = ud.data(forKey: tabletsKey),
            let list = try? JSONDecoder().decode([KnownTablet].self, from: data)
        else { return }
        knownTablets = list
        rebuildAllTools()
    }

    private func saveTablets() {
        guard let data = try? JSONEncoder().encode(knownTablets) else { return }
        ud.set(data, forKey: tabletsKey)
    }

    private func toolsKey(_ id: Int) -> String {
        "device-0x\(String(id, radix: 16, uppercase: true))._knownTools"
    }

    private func saveTools(forDevice deviceID: Int) {
        guard let data = try? JSONEncoder().encode(knownTools) else { return }
        ud.set(data, forKey: toolsKey(deviceID))
    }
}
