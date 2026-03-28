# Architectural Assessment: CLI Feasibility for MockTab

**Date:** 2026-03-28  
**Assessment Type:** Feature viability + effort estimation  
**Conclusion:** ✅ HIGHLY FEASIBLE — Low effort, high value

---

## Executive Summary

Adding a CLI interface + JSON profile export to MockTab is **straightforward** because the codebase is already cleanly layered. The driver logic (IOKit communication, input injection) is completely separated from the SwiftUI UI, and all settings models are already `Codable` for serialization.

**Effort estimate:**
- Phase 1 (Schema + export/import): **1–2 hours**
- Phase 2 (Full CLI): **4–8 hours** (deferred until GUI stabilizes)
- **Total: 5–10 hours of work spread across 2–3 months**

---

## Architecture Layers

```
┌─────────────────────────────────────────────┐
│        SwiftUI GUI (menu bar app)           │ ← only this needs removal for CLI
├─────────────────────────────────────────────┤
│  Settings Layer (TabletSettings, Presets)   │ ← ALREADY CODABLE, NO UI DEPS
├─────────────────────────────────────────────┤
│  Driver Layer (TabletManager, Injector)     │ ← PURE SWIFT, NO UI DEPS
├─────────────────────────────────────────────┤
│  Foundation + IOKit (ancient, stable)       │ ← SAME FOR CLI
└─────────────────────────────────────────────┘
```

**Key insight:** CLI shares Layers 2–4 with the GUI. The UI is completely disposable.

---

## Current State: Settings Models

### Already Codable ✓

| Model | File | Codable? | Used in settings export? |
|-------|------|----------|--------------------------|
| `Preset` | TabletSettings.swift | ✅ Yes | Core (preset list) |
| `AppPresetBinding` | TabletSettings.swift | ✅ Yes | Secondary (app bindings) |
| `BezierCurve` | BezierCurve.swift | ✅ Yes | Core (pressure mapping) |
| `ButtonBinding` | TabletSettings.swift | ✅ Yes | Core (5 button fields) |
| `ToolSettings` | ToolSettings.swift | ⚠️ ObservableObject | Use its members, not the class |

### Not Codable (but contain Codable members)

| Model | File | Challenge | Solution |
|-------|------|-----------|----------|
| `TabletSettings` | TabletSettings.swift | ObservableObject + @Published | Create `Profile` struct with extracted fields |
| `ToolSettings` | ToolSettings.swift | ObservableObject + @Published | Extract to `ToolSnapshot` struct for JSON |

---

## Codable Chain Validation

All types in a JSON profile are serializable:

```
Profile (new, Codable)
  ├─ String (primitive) ✓
  ├─ Double (primitive) ✓
  ├─ Bool (primitive) ✓
  ├─ Int (primitive) ✓
  ├─ BezierCurve (Codable) ✓
  │  └─ CGPoint (Codable in Swift 5+) ✓
  ├─ ButtonBinding (Codable) ✓
  │  ├─ Kind enum (String, Codable) ✓
  │  └─ UInt16, UInt64, String (primitives) ✓
  ├─ [ButtonBinding] (array of Codable) ✓
  └─ TouchRingMode enum (String, Codable) ✓
```

**Verdict:** No type changes needed. Just wrap in `Profile` struct.

---

## Current Settings Storage

### Per-device UserDefaults namespace
```
"device-0x0357.activeAreaX" = 10.5
"device-0x0357.activeAreaY" = 20.0
"device-0x0357.pressureCurve" = <JSON data>
...
```

### Not persisted in UserDefaults (transient)
- Presets list (kept in memory, auto-loaded from per-device keys)
- Active tool instance (reloaded from serialized bindings)
- Per-serial tool cache (runtime-only)

### Import strategy
When user runs `mocktab-cli profile import myprofile.json`:
1. CLI decodes Profile from JSON
2. CLI calls `TabletSettings.importProfile(profile)` 
3. TabletSettings writes all fields to UserDefaults under current device's namespace
4. On next launch, GUI reads the same keys and displays the settings

---

## What Each Model Contributes to Profile

### From TabletSettings (device-level)
```swift
activeAreaX, activeAreaY, activeAreaWidth, activeAreaHeight  // tablet area
proportionalMapping                                           // aspect ratio lock
targetDisplayIndex                                            // display routing
pressureCurve                                                 // pressure response
smoothingStrength                                             // pen smoothing
touchRingMode                                                 // scroll / off
touchRingButtonBinding                                        // center button action
```

### From ToolSettings (pen/eraser level)
```swift
penButton1Binding, penButton2Binding                          // side buttons
tipBinding, eraserBinding                                     // tip + eraser actions
pressureCurve (per-tool)                                      // per-pen pressure (Phase 2)
smoothingStrength (per-tool)                                  // per-pen smoothing (Phase 2)
```

### Additional metadata
```swift
name                                                          // profile display name
deviceModel                                                   // "Wacom Intuos Pro M" (ref only)
toolSettingsPerSerial (Phase 2)                              // per-pen-serial overrides
```

---

## Export/Import Functions

### Export (GUI → JSON file)
```swift
// In TabletSettings class
func exportCurrentAsProfile(name: String, deviceName: String) -> Profile {
    // Read current activeArea*, pressureCurve, smoothingStrength, button bindings
    // Package into Profile struct
    // Return Profile (caller handles JSON encoding + file write)
}

// Usage:
let profile = settings.exportCurrentAsProfile(name: "My Setup", deviceName: "PTH-660")
let json = try JSONEncoder().encode(profile)
try json.write(to: URL(fileURLWithPath: "~/my-profile.json"))
```

### Import (JSON file → GUI)
```swift
// In TabletSettings class
func importProfile(_ profile: Profile) {
    // Apply all Profile fields to @Published properties
    // Automatically triggers UserDefaults writes + SwiftUI updates
}

// Usage:
let json = try Data(contentsOf: url)
let profile = try JSONDecoder().decode(Profile.self, from: json)
settings.importProfile(profile)
```

---

## JSON Schema Example

```json
{
  "name": "Creative Work",
  "deviceModel": "Wacom Intuos Pro M",
  "tabletAreaX": 0.0,
  "tabletAreaY": 0.0,
  "tabletAreaWidth": 216.0,
  "tabletAreaHeight": 135.0,
  "proportionalMapping": true,
  "targetDisplayIndex": 0,
  "pressureCurve": {
    "p1": { "x": 0.25, "y": 0.25 },
    "p2": { "x": 0.75, "y": 0.75 }
  },
  "smoothingStrength": 0.5,
  "penButton1": {
    "kind": "rightClick",
    "keyCode": 0,
    "modifierFlags": 0,
    "keyLabel": ""
  },
  "penButton2": {
    "kind": "middleClick",
    "keyCode": 0,
    "modifierFlags": 0,
    "keyLabel": ""
  },
  "tipBinding": {
    "kind": "leftClick",
    "keyCode": 0,
    "modifierFlags": 0,
    "keyLabel": ""
  },
  "eraserBinding": {
    "kind": "rightClick",
    "keyCode": 0,
    "modifierFlags": 0,
    "keyLabel": ""
  },
  "touchRingMode": "scroll",
  "touchRingButtonBinding": {
    "kind": "none",
    "keyCode": 0,
    "modifierFlags": 0,
    "keyLabel": ""
  }
}
```

---

## Phase 1: Schema Establishment (1–2 hours)

### Deliverables
1. **`MockTab/Settings/Profile.swift`** — new Codable struct
2. **`MockTab/Settings/TabletSettings.swift`** — add 2 methods (exportCurrentAsProfile, importProfile)
3. **`MockTab/example-profile.json`** — reference implementation of schema
4. **`MockTabTests/ProfileCodingTests.swift`** — round-trip encoding/decoding test

### Why now?
- Establishes JSON contract before Settings design evolves further
- Validates all types are actually serializable
- Zero risk (no UI changes, backward compatible)
- Takes 1–2 hours, clears path for CLI later

### Why not full CLI now?
- Settings schema may still change (adding fields, renaming)
- Full CLI wouldn't ship for weeks anyway (depends on GUI stability)
- Lightweight schema investment buys architecture clarity with minimal time cost

---

## Phase 2: Full CLI (4–8 hours, deferred until GUI stable)

### Scope
- New macOS command-line executable target
- Share Profile.swift + TabletSettings with GUI via framework or copy
- Argument parsing + JSON I/O wrappers
- 5–8 commands: profile export/import/list, devices list, status, watch

### Why later?
- Settings design needs to be locked (1–2 months of GUI development)
- CLI isn't needed until GUI is feature-complete
- Phased approach keeps iteration velocity high (schema + CLI can evolve separately)

---

## Risk Analysis

### Phase 1
| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|-----------|
| Codable types don't work | Very low | Caught by unit test | Add unit test first |
| Settings change invalidates schema | Low | Regenerate Profile from updated TabletSettings | Schema is flexible (fields can be added) |
| Export/import bugs | Low | Tested before ship | Unit test validates round-trip |

**Overall:** Very low risk. No GUI changes, no shipped code.

### Phase 2
| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|-----------|
| Settings API instability | Medium | CLI breaks if TabletSettings refactors | Wait until settings stable; use stable APIs only |
| CLI argument parsing scope creep | Low | Scope to essentials, add features incrementally | Define MVP command set upfront |
| File I/O permissions | Low | Graceful error handling | Test on sandboxed + unsandboxed scenarios |

**Overall:** Low-medium risk. Mitigated by waiting for stability.

---

## Backward Compatibility: OS Version Support

### Current
- GUI requires macOS 13.0 (SwiftUI `MenuBarExtra` + `AXIsProcessTrusted`)
- Uses Swift 5.0 (available since macOS 10.14.4)

### CLI Option 1: Match GUI requirement (macOS 13.0)
- Simple: same codebase as GUI
- No loss of capability

### CLI Option 2: Target older OS (macOS 10.14+)
- More complex: avoid MenuBarExtra, use older AppKit APIs
- Driver code already compatible (IOKit is ancient)
- No user demand yet; deferred

**Decision:** Phase 1 assumes macOS 13.0 minimum (same as GUI). Backport later if needed.

---

## Code Organization: Phase 2 Project Structure

```
MockTab.xcodeproj/
│
├─ MockTab (app target)
│  ├─ App/
│  │  ├─ MockTabApp.swift
│  │  ├─ MenuBarView.swift
│  │  ├─ PreferencesWindowController.swift
│  │  └─ ...
│  ├─ UI/
│  │  ├─ TabletAreaView.swift
│  │  └─ ...
│  ├─ Driver/
│  │  ├─ TabletManager.swift
│  │  └─ ...
│  └─ Settings/
│     ├─ TabletSettings.swift
│     ├─ ToolSettings.swift
│     ├─ Profile.swift (← NEW, Phase 1)
│     └─ ...
│
├─ MockTabCLI (executable target, Phase 2)
│  ├─ main.swift
│  ├─ Commands/
│  │  ├─ ProfileCommand.swift
│  │  ├─ DeviceCommand.swift
│  │  └─ StatusCommand.swift
│  └─ Utilities/
│     ├─ JSONProfileIO.swift
│     └─ ErrorHandling.swift
│
└─ MockTabTests
   ├─ ProfileCodingTests.swift (← NEW, Phase 1)
   └─ ...
```

**Option:** Avoid framework duplication by symlinking or using `#include` for Settings files in CLI target (simple for small codebase).

---

## Performance Considerations

### Export
- 1 `Profile` struct → JSON: ~5ms (JSONEncoder is fast)
- No I/O until file write
- No blocking calls

### Import
- File read: ~1ms (profiles are small, <10KB)
- JSON → `Profile` decode: ~5ms
- Settings apply (UserDefaults writes): ~10ms
- SwiftUI re-render: automatic (happens on main thread, gated by `infoViewVisible`)

**Impact:** Negligible. No performance concerns.

---

## User Value: Why This Matters

### For users on old OS
- Build profile on newer Mac running modern MockTab
- Export as JSON
- Transfer file to legacy Mac
- Import JSON into older MockTab (if CLI available)
- Eliminates manual UI configuration

### For power users
- Edit profiles in text editor (JSON is human-readable)
- Version control profiles in Git
- Share profiles via email / GitHub
- Script profile generation

### For MockTab ecosystem
- Portable configuration format
- Backup/restore workflows
- Community profile library possible

---

## Comparison: Option 1 vs Option 2

| Aspect | Option 1: UserDefaults Share | Option 2: JSON Files (CHOSEN) |
|--------|-----|-----|
| **Complexity** | Medium | Low |
| **Portability** | Low (tied to one Mac's prefs) | High (JSON moves anywhere) |
| **Human-readable** | No (binary .plist) | Yes (text JSON) |
| **Multi-device support** | Auto-sync (risky) | Explicit import (safer) |
| **Backward compat** | Easy (same APIs) | Trivial (just decode) |
| **GUI integration** | Tight (live sync) | Loose (manual import) |
| **File format** | OS-specific | Universal |
| **Effort (Phase 1)** | 1–2 hours | 1–2 hours |
| **Effort (Phase 2)** | 4–8 hours | 4–8 hours |

**Chosen:** Option 2 — JSON files are more portable and future-proof.

---

## Decision Summary

✅ **Build Phase 1 (light setup) now** — 1–2 hours, zero risk
- Locks JSON schema early
- Validates all types are Codable
- Creates reusable Profile struct
- No GUI changes

⏸️ **Defer Phase 2 (full CLI) until GUI stable** — 4–8 hours, ~6 weeks
- Settings design won't change further
- CLI becomes straightforward copy of Phase 1 + argument parsing
- Full value when users actually need it

**Total effort:** 5–10 hours across 2–3 months

**Risk level:** Low (Phase 1) → Low-medium (Phase 2)

**Value:** High (portability, future-proofing, community ecosystem)

---

## References

- Full implementation guide: `Notes/Session-5-CLI-JSON-Profiles-Plan.md`
- Quick resumption: `CLAUDE.md` (Quick Resumption Guide section)
- Task list: `todo.md` (Active Feature: CLI + JSON Profile Export section)
- Existing architecture: `CLAUDE.md` (Architecture section)
- Settings models: `MockTab/Settings/TabletSettings.swift`, `ToolSettings.swift`

---

_Prepared by: Claude (Session 5, 2026-03-28)_
_Ready for: Any Claude client resuming this project_