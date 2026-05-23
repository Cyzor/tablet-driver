// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Text scale environment
//
// macOS's `.dynamicTypeSize` modifier is a no-op for third-party apps:
// SwiftUI's semantic font resolver (`Font.body`, `.caption`, …) reads from
// the same private "is this app text-size-aware" bit that gates the
// Accessibility → Display → Text Size picker, and unenrolled apps don't
// flip it. To deliver real, app-wide scaling we use our own env value
// (`\.textScale`) and our own font modifier (`.appFont(_:)`) that
// multiplies a known base point size by the scale before constructing
// the Font. This route works regardless of macOS gating because we never
// ask the system for a "Dynamic Type size" — we compute point sizes
// ourselves.

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// User-controllable point-size multiplier. `AppearanceRoot` sets it
    /// from the View → Text Size submenu; `.appFont(_:)` reads it.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

// MARK: - Font roles
//
// Every visible piece of text in MockTab should resolve through one of
// these roles via `.appFont(_:)`. The base sizes mirror macOS's default
// SwiftUI font ramp so the "Standard" tier looks identical to the
// pre-migration UI.

enum AppFontRole {

    // ── SwiftUI semantic ramp (mirrors macOS defaults) ──────────────────
    case largeTitle   // 26 pt
    case title        // 22 pt
    case title2       // 17 pt
    case title3       // 15 pt
    case headline     // 13 pt semibold
    case body         // 13 pt
    case callout      // 12 pt
    case subheadline  // 11 pt
    case footnote     // 10 pt
    case caption      // 10 pt
    case caption2     // 10 pt

    // ── MockTab custom tokens ───────────────────────────────────────────
    case settingsLabel    // 13 pt — setting names, descriptions, status lines
    case settingsBadge    // 10 pt — count badges, chips
    case badgeTitle       // 12 pt — canvas overlay titles (device/app names)
    case badgeSubtitle    // 10 pt — canvas overlay subtitles (coords, model numbers)
    case settingsCaption  // 10 pt — explicit caption tier
    case monospaced       // 13 pt monospaced — coordinate / hex readouts

    // ── Escape hatch for sizes that don't fit a role ────────────────────
    /// Custom point size. Use sparingly — prefer the named roles above
    /// for consistency. Scales with the text-size preference like any
    /// other role.
    case custom(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default)

    var baseSize: CGFloat {
        switch self {
        case .custom(let s, _, _):                                        return s
        case .largeTitle:                                                 return 26
        case .title:                                                      return 22
        case .title2:                                                     return 17
        case .title3:                                                     return 15
        case .headline, .body, .settingsLabel, .monospaced:               return 13
        case .callout, .badgeTitle:                                       return 12
        case .subheadline:                                                return 11
        case .footnote, .caption, .caption2,
             .settingsBadge, .badgeSubtitle, .settingsCaption:            return 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .custom(_, let w, _): return w
        case .headline:            return .semibold
        default:                   return .regular
        }
    }

    var design: Font.Design {
        switch self {
        case .custom(_, _, let d): return d
        case .monospaced:          return .monospaced
        default:                   return .default
        }
    }
}

// MARK: - Modifier

private struct AppFontModifier: ViewModifier {
    @Environment(\.textScale) private var scale
    let role: AppFontRole

    func body(content: Content) -> some View {
        content.font(.system(
            size: role.baseSize * scale,
            weight: role.weight,
            design: role.design))
    }
}

extension View {
    /// Apply a MockTab semantic font role. Scales live with the user's
    /// Text Size choice (View → Text Size submenu). Chain SwiftUI's
    /// `.fontWeight(_:)`, `.italic()`, `.bold()` after for variants —
    /// they apply on top of the role's font.
    func appFont(_ role: AppFontRole) -> some View {
        modifier(AppFontModifier(role: role))
    }

    /// Custom-size shorthand. Equivalent to
    /// `.appFont(.custom(size: …, weight: …, design: …))`.
    /// Use sparingly — prefer named roles for consistency.
    func appFont(size: CGFloat,
                 weight: Font.Weight = .regular,
                 design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(role: .custom(size: size, weight: weight, design: design)))
    }
}

extension Font {
    /// Resolve an `AppFontRole` to a concrete `Font` at a given scale.
    /// Use at Canvas `ctx.resolve(Text(...).font(_))` sites where the
    /// `.appFont(_:)` view modifier can't compose (those return
    /// `some View`, but `Text.font(_)` requires a `Font`). The caller is
    /// responsible for supplying the current `\.textScale` —
    /// typically by reading `@AppStorage(AppearancePrefs.storageKey)`
    /// directly in the enclosing view.
    static func appFont(_ role: AppFontRole, scale: CGFloat) -> Font {
        .system(size: role.baseSize * scale, weight: role.weight, design: role.design)
    }
}

// MARK: - Appearance preferences

enum AppearancePrefs {
    /// Five user-facing choices, ordered small → large.
    static let scales: [CGFloat] = [
        0.85,   // Small
        0.92,   // Medium
        1.00,   // Standard (system default)
        1.15,   // Large
        1.30,   // Extra Large
    ]

    /// Index of "Standard".
    static let defaultIndex = 2

    /// @AppStorage key — Int index into `scales`.
    static let storageKey = "preferredTextSizeIndex"

    static func clampedIndex(_ raw: Int) -> Int {
        Swift.max(0, Swift.min(raw, scales.count - 1))
    }

    static func scale(forIndex index: Int) -> CGFloat {
        scales[clampedIndex(index)]
    }

    static func label(forIndex index: Int) -> String {
        switch clampedIndex(index) {
        case 0:  return String(localized: "Small",       comment: "Text Size submenu: smallest")
        case 1:  return String(localized: "Medium",      comment: "Text Size submenu: second-smallest")
        case 2:  return String(localized: "Standard",    comment: "Text Size submenu: system default")
        case 3:  return String(localized: "Large",       comment: "Text Size submenu: second-largest")
        case 4:  return String(localized: "Extra Large", comment: "Text Size submenu: largest")
        default: return String(localized: "Standard",    comment: "Text Size submenu: system default")
        }
    }
}

// MARK: - Appearance root

/// Wraps a SwiftUI root view to honour the user-controllable text-size
/// preference. Apply at every `NSHostingController(rootView:)` /
/// `NSHostingView(rootView:)` call site via `.withAppearance()` so each
/// window updates live when the menu choice changes.
private struct AppearanceRoot<Content: View>: View {
    @AppStorage(AppearancePrefs.storageKey)
    private var sizeIndex: Int = AppearancePrefs.defaultIndex
    let content: Content

    private var scale: CGFloat { AppearancePrefs.scale(forIndex: sizeIndex) }

    var body: some View {
        // `.environment(\.textScale, …)` is read by every explicit `.appFont(…)`
        // call in the tree. `.font(…)` on the container sets the *inherited*
        // font that any Text with no explicit modifier will use — fixing Toggle
        // primary labels, coordinate readouts, and other unlabelled Text views
        // that would otherwise silently ignore the text-size preference.
        // Views with an explicit `.appFont(…)` always override the inherited
        // font, so this cannot regress existing styled text.
        content
            .environment(\.textScale, scale)
            .font(.system(size: AppFontRole.body.baseSize * scale))
    }
}

extension View {
    /// Apply MockTab's user-controllable text-scale preference. Use at
    /// every `NSHostingController(rootView:)` site.
    func withAppearance() -> some View {
        AppearanceRoot(content: self)
    }
}
