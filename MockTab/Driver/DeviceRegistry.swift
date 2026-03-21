import Foundation

/// Persistent registry of tablets and tools the user has ever connected.
///
/// Tablets are stored globally (one entry per product ID).
/// Tools are stored per-device under the device-scoped UserDefaults namespace,
/// and are loaded/swapped when the active device changes.
///
/// Called by TabletManager on device connection and on each report that
/// includes a proximity event.
@MainActor
final class DeviceRegistry: ObservableObject {

    static let shared = DeviceRegistry()

    struct KnownTablet: Identifiable, Codable, Equatable {
        let id:        Int     // productID — immutable unique key
        var nickname:  String  // user-editable; defaults to modelName
        let modelName: String  // set at first-seen time (e.g. "PTH-860")
    }

    struct KnownTool: Identifiable, Codable, Equatable {
        let id:       String  // "stylus" or "eraser"
        var nickname: String  // user-editable; defaults to kind on first creation
        var kind:     String  // human-readable pen model + type, refreshed on load
    }

    @Published var knownTablets: [KnownTablet] = []
    @Published var knownTools:   [KnownTool]   = []

    private let ud = UserDefaults.standard

    private init() { loadTablets() }

    // MARK: - Pen model lookup

    /// Returns the model name of the pen bundled with a given Wacom tablet,
    /// optionally qualified with "(Eraser)" for the reverse end.
    static func penName(forProductID productID: Int, isEraser: Bool) -> String {
        let base: String
        switch productID {
        case 0x0358, 0x0357:  base = "Pro Pen 2"        // Intuos Pro M/L (2017+)
        case 0x0317:          base = "Grip Pen"          // Intuos 5 Large
        case 0x00B5:          base = "Grip Pen"          // Intuos3 Widescreen
        case 0x00F4:          base = "Grip Pen"          // Cintiq 24HD
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

    /// Called when proximity changes for the given device.
    /// Adds a tool entry the first time each type (stylus / eraser) is seen.
    func recordTool(isEraser: Bool, forDevice deviceID: Int) {
        let toolID = isEraser ? "eraser" : "stylus"
        guard !knownTools.contains(where: { $0.id == toolID }) else { return }
        let kind = Self.penName(forProductID: deviceID, isEraser: isEraser)
        knownTools.append(KnownTool(id: toolID, nickname: kind, kind: kind))
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
    /// The `kind` field is refreshed from the current pen-name table on every
    /// load so that existing persisted entries pick up improved model names
    /// automatically.  Called automatically by `recordTablet` and may also be
    /// called directly when the user selects a different tablet in DevicesView.
    func loadTools(forDevice deviceID: Int) {
        guard let data = ud.data(forKey: toolsKey(deviceID)),
              var list = try? JSONDecoder().decode([KnownTool].self, from: data)
        else { knownTools = []; return }

        // Refresh the kind label in case the name mapping was improved.
        var changed = false
        for i in list.indices {
            let isEraser  = list[i].id == "eraser"
            let freshKind = Self.penName(forProductID: deviceID, isEraser: isEraser)
            if list[i].kind != freshKind { list[i].kind = freshKind; changed = true }
        }
        knownTools = list
        if changed { saveTools(forDevice: deviceID) }
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
