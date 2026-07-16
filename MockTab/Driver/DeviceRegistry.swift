// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "registry")

/// Persistent registry of tablets and tools the user has ever connected.
///
/// Tablets are stored globally (one entry per physical unit).
/// Tools are stored per-device under the device-scoped UserDefaults namespace,
/// and are loaded/swapped when the active device changes.
///
/// Called by TabletManager on device connection and on each tool-enter event.
@MainActor
final class DeviceRegistry: ObservableObject {

    static let shared = DeviceRegistry()

    struct KnownTablet: Identifiable, Codable, Equatable {
        /// Canonical product ID — model identity. Encoded under the legacy
        /// JSON key `"id"` so pre-instance-identity rows decode unchanged.
        let productID: Int
        /// Instance token for additional physical units of the same model.
        /// nil (all pre-existing rows) or "" = the unit holding the model's
        /// legacy settings namespace — see `DeviceRegistry.settingsPrefix`.
        var instance: String?
        var nickname: String  // user-editable; defaults to modelName
        let modelName: String  // set at first-seen time (e.g. "PTH-860")
        var usbSerial: String?  // USB serial number from device firmware; nil if absent
        /// Vendor ID last seen for this product, so window restoration can
        /// reconstruct a stub `DeviceContext` with the right vendor before the
        /// real device reconnects. Optional so pre-existing persisted entries
        /// (saved before this field existed) still decode; nil = unknown,
        /// callers fall back to the Wacom default.
        var vendorID: Int?

        enum CodingKeys: String, CodingKey {
            case productID = "id"
            case instance, nickname, modelName, usbSerial, vendorID
        }

        /// Identifiable key: composite instance string, unique per physical
        /// unit even when two rows share a model.
        var id: String { instanceKey.stringValue }

        var instanceKey: DeviceInstanceKey {
            DeviceInstanceKey(productID: productID, instance: instance ?? "")
        }

        /// Best available identifier string for display.
        /// Prefers the firmware USB serial number; falls back to product ID hex.
        var displayID: String {
            if let s = usbSerial, !s.isEmpty { return s }
            return "0x\(String(format: "%04X", productID))"
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

    private init() {
        loadTablets()
        mergeQuickKeysDongleIdentity()
    }

    /// One-time migration for the Xencelabs Quick Keys transport merge: the
    /// wireless dongle (0x5203) used to be its own device, so a puck set up
    /// over both transports has two settings namespaces (the "LED colors
    /// differ between wired and wireless" symptom). Fold the dongle's
    /// persisted state into the wired puck's (0x5202) — wired values win,
    /// dongle values fill only keys the wired side never set — and retire
    /// the dongle's device row. New connects always arrive under the
    /// canonical PID (see `VendorDeviceRegistry.canonicalProductID(for:)`).
    private func mergeQuickKeysDongleIdentity() {
        let flag = "_quickKeysDongleIdentityMerged"
        guard !ud.bool(forKey: flag) else { return }

        let oldPrefix = "device-0x5203."
        let newPrefix = "device-0x5202."
        for (key, value) in ud.dictionaryRepresentation() where key.hasPrefix(oldPrefix) {
            let target = newPrefix + key.dropFirst(oldPrefix.count)
            if ud.object(forKey: target) == nil { ud.set(value, forKey: target) }
            ud.removeObject(forKey: key)
        }

        if let idx = knownTablets.firstIndex(where: { $0.productID == 0x5203 }) {
            let dongleRow = knownTablets.remove(at: idx)
            if !knownTablets.contains(where: { $0.productID == 0x5202 }) {
                // The puck was only ever seen wirelessly — carry its row over
                // under the canonical identity. Default nicknames follow the
                // model name; a custom one is kept.
                let modelName = TabletManager.deviceName(
                    forProductID: 0x5202, vendorID: dongleRow.vendorID ?? 0x28BD)
                knownTablets.append(
                    KnownTablet(
                        productID: 0x5202,
                        instance: dongleRow.instance,
                        nickname: dongleRow.nickname == dongleRow.modelName
                            ? modelName : dongleRow.nickname,
                        modelName: modelName,
                        usbSerial: dongleRow.usbSerial,
                        vendorID: dongleRow.vendorID))
            }
            saveTablets()
        }

        var serialMap = hardwareSerialMap()
        if serialMap.values.contains(0x5203) {
            for (serial, pid) in serialMap where pid == 0x5203 {
                serialMap[serial] = 0x5202
            }
            saveHardwareSerialMap(serialMap)
        }

        ud.set(true, forKey: flag)
    }

    // MARK: - Instance claims

    /// Resolves the UserDefaults settings prefix for one physical device
    /// instance under the claim-the-legacy-prefix rule: the first instance
    /// ever seen for a PID permanently claims the historical
    /// `device-0x{PID}.` prefix (so existing installs keep every setting,
    /// preset, and calibration untouched); any other instance of the same
    /// PID gets a fresh `device-0x{PID}#{instance}.` namespace. Instances
    /// with no token (no serial, no locationID) always resolve to the
    /// legacy prefix — today's PID-only behavior.
    ///
    /// The claim is persisted (`_instanceClaims`, JSON `[pidHex: instance]`)
    /// so it is deterministic across reboots and ports, not connect-order
    /// dependent.
    /// The claim logic itself lives in `DeviceInstanceClaims` (Foundation-
    /// only, injectable UserDefaults) so the standalone harness in
    /// `tools/instance-identity-tests/` can exercise it; this is the app's
    /// live instance.
    private var claims: DeviceInstanceClaims {
        DeviceInstanceClaims(ud: ud) { pidHex in
            logger.info("DeviceRegistry: instance claimed legacy prefix for PID 0x\(pidHex, privacy: .public)")
        }
    }

    func settingsPrefix(for key: DeviceInstanceKey) -> String {
        claims.settingsPrefix(for: key)
    }

    /// Row-normalized instance token: nil for the claimed unit (its row and
    /// namespace stay in the legacy, un-suffixed form), the raw token for
    /// any additional unit of the same model.
    private func rowInstance(for key: DeviceInstanceKey) -> String? {
        claims.rowInstance(for: key)
    }

    /// Pure prefix formatting for a row-normalized key (no claim lookup —
    /// use `settingsPrefix(for:)` for live-device resolution).
    private func prefix(for key: DeviceInstanceKey) -> String {
        claims.prefix(for: key)
    }

    /// Claim-normalized form: the claimed unit's key folds to the empty
    /// instance (legacy identity), any other unit keeps its token. Two keys
    /// that normalize equal refer to the same physical device — window
    /// matching and restore use this so a pre-instance saved identity
    /// (empty token) and the live claimed device compare equal.
    func normalizedKey(_ key: DeviceInstanceKey) -> DeviceInstanceKey {
        claims.normalizedKey(key)
    }

    /// The registry row for a physical unit, matched claim-normalized so the
    /// legacy empty-instance identity and the claimed unit compare equal.
    func row(forKey key: DeviceInstanceKey) -> KnownTablet? {
        let normalized = normalizedKey(key)
        return knownTablets.first(where: { normalizedKey($0.instanceKey) == normalized })
    }

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
    func recordTablet(
        instanceKey: DeviceInstanceKey, usbSerial: String?,
        vendorID: Int = 0x056A, productString: String? = nil
    ) {
        let productID = instanceKey.productID
        let rowInst = rowInstance(for: instanceKey)
        let modelName = TabletManager.deviceName(
            forProductID: productID, vendorID: vendorID, productString: productString)
        if let idx = knownTablets.firstIndex(where: {
            $0.productID == productID && ($0.instance ?? "") == (rowInst ?? "")
        }) {
            var changed = false
            // Backfill serial if we now have it and didn't before.
            if knownTablets[idx].usbSerial == nil, let s = usbSerial, !s.isEmpty {
                knownTablets[idx].usbSerial = s
                changed = true
            }
            // Backfill vendorID for entries persisted before this field existed,
            // or if it's ever recorded wrong — the live connect always knows best.
            if knownTablets[idx].vendorID != vendorID {
                knownTablets[idx].vendorID = vendorID
                changed = true
            }
            if changed { saveTablets() }
        } else {
            // A second unit of an already-known model gets a nickname
            // disambiguator so the Devices list and menus stay tellable
            // apart (short serial tail when available).
            var nickname = modelName
            if rowInst != nil, knownTablets.contains(where: { $0.modelName == modelName }) {
                let tail = (usbSerial?.suffix(4)).map(String.init) ?? "2"
                nickname = "\(modelName) (\(tail))"
            }
            knownTablets.append(
                KnownTablet(
                    productID: productID,
                    instance: rowInst,
                    nickname: nickname,
                    modelName: modelName,
                    usbSerial: usbSerial,
                    vendorID: vendorID))
            saveTablets()
        }
        loadTools(for: instanceKey)
    }

    /// Last-known vendor ID for a previously-connected product, or nil if
    /// never recorded. Used by `SettingsWindowManager` to reconstruct a
    /// stub `DeviceContext` with the correct vendor when restoring a window
    /// at launch, before the real device has reconnected this session.
    func vendorID(forProductID productID: Int) -> Int? {
        knownTablets.first(where: { $0.productID == productID })?.vendorID
    }

    /// Called when a new tool enters proximity on an IntuosV2 device (serial known).
    /// Also called for IntuosV1 devices with serial = 0 (generic stylus/eraser).
    /// Returns the actual tool ID assigned (may have counter suffix for multi-pen IntuosV1 devices).
    @discardableResult
    func recordTool(identity: ToolIdentity, forDevice key: DeviceInstanceKey) -> String {
        let deviceID = key.productID  // model identity: pen names, specs
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
                saveTools(for: key)
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
        saveTools(for: key)
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

    func renameTablet(id: String, to name: String) {
        guard let idx = knownTablets.firstIndex(where: { $0.id == id }) else { return }
        knownTablets[idx].nickname = name
        saveTablets()
    }

    func renameTool(id: String, to name: String, forDevice deviceID: String) {
        guard let idx = knownTools.firstIndex(where: { $0.id == id }),
            let key = DeviceInstanceKey(stringValue: deviceID)
        else { return }
        knownTools[idx].nickname = name
        saveTools(for: key)
        rebuildAllTools()
    }

    /// Renames a tool in every tablet's persisted list. Used by the
    /// all-tablets section of the Devices pane, where the edited tool may
    /// not belong to the currently selected tablet (so `renameTool(_:to:forDevice:)`,
    /// which operates on `knownTools`, could not find it).
    func renameToolEverywhere(id: String, to name: String) {
        for tablet in knownTablets {
            guard let data = ud.data(forKey: toolsKey(tablet.instanceKey)),
                var list = try? JSONDecoder().decode([KnownTool].self, from: data),
                let idx = list.firstIndex(where: { $0.id == id })
            else { continue }
            list[idx].nickname = name
            guard let saved = try? JSONEncoder().encode(list) else { continue }
            ud.set(saved, forKey: toolsKey(tablet.instanceKey))
        }
        if let idx = knownTools.firstIndex(where: { $0.id == id }) {
            knownTools[idx].nickname = name
        }
        rebuildAllTools()
    }

    /// Captured state needed to reverse a tool removal. Opaque to callers;
    /// pass back to `restoreTool(_:)` to undo.
    struct ToolRemovalSnapshot {
        let tool: KnownTool
        let originDeviceID: String  // row id the user invoked removal from ("" = everywhere)
        let perDeviceBlobs: [String: Data]  // toolsKey blob per affected row id (pre-removal)
    }

    /// Removes a tool from one tablet's persisted list. Returns a snapshot
    /// that callers can pass to `restoreTool(_:)` to undo.
    @discardableResult
    func forgetTool(id: String, forDevice deviceID: String) -> ToolRemovalSnapshot? {
        guard let tool = knownTools.first(where: { $0.id == id }),
            let key = DeviceInstanceKey(stringValue: deviceID)
        else { return nil }
        let originalBlob = ud.data(forKey: toolsKey(key))
        knownTools.removeAll { $0.id == id }
        saveTools(for: key)
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
        var blobs: [String: Data] = [:]
        for tablet in knownTablets {
            guard let data = ud.data(forKey: toolsKey(tablet.instanceKey)),
                var list = try? JSONDecoder().decode([KnownTool].self, from: data)
            else { continue }
            let before = list.count
            list.removeAll { $0.id == id }
            guard list.count != before,
                let saved = try? JSONEncoder().encode(list)
            else { continue }
            blobs[tablet.id] = data  // pre-removal blob
            ud.set(saved, forKey: toolsKey(tablet.instanceKey))
        }
        knownTools.removeAll { $0.id == id }
        rebuildAllTools()
        guard let tool, !blobs.isEmpty else { return nil }
        return ToolRemovalSnapshot(tool: tool, originDeviceID: "", perDeviceBlobs: blobs)
    }

    /// Reverses a prior `forgetTool` or `forgetToolEverywhere`.
    func restoreTool(_ snapshot: ToolRemovalSnapshot) {
        for (deviceID, blob) in snapshot.perDeviceBlobs {
            guard let key = DeviceInstanceKey(stringValue: deviceID) else { continue }
            ud.set(blob, forKey: toolsKey(key))
        }
        // Refresh in-memory list if the origin device is currently loaded
        if let key = DeviceInstanceKey(stringValue: snapshot.originDeviceID) {
            loadTools(for: key)
        }
        rebuildAllTools()
    }

    // MARK: - Tablet removal

    /// Captured state needed to reverse a tablet removal.
    struct TabletRemovalSnapshot {
        let tablet: KnownTablet
        let tabletIndex: Int
        let snapshotKV: [String: Data]  // every UserDefaults key under the row's device prefix that held a value
        let serialMapEntries: [String: Int]  // _hardwareSerials entries pointing at this model
    }

    /// Removes a tablet entry plus all device-scoped persisted state
    /// (tool list, settings, profiles, app overrides). Returns a snapshot
    /// suitable for `restoreTablet(_:)`. Caller must ensure the tablet is
    /// not currently connected.
    @discardableResult
    func removeTablet(id: String) -> TabletRemovalSnapshot? {
        guard let idx = knownTablets.firstIndex(where: { $0.id == id }) else { return nil }
        let tablet = knownTablets[idx]
        let prefix = prefix(for: tablet.instanceKey)

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

        // Snapshot serial-map entries pointing at this model. The map is
        // model-keyed (transport folding), so entries survive only while
        // another row of the same model remains.
        let serialEntries = knownTablets.contains(where: {
            $0.productID == tablet.productID && $0.id != id
        }) ? [:] : hardwareSerialMap().filter { $0.value == tablet.productID }

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
    func loadTools(for key: DeviceInstanceKey) {
        let deviceID = key.productID  // model identity: pen names, family
        guard let data = ud.data(forKey: toolsKey(key)),
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
        if changed { saveTools(for: key) }
        rebuildAllTools()
    }

    /// Row-id string variant for UI callers holding a `KnownTablet.id`.
    func loadTools(forDevice id: String) {
        guard let key = DeviceInstanceKey(stringValue: id) else { return }
        loadTools(for: key)
    }

    // MARK: - Helpers

    /// Rebuilds `allKnownTools` by reading every per-tablet tool list from
    /// UserDefaults and merging them in tablet order, skipping duplicate IDs.
    private func rebuildAllTools() {
        var seen = Set<String>()
        var merged = [KnownTool]()
        for tablet in knownTablets {
            guard let data = ud.data(forKey: toolsKey(tablet.instanceKey)),
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
    func tools(for key: DeviceInstanceKey) -> [KnownTool] {
        guard let data = ud.data(forKey: toolsKey(key)),
            let list = try? JSONDecoder().decode([KnownTool].self, from: data)
        else { return [] }
        return list
    }

    /// Model-keyed variant (legacy namespace) for preset export, which is
    /// deliberately model-keyed — see the archive format.
    func tools(forDevice productID: Int) -> [KnownTool] {
        tools(for: DeviceInstanceKey(productID: productID, instance: ""))
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

    private func toolsKey(_ key: DeviceInstanceKey) -> String {
        // Normalize so a live key carrying the claimed unit's serial token
        // resolves to the same legacy-prefix key as that unit's row.
        prefix(for: normalizedKey(key)) + "_knownTools"
    }

    private func saveTools(for key: DeviceInstanceKey) {
        guard let data = try? JSONEncoder().encode(knownTools) else { return }
        ud.set(data, forKey: toolsKey(key))
    }
}
