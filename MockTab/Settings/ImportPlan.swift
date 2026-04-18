import Foundation

/// The result of parsing a v2 JSON backup: one entry per tablet found in the file.
struct ImportPlan {
    struct TabletEntry {
        let productID: Int
        let modelName: String
        let nickname: String
        /// The preset name that will be created (may have suffix if name already taken).
        let resolvedProfileName: String
        /// All keys/values ready to write to UserDefaults for the preset.
        let profileValues: [String: Any]
        /// True if this productID is already in the registry.
        let isKnown: Bool
    }

    let sourceDate: String
    let entries: [TabletEntry]
}
