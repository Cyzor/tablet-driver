# Session 5: CLI + JSON Profile Export — Design & Implementation Plan

**Date:** 2026-03-28  
**Session Type:** Architecture review + feature planning  
**Outcome:** Two-phase implementation plan decided (light now, full later)

---

## Context

User asked: "How feasible would it be to include a basic faceless version for computers too old or unwilling to use a newer OS? Maybe a command line interface could load profiles built elsewhere."

### Project Overview
- **MockTab**: Native Swift tablet driver for Wacom tablets on macOS 13+
- **Architecture**: Cleanly separated driver (IOKit-based) from SwiftUI UI
- **Current GUI**: SwiftUI menu bar app with preferences window (8 tabs)
- **Settings**: Per-device UserDefaults with preset system (already Codable)

---

## Feasibility Assessment: VERY HIGH ✓

### Why It Works

1. **Settings are UI-agnostic**
   - `TabletSettings` uses `UserDefaults` directly, zero SwiftUI dependencies
   - Core models already implement `Codable`: `Preset`, `BezierCurve`, `ButtonBinding`, `ToolSettings`
   
2. **Driver is SwiftUI-agnostic**
   - `TabletManager`, `InputInjector`, device decoders are pure Swift
   - Uses only IOKit + Foundation (ancient, stable macOS APIs)
   - No GUI dependencies anywhere

3. **JSON is portable**
   - Profiles can be exported as JSON, edited manually, imported on different machines
   - Perfect for users on older OS versions to build config on newer machine, load on legacy

### Architecture Layers

```
UIKit/AppKit/SwiftUI (menu bar, 8-tab preferences)
  ↓ (depends on)
Settings Layer (TabletSettings, ToolSettings, Presets — all Codable)
  ↓ (depends on)
Driver Layer (TabletManager, InputInjector, device decoders — pure Swift/IOKit)
  ↓ (depends on)
Foundation + IOKit (stable macOS APIs)
```

CLI would share Layers 2–4 with the GUI.

---

## Feature Options Considered

### Option 1: CLI with UserDefaults Sharing
- CLI and GUI both read/write same UserDefaults database
- Commands: `mocktab profile activate`, `mocktab status`, `mocktab devices list`, etc.
- **Pros:** Full power, GUI and CLI stay in sync
- **Cons:** Still requires Swift 5.0+ (which is fine — available since macOS 10.14.4+)

### Option 2: CLI with JSON File Profiles ← **CHOSEN**
- CLI imports/exports profiles as JSON files
- GUI can also export profiles for manual sharing
- Commands: `mocktab-cli profile export profile.json`, `mocktab-cli profile import profile.json`
- **Pros:** Portable, human-editable, works cross-machine, minimal GUI coupling
- **Cons:** Slightly less integrated (separate file per profile, not live sync)

### Option 3: Backward Compatibility Layer
- CLI targets macOS 10.13 or earlier
- Would require careful API selection
- **Status:** Deferred; insufficient user demand yet

---

## Decision: Two-Phase Implementation (Option 2)

### Rationale

**Light setup now (1–2 hours):**
- Establishes JSON schema early
- Forces architectural clarity on what's exportable
- `Codable` conformance check catches issues before settings design locks
- Zero risk: no UI changes, just data models

**Full CLI later (4–8 hours, when GUI stable):**
- Settings schema is frozen, no moving targets
- Easy to implement because format is already defined
- Users get value immediately once GUI is feature-complete

---

## Phase 1: Light Setup (THIS SESSION) — 1–2 Hours

### 1.1 Create `Profile.swift`

**File location:** `MockTab/Settings/Profile.swift`

**Purpose:** Portable snapshot of device + tool settings

**Key points:**
- `Codable` for JSON serialization
- Contains device settings (area, display, pressure curve, button mappings)
- Includes aux settings (touch ring)
- Future: per-serial tool settings (Phase 2)
- Does NOT include per-device UserDefaults namespace (that's runtime storage, not profile)

**Model structure:**
```swift
struct Profile: Codable, Equatable {
    var name: String
    var deviceModel: String
    
    // Tablet area mapping
    var tabletAreaX/Y/Width/Height: Double
    var proportionalMapping: Bool
    var targetDisplayIndex: Int
    
    // Pressure response
    var pressureCurve: BezierCurve       // already Codable ✓
    var smoothingStrength: Double
    
    // Button bindings
    var penButton1/2: ButtonBinding      // already Codable ✓
    var tipBinding/eraserBinding: ButtonBinding
    
    // Aux
    var touchRingMode: String
    var touchRingButtonBinding: ButtonBinding
    
    // Future (Phase 2)
    var toolSettingsPerSerial: [String: ToolSnapshot]? = nil
}
```

**Codable chain check:**
- `Profile` ← requires `BezierCurve` (✓ already Codable), `ButtonBinding` (✓ already Codable)
- `BezierCurve` ← contains `CGPoint` (✓ Codable in Swift 5+)
- `ButtonBinding` ← contains `UInt16`, `UInt64`, `String` (✓ all Codable primitives)

### 1.2 Add export/import to TabletSettings

**File:** `MockTab/Settings/TabletSettings.swift` (add methods to class)

```swift
func exportCurrentAsProfile(name: String, deviceName: String) -> Profile {
    // Snapshot all current device settings into a Profile struct
}

func importProfile(_ profile: Profile) {
    // Apply all Profile fields back to TabletSettings @Published properties
}
```

**Why two methods, not one round-trip?**
- Export: captures `activeContext.settings` (single device) at a moment in time
- Import: applies to whichever device is currently connected
- Asymmetric by design: GUI manages *one active device* at a time

### 1.3 Example JSON profile

**File:** `MockTab/example-profile.json` (document the schema)

Shows:
- All top-level keys
- ButtonBinding structure (kind, keyCode, modifierFlags, keyLabel)
- BezierCurve structure (p1 and p2 control points)
- Real-world values (e.g., proportionalMapping: true, touchRingMode: "scroll")

**Purpose:** Users know what a profile looks like before CLI exists

### 1.4 Unit test: round-trip JSON

**File:** `MockTabTests/ProfileCodingTests.swift` (new)

Test that:
- Encode Profile → JSON
- Decode JSON → Profile
- Round-trip produces identical object

**Why now?** Catches Codable errors early; validates all nested models work

---

## Phase 2: Full CLI Implementation (LATER, 4–8 hours)

When GUI is feature-complete and `TabletSettings` schema is stable:

### 2.1 New CLI target

Xcode project structure:
```
MockTab.xcodeproj/
  MockTab (app, GUI)
  MockTabCLI (command-line executable)
  MockTabCore (shared framework) — optional, depends on refactor scope
```

### 2.2 Shared code

Move/link to CLI target:
- `Profile.swift` (new)
- `TabletSettings.swift`
- `ToolSettings.swift`
- `BezierCurve.swift`
- `ButtonBinding.swift`
- `WacomDeviceRegistry.swift` (for device names)

Driver code NOT needed for basic CLI (profiles are static JSON).

### 2.3 CLI commands

```bash
# Export current settings (if tablet connected)
$ mocktab-cli profile export MyProfile

# Import a profile into current device settings
$ mocktab-cli profile import MyProfile.json

# List all defined profiles
$ mocktab-cli profile list

# Show connected devices and current active profile
$ mocktab-cli status

# Watch for device changes (daemon mode, optional)
$ mocktab-cli watch

# Query device registry (optional)
$ mocktab-cli devices info --pid 0x0357
```

### 2.4 Implementation notes

- **Argument parsing:** Use `Foundation.CommandLine` or add dependency (e.g., `ArgumentParser`)
- **JSON I/O:** `JSONEncoder`/`JSONDecoder` (already in use elsewhere)
- **UserDefaults:** CLI reads same `com.cyzor.mocktab` domain as GUI
- **Profiles directory:** `~/.mocktab/profiles/` (or per XDG spec)
- **Error handling:** Print to stderr, exit codes 0 (success) / 1 (error)

---

## JSON Schema (Final Format)

See `example-profile.json` in project for full example. Structure:

```
Profile
├─ name: String                    // "Creative Work"
├─ deviceModel: String             // "Wacom Intuos Pro M"
├─ tabletAreaX/Y/Width/Height: Double
├─ proportionalMapping: Bool
├─ targetDisplayIndex: Int
├─ pressureCurve: BezierCurve
│  ├─ p1: CGPoint { x, y }
│  └─ p2: CGPoint { x, y }
├─ smoothingStrength: Double
├─ penButton1/2: ButtonBinding
│  ├─ kind: String ("none" | "leftClick" | "rightClick" | "middleClick" | "keyCombo")
│  ├─ keyCode: UInt16
│  ├─ modifierFlags: UInt64
│  └─ keyLabel: String
├─ tipBinding/eraserBinding: ButtonBinding
├─ touchRingMode: String           // "scroll" | "off"
├─ touchRingButtonBinding: ButtonBinding
└─ toolSettingsPerSerial?: {String: ToolSnapshot}  // Phase 2, future
```

---

## Architectural Benefits (Why Do This)

### Immediate (Phase 1)
1. **Schema clarity**: Forces decision on "what's exportable?" before settings lock
2. **Early validation**: Codable check catches serialization bugs now, not later
3. **Zero risk**: No UI changes, just data models and unit tests
4. **Documentation**: JSON example shows users what a profile is

### Long-term (Phase 2)
1. **Portability**: Profiles move between machines, OS versions
2. **Automation**: Scripts can generate/manipulate profiles programmatically
3. **Backup**: JSON profiles are human-readable diffs (better than binary UserDefaults)
4. **Community**: Users can share profiles online
5. **Legacy support**: Old macOS versions can use profiles built on newer machines

---

## File Checklist

### To Create (Phase 1)
- [ ] `MockTab/Settings/Profile.swift` — new `Profile` + `ToolSnapshot` structs
- [ ] `MockTab/example-profile.json` — schema documentation
- [ ] `MockTabTests/ProfileCodingTests.swift` — round-trip test (optional but recommended)

### To Modify (Phase 1)
- [ ] `MockTab/Settings/TabletSettings.swift` — add `exportCurrentAsProfile()` + `importProfile()`
- [ ] `todo.md` — update status (mark Phase 1 complete)
- [ ] `progress.md` — log Phase 1 completion

### To Create (Phase 2, LATER)
- [ ] `MockTabCLI/main.swift` — command dispatch
- [ ] `MockTabCLI/Commands/ProfileCommand.swift`
- [ ] `MockTabCLI/Commands/DeviceCommand.swift`
- [ ] etc.

---

## Resume Guide for Next Session

### If picking up Phase 1 implementation:

1. Read this document (you're reading it now)
2. Open `MockTab/Settings/TabletSettings.swift`, examine existing structure
3. Create `MockTab/Settings/Profile.swift` with exact struct definitions (see section 1.1)
4. Add export/import methods to `TabletSettings` (see section 1.2)
5. Create `example-profile.json` in project root (see section 1.3)
6. Write unit test in `MockTabTests/ProfileCodingTests.swift` (see section 1.4)
7. Build & test: `xcodebuild test -project MockTab.xcodeproj`
8. Update `todo.md` mark Phase 1 complete

**Expected time:** 1–2 hours  
**Risk level:** Very low (no GUI changes, backward compatible)  
**Testing:** Unit test validates JSON round-trip

### If picking up Phase 2 implementation:

1. Re-read sections 2.1–2.4 of this document
2. Create CLI target in Xcode
3. Share `Profile.swift`, `TabletSettings.swift`, etc. via framework or symlink
4. Implement command router (use `CommandLine.arguments`)
5. Start with simplest command: `profile list` (read `~/.mocktab/profiles/*.json`)
6. Add JSON I/O helpers (encode/decode utilities)
7. Implement remaining commands incrementally
8. Add `man` page or `--help` output

**Expected time:** 4–8 hours  
**Risk level:** Low (shares only settings models, no driver code)  
**Dependencies:** ArgumentParser (optional, add if CLI scales)

---

## Key Decisions Locked

1. **Option 2 chosen** — JSON file profiles, not UserDefaults sharing
2. **Two phases** — Light now (1–2h), full later (4–8h)
3. **Schema in Phase 1** — Establishes contract before GUI changes further
4. **Phase 2 deferred** — When GUI design is stable (1–2 months)
5. **Legacy OS support deferred** — Sufficient user demand not yet confirmed

---

## Open Questions (Deferred)

1. **Profile storage location**: `~/.mocktab/profiles/` vs. `~/Library/Application Support/MockTab/Profiles/` vs. XDG?
2. **Naming scheme**: `ProfileName.json` vs. `ProfileName.mocktab` vs. version header?
3. **Per-serial tools**: Should Phase 2 CLI support per-pen-serial settings from the start?
4. **Touch ring button field**: Currently `activeTool.tipBinding` is used as placeholder; real field needed in UI first

---

## References

- **Project documentation:** `CLAUDE.md`, `progress.md`, `README.md`
- **Settings architecture:** `MockTab/Settings/TabletSettings.swift` (line 17+)
- **Models already Codable:** `BezierCurve.swift`, `ButtonBinding.swift`, `Preset` struct (in TabletSettings)
- **Example JSON:** To be created as `example-profile.json`

---

## Session Notes

### What Went Well
- Clear architecture separation makes CLI trivial
- All required models already `Codable`
- No breaking changes needed

### What to Watch For
- `TouchRingMode` enum and `ToolSettings` might need minor adjustments for full export
- `activeTool.touchRingButtonBinding` needs dedicated field (currently using tipBinding as placeholder)
- Per-serial tool settings (Phase 2) requires clarification on JSON structure

---

_End of Session 5 summary. Next session: implement Phase 1._
```

Now let me create a focused resumption guide: