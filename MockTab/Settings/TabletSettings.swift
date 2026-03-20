import Foundation
import SwiftUI

/// All user-configurable settings, persisted via UserDefaults / @AppStorage.
/// Published so SwiftUI views update automatically.
@MainActor
final class TabletSettings: ObservableObject {

    // MARK: - Active area (fractions of the full digitizer surface, 0.0..1.0)

    @AppStorage("activeAreaX") var activeAreaX: Double = 0.0
    @AppStorage("activeAreaY") var activeAreaY: Double = 0.0
    @AppStorage("activeAreaWidth")  var activeAreaWidth:  Double = 1.0
    @AppStorage("activeAreaHeight") var activeAreaHeight: Double = 1.0

    // MARK: - Display mapping

    /// 0 = primary display, 1..N = specific display by index in CGGetActiveDisplayList order.
    @AppStorage("targetDisplayIndex") var targetDisplayIndex: Int = 0

    // MARK: - Pressure curve

    @Published var pressureCurve: BezierCurve = .linear {
        didSet { savePressureCurve() }
    }

    // MARK: - Input smoothing

    /// Extra software EMA smoothing on top of hardware filtering.
    /// 0 = raw hardware output, 1 = maximum smoothing (less jitter, more lag).
    @AppStorage("smoothingStrength") var smoothingStrength: Double = 0.0

    /// Radius in screen pixels within which a second tap is snapped to the
    /// first tap position, ensuring reliable double- and triple-click detection.
    /// 0 = disabled.  Wacom typically defaults to ~10 pt.
    @AppStorage("doubleClickDistance") var doubleClickDistance: Double = 10.0

    // MARK: - Button mapping

    @AppStorage("penButton1Action") var penButton1Action: Int = ButtonAction.rightClick.rawValue
    @AppStorage("penButton2Action") var penButton2Action: Int = ButtonAction.middleClick.rawValue

    // Express key mappings (up to 8 keys, stored as comma-separated raw values)
    @AppStorage("expressKeyActions") private var expressKeyActionsRaw: String = ""

    var expressKeyActions: [ButtonAction] {
        get {
            expressKeyActionsRaw
                .split(separator: ",")
                .compactMap { Int($0).flatMap(ButtonAction.init) }
        }
        set {
            expressKeyActionsRaw = newValue.map { String($0.rawValue) }.joined(separator: ",")
        }
    }

    // MARK: - Init

    init() {
        loadPressureCurve()
    }

    // MARK: - Persistence helpers

    private func savePressureCurve() {
        if let data = try? JSONEncoder().encode(pressureCurve) {
            UserDefaults.standard.set(data, forKey: "pressureCurve")
        }
    }

    private func loadPressureCurve() {
        guard let data = UserDefaults.standard.data(forKey: "pressureCurve"),
              let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
        else { return }
        pressureCurve = curve
    }

    // MARK: - Convenience

    func resetToDefaults() {
        activeAreaX = 0; activeAreaY = 0
        activeAreaWidth = 1; activeAreaHeight = 1
        targetDisplayIndex = 0
        pressureCurve = .linear
        smoothingStrength = 0.0
        doubleClickDistance = 10.0
        penButton1Action = ButtonAction.rightClick.rawValue
        penButton2Action = ButtonAction.middleClick.rawValue
        expressKeyActionsRaw = ""
    }
}

// MARK: - Button action type

enum ButtonAction: Int, CaseIterable, Identifiable {
    case none         = 0
    case leftClick    = 1
    case rightClick   = 2
    case middleClick  = 3
    case undo         = 4
    case redo         = 5
    case spaceBar     = 6
    case escape       = 7

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:        return "None"
        case .leftClick:   return "Left Click"
        case .rightClick:  return "Right Click"
        case .middleClick: return "Middle Click"
        case .undo:        return "Undo (⌘Z)"
        case .redo:        return "Redo (⌘⇧Z)"
        case .spaceBar:    return "Space"
        case .escape:      return "Escape"
        }
    }
}
