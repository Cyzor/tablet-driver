// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// Small AppKit views that more than one pane hosts in SwiftUI.

// MARK: - Hosting window

/// Weak handle to the window a view lives in, filled in by `WindowReader`.
final class WindowRef {
    weak var window: NSWindow?
}

/// Records the hosting window into `ref`, so an action can target the window
/// it came from rather than whichever one is key.
struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> NSView { Probe(ref: ref) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let ref: WindowRef
        init(ref: WindowRef) {
            self.ref = ref
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Record, never clear: several readers can share one ref, and a
            // reader leaving the pane (the Screen Area section on switching to
            // Toggle) must not blank the window for the ones that stay. The
            // ref is weak, so a closed window still clears itself.
            if let window { ref.window = window }
        }
    }
}

// MARK: - Radio indicator

/// Display-only native macOS radio button. A real `NSButton`, so it fades
/// with its window like any system control.
/// Position (circle left, label right) is controlled by the enclosing HStack.
/// Interaction is handled by the parent — this view ignores hit-testing.
struct NativeRadioIndicator: NSViewRepresentable {
    let isSelected: Bool

    func makeNSView(context: Context) -> RadioIndicatorView { RadioIndicatorView() }

    func updateNSView(_ view: RadioIndicatorView, context: Context) {
        view.button.state = isSelected ? .on : .off
    }

    final class RadioIndicatorView: NSView {
        let button = NSButton(radioButtonWithTitle: "", target: nil, action: nil)

        override init(frame: NSRect) {
            super.init(frame: frame)
            button.imagePosition = .imageOnly
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setAccessibilityElement(false)
            addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: centerXAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Right-click menu

/// Serves a right-click menu without stealing any other mouse event:
/// `hitTest` returns nil for everything but a right mouse-down, so clicks and
/// drags fall through to the SwiftUI views beneath. It builds and pops the
/// `NSMenu` itself inside `rightMouseDown`, because SwiftUI's `.contextMenu`
/// reads its content at menu-open time and could show the previous
/// selection's menu.
struct RightClickMenuHost: NSViewRepresentable {
    let menuBuilder: (CGPoint) -> NSMenu?

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.menuBuilder = menuBuilder
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.menuBuilder = menuBuilder
    }

    final class CatcherView: NSView {
        var menuBuilder: ((CGPoint) -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            // AppKit's y-axis grows upward; the SwiftUI-side hit-testing
            // (`region(at:in:)`) expects the same top-left origin GeometryReader
            // reports, so flip once here rather than teach that math two origins.
            let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
            guard let menu = menuBuilder?(flipped) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
