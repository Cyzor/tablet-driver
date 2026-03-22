import Foundation

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
        let id:        Int     // productID — immutable unique key
        var nickname:  String  // user-editable; defaults to modelName
        let modelName: String  // set at first-seen time (e.g. "PTH-860")
    }

    struct KnownTool: Identifiable, Codable, Equatable {
        /// Serial-scoped ID: "0x{HEX8}" for tip, "eraser-0x{HEX8}" for eraser end.
        /// Falls back to "stylus" / "eraser" for IntuosV1 devices with no serial.
        let id:       String
        var nickname: String  // user-editable; defaults to kind on first creation
        var kind:     String  // human-readable name, refreshed on load
        var serial:   UInt32? // nil for old persisted entries without serial support
        var toolCode: UInt16? // nil for old persisted entries
    }

    @Published var knownTablets: [KnownTablet] = []
    @Published var knownTools:   [KnownTool]   = []

    private let ud = UserDefaults.standard

    private init() { loadTablets() }

    // MARK: - Pen model lookup

    /// Human-readable base name for a Wacom tool code (eraser suffix not included).
    static func penBaseName(forToolCode toolCode: UInt16) -> String {
        // Mask off the eraser bit (bit 3) to get the tip variant code.
        switch toolCode & ~UInt16(0x0008) {
        case 0x0802: return "Grip Pen"
        case 0x0804: return "Grip Pen"
        case 0x0812: return "Inking Pen"
        case 0x0832: return "Pro Pen 2"
        case 0x0842: return "Pro Pen 3"
        case 0x0852: return "Pen 4K"
        default:     return "Stylus"
        }
    }

    /// Full name including "(Eraser)" suffix when appropriate.
    static func penName(forToolCode toolCode: UInt16) -> String {
        let base = penBaseName(forToolCode: toolCode)
        let isEraser = (toolCode & 0x0008) != 0
        return isEraser ? "\(base) (Eraser)" : base
    }

    /// Fallback used for IntuosV1 devices that don't report a tool code.
    static func penName(forProductID productID: Int, isEraser: Bool) -> String {
        let base: String
        switch productID {
        case 0x0358, 0x0357:  base = "Pro Pen 2"
        case 0x0317:          base = "Grip Pen"
        case 0x00B5:          base = "Grip Pen"
        case 0x00F4:          base = "Grip Pen"
        default:              base = "Stylus"
        }
        return isEraser ? "\(base) (Eraser)" : base
    }

    // MARK: - Recording

    /// Called when a tablet connects.  Adds it to the global tablet list if
    /// it has not been seen before, then loads the per-device tool list.
    func recordTablet(productID: Int) {
        let modelName = TabletManager.deviceName(forProductID: productID)
        if !knownTablets.contains(where: { $0.id == productID }) {
            knownTablets.append(KnownTablet(id: productID,
                                            nickname: modelName,
                                            modelName: modelName))
            saveTablets()
        }
        loadTools(forDevice: productID)
    }

    /// Called when a new tool enters proximity on an IntuosV2 device (serial known).
    /// Also called for IntuosV1 devices with serial = 0 (generic stylus/eraser).
    func recordTool(identity: ToolIdentity, forDevice deviceID: Int) {
        let toolID = Self.toolID(for: identity)
        let kind   = identity.serial != 0
            ? Self.penName(forToolCode: identity.toolCode)
            : Self.penName(forProductID: deviceID, isEraser: identity.isEraser)

        // Refresh kind on existing entry (model name table may have improved).
        if let idx = knownTools.firstIndex(where: { $0.id == toolID }) {
            if knownTools[idx].kind != kind {
                knownTools[idx].kind = kind
                if knownTools[idx].toolCode == nil {
                    knownTools[idx].toolCode = identity.toolCode
                    knownTools[idx].serial   = identity.serial
                }
                saveTools(forDevice: deviceID)
            }
            return
        }

        // Migration: when the real serial arrives, remove the old generic entry.
        if identity.serial != 0 {
            let genericID = identity.isEraser ? "eraser" : "stylus"
            if let oldIdx = knownTools.firstIndex(where: { $0.id == genericID }) {
                knownTools.remove(at: oldIdx)
            }
        }

        knownTools.append(KnownTool(id: toolID,
                                    nickname: kind,
                                    kind: kind,
                                    serial: identity.serial,
                                    toolCode: identity.toolCode))
        saveTools(forDevice: deviceID)
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

    // MARK: - Device switch

    /// Loads the tool list for `deviceID` into `knownTools`.
    /// The `kind` field is refreshed on load so that improved model names
    /// are picked up automatically.  Called by `recordTablet` and when the
    /// user selects a different tablet in DevicesView.
    func loadTools(forDevice deviceID: Int) {
        guard let data = ud.data(forKey: toolsKey(deviceID)),
              var list = try? JSONDecoder().decode([KnownTool].self, from: data)
        else { knownTools = []; return }

        var changed = false
        for i in list.indices {
            let freshKind: String
            if let tc = list[i].toolCode {
                freshKind = Self.penName(forToolCode: tc)
            } else {
                let isEraser = list[i].id == "eraser" || list[i].id.hasPrefix("eraser-")
                freshKind = Self.penName(forProductID: deviceID, isEraser: isEraser)
            }
            if list[i].kind != freshKind { list[i].kind = freshKind; changed = true }
        }
        knownTools = list
        if changed { saveTools(forDevice: deviceID) }
    }

    // MARK: - Helpers

    /// Canonical tool ID string for a ToolIdentity.
    static func toolID(for identity: ToolIdentity) -> String {
        if identity.serial == 0 {
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
