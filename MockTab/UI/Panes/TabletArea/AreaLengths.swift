// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How the Tablet Area pane shows the active area's size: millimeters, or
/// inches on a Mac set to the US system. Percentages of the surface stand in
/// when its size is unknown.
struct AreaLengths {
    /// The surface as it sits once turned, or nil when unknown.
    let surfaceMM: CGSize?

    private enum Unit { case millimeters, inches, percent }

    private var unit: Unit {
        guard surfaceMM != nil else { return .percent }
        return Locale.current.measurementSystem == .us ? .inches : .millimeters
    }

    var symbol: String {
        switch unit {
        case .millimeters: String(localized: "mm", comment: "Unit after the Tablet Area pane's size")
        case .inches: String(localized: "in", comment: "Unit after the Tablet Area pane's size")
        case .percent: "%"
        }
    }

    func shown(_ fraction: Double, horizontal: Bool) -> String {
        let value = value(of: fraction, horizontal: horizontal)
        return value.formatted(.number.precision(.fractionLength(unit == .inches ? 1 : 0)))
    }

    func spoken(_ fraction: Double, horizontal: Bool) -> String {
        if let surfaceMM {
            return AreaSpokenSize.millimeters(surfaceMM).length(of: fraction, horizontal: horizontal)
        }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// The fraction of the surface a typed length asks for. A bare number is
    /// in the shown unit; "mm", "cm", "in", or "%" after it picks another.
    func fraction(fromTyped text: String, horizontal: Bool) -> Double? {
        var number = text.trimmingCharacters(in: .whitespaces).lowercased()
        var typedUnit = unit
        var scale = 1.0
        for (suffix, suffixUnit, suffixScale) in [
            ("mm", Unit.millimeters, 1.0), ("cm", .millimeters, 10), ("in", .inches, 1),
            ("\"", .inches, 1), ("%", .percent, 1),
        ] where number.hasSuffix(suffix) {
            number = String(number.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            typedUnit = surfaceMM == nil ? .percent : suffixUnit
            scale = suffixScale
            break
        }
        guard let value = try? Double(number, format: .number), value > 0 else { return nil }
        let side = surfaceMM.map { horizontal ? $0.width : $0.height } ?? 0
        switch typedUnit {
        case .millimeters: return value * scale / side
        case .inches: return value * 25.4 / side
        case .percent: return value / 100
        }
    }

    private func value(of fraction: Double, horizontal: Bool) -> Double {
        let side = surfaceMM.map { horizontal ? $0.width : $0.height } ?? 0
        switch unit {
        case .millimeters: return fraction * side
        case .inches: return fraction * side / 25.4
        case .percent: return fraction * 100
        }
    }

    /// A familiar name for a width-to-height shape, such as "16:10", or nil
    /// when the shape isn't within 1% of one.
    static func shapeName(aspect: Double) -> String? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        let ratios = [(16, 9), (16, 10), (3, 2), (4, 3), (5, 4), (1, 1), (21, 9)]
        for (long, short) in ratios {
            for (w, h) in [(long, short), (short, long)] where abs(aspect / (Double(w) / Double(h)) - 1) < 0.01 {
                return "\(w):\(h)"
            }
        }
        return nil
    }
}
