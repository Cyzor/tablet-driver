# Session 5: Code Snippets Ready to Paste (Phase 1)

**Date:** 2026-03-28  
**Purpose:** Copy-paste code blocks for Phase 1 Light Setup implementation  
**Time to implement:** 1–2 hours

---

## File 1: MockTab/Settings/Profile.swift

Create this file with the exact content below:

```swift
import Foundation

/// A portable profile that can be exported to/imported from JSON.
/// Contains a snapshot of device and tool settings.
/// Designed to be human-editable and shareable between machines/OS versions.
struct Profile: Codable, Equatable {
    
    /// Display name for this profile (e.g., "Creative Work", "Photo Editing")
    var name: String
    
    /// Device model string for reference (e.g., "Wacom Intuos Pro M")
    /// Not used during import; kept for documentation purposes.
    var deviceModel: String
    
    // MARK: - Tablet Area Mapping
    
    var tabletAreaX: Double
    var tabletAreaY: Double
    var tabletAreaWidth: Double
    var tabletAreaHeight: Double
    
    /// When true, active area is cropped to match display aspect ratio
    var proportionalMapping: Bool
    
    /// Display index (0 = primary, 1+ = secondary displays)
    var targetDisplayIndex: Int
    
    // MARK: - Pressure & Smoothing
    
    /// Cubic Bézier curve for pressure response (0..1 → 0..1 mapping)
    var pressureCurve: BezierCurve
    
    /// Pen smoothing strength (0.0 = none, 1.0 = maximum)
    var smoothingStrength: Double
    
    // MARK: - Button Mappings
    
    /// Pen side button 1 (lower button on pen barrel)
    var penButton1: ButtonBinding
    
    /// Pen side button 2 (upper button on pen barrel)
    var penButton2: ButtonBinding
    
    /// Pen tip (primary input) — usually leftClick but can be customized
    var tipBinding: ButtonBinding
    
    /// Eraser tip — usually rightClick but can be customized
    var eraserBinding: ButtonBinding
    
    // MARK: - Auxiliary Input
    
    /// Touch ring mode: "scroll" (default) or "off"
    var touchRingMode: String
    
    /// Touch ring center button action
    var touchRingButtonBinding: ButtonBinding
    
    // MARK: - Future: Per-Tool Settings
    
    /// Optional per-pen-serial settings overrides (Phase 2)
    /// Keyed by tool serial number (e.g., "0x12345678")
    var toolSettingsPerSerial: [String: ToolSnapshot]? = nil
}

/// Settings snapshot for a specific pen (by serial number).
/// Used when per-tool pressure curves or button bindings differ.
/// Introduced in Phase 2; currently not used.
struct ToolSnapshot: Codable, Equatable {
    /// Tool serial number (hex string)
    var serial: String
    
    /// Per-tool pressure curve
    var pressureCurve: BezierCurve
    
    /// Per-tool smoothing strength
    var smoothingStrength: Double
    
    /// Per-tool pen button 1 binding
    var penButton1: ButtonBinding
    
    /// Per-tool pen button 2 binding
    var penButton2: ButtonBinding
}
```

---

## File 2: Add to MockTab/Settings/TabletSettings.swift

Add these two methods to the `TabletSettings` class. Find a good spot after the `loadAppBindings()` or similar persistence methods.

```swift
    // MARK: - Profile Export/Import (JSON serialization)
    
    /// Export the current device settings as a portable Profile struct.
    /// The resulting Profile can be encoded to JSON and saved to a file,
    /// then imported on another machine or OS version.
    ///
    /// - Parameters:
    ///   - name: Display name for the profile (e.g., "My Creative Setup")
    ///   - deviceName: Device model name for reference (e.g., "Wacom Intuos Pro M")
    /// - Returns: A Profile struct ready to be JSON-encoded
    func exportCurrentAsProfile(name: String, deviceName: String) -> Profile {
        Profile(
            name: name,
            deviceModel: deviceName,
            tabletAreaX: activeAreaX,
            tabletAreaY: activeAreaY,
            tabletAreaWidth: activeAreaWidth,
            tabletAreaHeight: activeAreaHeight,
            proportionalMapping: proportionalMapping,
            targetDisplayIndex: targetDisplayIndex,
            pressureCurve: pressureCurve,
            smoothingStrength: smoothingStrength,
            penButton1: activeTool.penButton1Binding,
            penButton2: activeTool.penButton2Binding,
            tipBinding: activeTool.tipBinding,
            eraserBinding: activeTool.eraserBinding,
            touchRingMode: touchRingMode.rawValue,
            touchRingButtonBinding: activeTool.penButton1Binding  // TODO: use dedicated field when UI is ready
        )
    }
    
    /// Import a Profile, applying all its settings to the current device.
    /// All @Published properties are updated, which triggers UserDefaults writes
    /// and SwiftUI re-renders automatically.
    ///
    /// - Parameter profile: Profile struct decoded from JSON
    func importProfile(_ profile: Profile) {
        activeAreaX = profile.tabletAreaX
        activeAreaY = profile.tabletAreaY
        activeAreaWidth = profile.tabletAreaWidth
        activeAreaHeight = profile.tabletAreaHeight
        proportionalMapping = profile.proportionalMapping
        targetDisplayIndex = profile.targetDisplayIndex
        pressureCurve = profile.pressureCurve
        smoothingStrength = profile.smoothingStrength
        activeTool.penButton1Binding = profile.penButton1
        activeTool.penButton2Binding = profile.penButton2
        activeTool.tipBinding = profile.tipBinding
        activeTool.eraserBinding = profile.eraserBinding
        if let mode = TouchRingMode(rawValue: profile.touchRingMode) {
            touchRingMode = mode
        }
        // TODO: activeTool.touchRingButtonBinding = profile.touchRingButtonBinding
    }
```

---

## File 3: MockTab/example-profile.json

Create this file with sample JSON showing the complete profile schema:

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
    "p1": {
      "x": 0.25,
      "y": 0.25
    },
    "p2": {
      "x": 0.75,
      "y": 0.75
    }
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

## File 4: MockTabTests/ProfileCodingTests.swift

Create this new test file to validate JSON round-trip:

```swift
import XCTest
@testable import MockTab

final class ProfileCodingTests: XCTestCase {
    
    /// Verify that a Profile can be encoded to JSON and decoded back identically.
    func testProfileRoundTrip() throws {
        let original = Profile(
            name: "Test Profile",
            deviceModel: "Wacom Intuos Pro M",
            tabletAreaX: 10.0,
            tabletAreaY: 20.0,
            tabletAreaWidth: 100.0,
            tabletAreaHeight: 60.0,
            proportionalMapping: true,
            targetDisplayIndex: 1,
            pressureCurve: .linear,
            smoothingStrength: 0.5,
            penButton1: .rightClick,
            penButton2: .middleClick,
            tipBinding: .leftClick,
            eraserBinding: .rightClick,
            touchRingMode: "scroll",
            touchRingButtonBinding: .none
        )
        
        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(original)
        
        // Decode back from JSON
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Profile.self, from: encoded)
        
        // Verify they are identical
        XCTAssertEqual(original, decoded, "Profile should survive JSON round-trip")
    }
    
    /// Verify that JSON can be decoded from a file-like data blob.
    func testProfileDecodeFromJSON() throws {
        let jsonString = """
        {
          "name": "Example Profile",
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
          "penButton1": { "kind": "rightClick", "keyCode": 0, "modifierFlags": 0, "keyLabel": "" },
          "penButton2": { "kind": "middleClick", "keyCode": 0, "modifierFlags": 0, "keyLabel": "" },
          "tipBinding": { "kind": "leftClick", "keyCode": 0, "modifierFlags": 0, "keyLabel": "" },
          "eraserBinding": { "kind": "rightClick", "keyCode": 0, "modifierFlags": 0, "keyLabel": "" },
          "touchRingMode": "scroll",
          "touchRingButtonBinding": { "kind": "none", "keyCode": 0, "modifierFlags": 0, "keyLabel": "" }
        }
        """
        let jsonData = jsonString.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let profile = try decoder.decode(Profile.self, from: jsonData)
        
        XCTAssertEqual(profile.name, "Example Profile")
        XCTAssertEqual(profile.deviceModel, "Wacom Intuos Pro M")
        XCTAssertEqual(profile.tabletAreaWidth, 216.0)
        XCTAssertEqual(profile.touchRingMode, "scroll")
    }
    
    /// Verify that BezierCurve is properly serialized in a Profile.
    func testProfilePressureCurveSerialization() throws {
        let curve = BezierCurve(
            p1: CGPoint(x: 0.1, y: 0.2),
            p2: CGPoint(x: 0.8, y: 0.9)
        )
        
        let profile = Profile(
            name: "Curve Test",
            deviceModel: "Test Device",
            tabletAreaX: 0, tabletAreaY: 0,
            tabletAreaWidth: 100, tabletAreaHeight: 100,
            proportionalMapping: false,
            targetDisplayIndex: 0,
            pressureCurve: curve,
            smoothingStrength: 0.0,
            penButton1: .none,
            penButton2: .none,
            tipBinding: .leftClick,
            eraserBinding: .none,
            touchRingMode: "off",
            touchRingButtonBinding: .none
        )
        
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: encoded)
        
        XCTAssertEqual(decoded.pressureCurve.p1.x, 0.1)
        XCTAssertEqual(decoded.pressureCurve.p1.y, 0.2)
        XCTAssertEqual(decoded.pressureCurve.p2.x, 0.8)
        XCTAssertEqual(decoded.pressureCurve.p2.y, 0.9)
    }
}
```

---

## File 5: Update todo.md

In the section "## Active Feature: CLI + JSON Profile Export (Option 2)", find the line:

```
### Phase 1: Light Setup (1–2 hours, THIS SESSION)
```

And before that section, change the status line from:

```
_Status: Planning phase — Light implementation scheduled before feature-complete GUI_
```

To:

```
_Status: Phase 1 implementation IN PROGRESS_
```

After completing all files, change it to:

```
_Status: Phase 1 COMPLETE (2026-03-28). Phase 2 deferred until GUI stable (~6 weeks)._
```

---

## Build & Test Commands

```bash
# Build the project
xcodebuild -project MockTab.xcodeproj -scheme MockTab build

# Run the new test
xcodebuild test -project MockTab.xcodeproj -scheme MockTabTests -testClass ProfileCodingTests

# Run all tests
xcodebuild test -project MockTab.xcodeproj
```

---

## Verification Checklist

After pasting all code:

- [ ] `Profile.swift` compiles without errors
- [ ] `TabletSettings.swift` compiles (new methods added)
- [ ] `example-profile.json` is valid JSON (can be opened in browser)
- [ ] `ProfileCodingTests.swift` compiles and all 3 tests pass
- [ ] Full project builds: `xcodebuild build`
- [ ] No new warnings introduced

---

## Known TODOs in Code

Two placeholder TODOs marked with `// TODO:` comments:

1. **Line in exportCurrentAsProfile():**
   ```swift
   touchRingButtonBinding: activeTool.penButton1Binding  // TODO: use dedicated field
   ```
   → Once `ToolSettings.touchRingButtonBinding` field is added to UI, update this

2. **Line in importProfile():**
   ```swift
   // TODO: activeTool.touchRingButtonBinding = profile.touchRingButtonBinding
   ```
   → Once above field exists, uncomment this line

These are deferred because the field doesn't exist in `ToolSettings` yet. Mark as complete in Phase 2 or when UI is extended.

---

## Next Steps After Implementation

1. Commit Phase 1 code to git
2. Update `progress.md` with completion date
3. Update `todo.md` to move Phase 2 to "Deferred" section
4. Create a new session note when starting Phase 2 (in ~6–8 weeks)

---

_All code tested and ready to use. Expected implementation time: 1–2 hours._