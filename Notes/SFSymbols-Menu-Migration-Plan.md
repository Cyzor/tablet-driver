# MockTab — SF Symbols in Action Menus: Migration Plan

_Drafted 2026-05-08. Deploy when the HIG hardens this recommendation for macOS 26, or at the author's discretion._

## Context

Apple's HIG for macOS 26 recommends SF Symbol images alongside text in action menus and context menus (`.contextMenu`, SwiftUI `Menu`). MockTab currently uses plain `Button("text")` in all three sites below. This is **not a compile error** and the app is not non-conforming — it is a stylistic gap that may become more visible as macOS 26 ships.

This plan covers the three SwiftUI `Menu` / `.contextMenu` call sites that contain user-visible action items. It does **not** cover:

- `NSMenuItem`-based main-menu commands (`MockTabApp.swift`, `MenuBarView.swift`) — `NSMenuItem.image` assignment is separate work and unrelated to SwiftUI `Label`.
- Toolbar buttons — already use SF Symbols.
- Any list-row decoration icons — already use SF Symbols as decorative images.

---

## Scope: three files, ~15 items

| File | Menu trigger | Item count |
|---|---|---|
| `MockTab/UI/Components/AppOverrideBar.swift` | Plus button → add-app context menu | 2 |
| `MockTab/UI/Panes/ProfilesView.swift` | Ellipsis button → profile actions | 5 |
| `MockTab/UI/Panes/ButtonMappingView.swift` | Ellipsis button → click-action menu | ~8 |

---

## Pattern

**Before:**
```swift
Button("Duplicate") { … }
Button("Delete", role: .destructive) { … }
```

**After:**
```swift
Button { … } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
Button(role: .destructive) { … } label: { Label("Delete", systemImage: "trash") }
```

`Label` composes a system image with a title string. SwiftUI renders the image automatically when the button appears inside a `Menu` or `.contextMenu`. In other contexts (e.g., a plain `HStack`) it renders inline — no behaviour change, just richer presentation.

Accessibility is unaffected: `Label` merges the text into the accessibility element automatically; VoiceOver reads only the title string.

---

## Symbol mapping

### AppOverrideBar.swift — add-app context menu

| Item text | Proposed symbol |
|---|---|
| "Choose App…" / "Browse…" | `folder` |
| "Add Active App" | `plus.app` |

_(Exact item text: verify against the live `Menu` block. The two actions are "pick from file panel" and "add the frontmost app".)_

### ProfilesView.swift — profile actions menu

| Item text | Proposed symbol |
|---|---|
| "Rename…" | `pencil` |
| "Duplicate" | `plus.square.on.square` |
| "Export JSON" | `arrow.up.doc` |
| "Import JSON" | `arrow.down.doc` |
| "Delete" (destructive) | `trash` |

_(Verify item count — there may also be a "Set as Default" item; use `checkmark` for that.)_

### ButtonMappingView.swift — click-action menu

| Item text | Proposed symbol |
|---|---|
| "No Action" | `circle.slash` |
| "Left Click" | `hand.point.left` |
| "Right Click" | `hand.point.right` |
| "Middle Click" | `button.vertical.square` |
| "Back" | `arrow.left` |
| "Forward" | `arrow.right` |
| "Open / Launch…" | `arrow.up.right.square` |
| "Keystroke…" | `keyboard` |

_(The full item list must be verified — ButtonMappingView builds its menu dynamically from `ButtonAction` cases. Update this table to match before implementing.)_

---

## Implementation steps

1. **Verify item text and structure** for each of the three menus by reading the current source before touching anything. The symbol table above is a draft based on the known actions; it may need adjustment.

2. **AppOverrideBar.swift** — smallest menu, do first as a test.
   - Find the `Menu { … } label: { … }` block that triggers on the plus/add button.
   - Replace each `Button("text")` inside with `Button { } label: { Label("text", systemImage: "…") }`.
   - Build and inspect in the app — confirm symbols appear and VoiceOver reads only the title.

3. **ProfilesView.swift** — five items.
   - Same mechanical change. The `Delete` item already uses `role: .destructive`; preserve that.
   - If there is a "Set as Default" / active-profile toggle item, use `checkmark` and conditionally fill it (`checkmark.circle.fill` when active).

4. **ButtonMappingView.swift** — largest, menu is likely built from a `ForEach` or `switch` over `ButtonAction` cases.
   - If the menu is a `ForEach` over an enum, add a `var menuSymbol: String` computed property to `ButtonAction` and use `Label(action.label, systemImage: action.menuSymbol)`.
   - If the menu is explicit `Button` calls, replace inline.

5. **Smoke-test all three menus** by opening the app and inspecting each. Confirm:
   - Each item shows an icon.
   - Destructive items retain red tinting (SwiftUI applies this automatically from `role: .destructive`).
   - VoiceOver reads item titles without the symbol name.

6. **No pbxproj changes needed** unless a new Swift file is introduced (the `ButtonAction` symbol property approach above does not require a new file).

---

## Trigger condition

Deploy this when any of the following is true:

- Apple ships macOS 26 and App Review / HIG guidance explicitly requires symbol-annotated menu items.
- A beta of macOS 26 shows visual degradation (e.g., a blank glyph slot) for plain `Button` in `Menu`, indicating the shell now expects `Label`.
- The author wants to ship it proactively — the change is purely additive and safe at any time.

There is no urgency as of 2026-05-08.

---

## What this plan does NOT cover

- **NSMenuItem images** (main menu, menu bar extra) — those require `NSMenuItem.image = NSImage(systemSymbolName:…)` and belong in a separate plan.
- **Toolbar buttons** — already done.
- **Keyboard shortcut display** — SwiftUI renders `.keyboardShortcut(…)` automatically alongside `Label`; no extra work.
- **Custom canvas views** (scratchpad, pressure curve, area selector) — these are deferred accessibility work (Pass 4 in the a11y plan), not menu-symbol work.
