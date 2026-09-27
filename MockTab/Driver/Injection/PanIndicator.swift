// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import OSLog

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "injection")

/// Pan View's engaged-state badge: a small symbol beside the stationary
/// pointer, like Firefox autoscroll. The pointer itself can't be restyled —
/// only the frontmost app sets the cursor — so this sits next to it in a
/// click-through panel instead. Nothing moves while panning, so a plain
/// window has none of the overlay-lag problems a tracking cursor would.
@MainActor
final class PanIndicator {
    static let shared = PanIndicator()

    /// Canvas at pointer size 1, drawn 1:1 so the stroke reads like the arrow's.
    private static let baseSize: CGFloat = 24
    /// Center of the badge relative to the hotspot: just past the arrow's tail.
    private static let baseCenterOffset = CGPoint(x: 17, y: -20)

    /// The user's pointer settings (System Settings > Accessibility > Display
    /// > Pointer), read from their preferences domain — no permission needed.
    private struct Style: Equatable {
        var scale: CGFloat = 1
        var fill: NSColor = .black
        var outline: NSColor = .white

        static func current() -> Style {
            let domain = "com.apple.universalaccess" as CFString
            func read(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain) }
            func color(_ key: String) -> NSColor? {
                guard let c = read(key) as? [String: Double],
                      let r = c["red"], let g = c["green"], let b = c["blue"]
                else { return nil }
                return NSColor(srgbRed: r, green: g, blue: b, alpha: c["alpha"] ?? 1)
            }
            var style = Style()
            if let size = read("mouseDriverCursorSize") as? Double {
                style.scale = CGFloat(min(max(size, 1), 4))
            }
            if read("cursorIsCustomized") as? Bool == true {
                style.fill = color("cursorFill") ?? style.fill
                style.outline = color("cursorOutline") ?? style.outline
            }
            return style
        }
    }

    private var style: Style?

    private lazy var imageView: NSImageView = {
        let image = NSImageView()
        image.imageScaling = .scaleNone
        // Matches the system cursors' shadow: 45% black, blur 2, 1 pt down.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        image.shadow = shadow
        return image
    }()

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.baseSize, height: Self.baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = imageView
        return panel
    }()

    /// Four-way arrow in the system cursor style: filled, outlined. A plain
    /// vector path, so the outline is a real stroke; rendered once per style
    /// and backing scale, cached by NSImage.
    private static func moveGlyph(_ style: Style) -> NSImage {
        let size = baseSize * style.scale
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // One arm (up), then the inner corner to its right; rotated four
            // times clockwise to close the outline.
            let tip: CGFloat = 7.25, headBase: CGFloat = 4, headHalf: CGFloat = 3, shaftHalf: CGFloat = 1
            let arm = [
                CGPoint(x: -shaftHalf, y: headBase), CGPoint(x: -headHalf, y: headBase),
                CGPoint(x: 0, y: tip), CGPoint(x: headHalf, y: headBase),
                CGPoint(x: shaftHalf, y: headBase), CGPoint(x: shaftHalf, y: shaftHalf),
            ]
            let path = CGMutablePath()
            path.addLines(between: (0..<4).flatMap { quarter in
                let t = CGAffineTransform(rotationAngle: -CGFloat(quarter) * .pi / 2)
                return arm.map { $0.applying(t) }
            }, transform: CGAffineTransform(scaleX: style.scale, y: style.scale)
                .concatenating(CGAffineTransform(translationX: size / 2, y: size / 2)))
            path.closeSubpath()
            cg.setLineJoin(.round)
            cg.addPath(path)
            cg.setStrokeColor(style.outline.cgColor)
            cg.setLineWidth(2.5 * style.scale)
            cg.strokePath()
            cg.addPath(path)
            cg.setFillColor(style.fill.cgColor)
            cg.fillPath()
            return true
        }
    }

    func show() {
        // Re-read per engage so pointer changes apply without a relaunch.
        let current = Style.current()
        if current != style {
            style = current
            imageView.image = Self.moveGlyph(current)
            let size = Self.baseSize * current.scale
            panel.setContentSize(NSSize(width: size, height: size))
            logger.info("PanIndicator: pointer scale \(current.scale, privacy: .public), customized colors \(current.fill != .black || current.outline != .white, privacy: .public)")
        }
        let size = Self.baseSize * current.scale
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(
            x: mouse.x + Self.baseCenterOffset.x * current.scale - size / 2,
            y: mouse.y + Self.baseCenterOffset.y * current.scale - size / 2))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
