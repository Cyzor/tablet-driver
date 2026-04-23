# AppleEvents Scripting Feasibility — MockTab

**Date:** 2026-04-18
**Status:** ✅ Feasible — Performance Impact Negligible
**Scope:** Read-only AppleEvent access to live tablet state

---

## Executive Summary

Adding read-only AppleEvents scripting support to MockTab is feasible with **negligible runtime cost**. The app's existing architecture — `@MainActor`-isolated state, pull-based `livePoint`/`liveButtonState` snapshots, and IOKit/HID callbacks on the main runloop — is well-aligned with how AppleEvent handlers receive and reply to events.

| Resource | Impact | Notes |
|----------|--------|-------|
| **CPU** | < 1% under heavy polling | ~0.02–0.08 ms per handler call; zero cost when idle |
| **Memory** | < 1 KB per device | Struct snapshots only; no persistent buffers |
| **Input latency** | None | Read-only; no lock contention with CGEvent tap path |
| **Usability** | None | Pure pull model; no side effects on tablet input |

---

## What Scripts Could Read

The following state is already maintained per-device and could be exposed trivially:

- **`TabletPoint`** (tablet coordinates): x, y, pressure, normalizedPressure, tiltX, tiltY, rotation, hoverDistance, inProximity
- **`LiveButtonState`**: tipDown, eraserDown, button1–5Down, expressKeys[16], touchRingActive, touchStrip states
- **Device metadata**: productID, deviceName, transport (USB/Bluetooth), batteryPercent, activeToolID, activeToolCode

These are already maintained as `@Published` properties on `TabletManager` and `DeviceContext`, and are updated via a two-gate throttling system that suppresses all UI overhead when the Info/Buttons tab is not visible.

---

## Existing Performance Architecture

MockTab already implements aggressive UI throttling to avoid SwiftUI overhead during drawing:

```
133 Hz tablet reports
  → infoViewVisible = false (default when not on Info/Buttons tab)
      → livePoint/liveButtons NEVER written → 0 @Published overhead
  → infoViewVisible = true
      → uiUpdateCounter steps by 1 per report, only assigns at counter == 0
      → ~16 Hz effective update rate to SwiftUI (every 8th report)
```

The input path (`InputInjector.inject()`) is entirely separate from `@Published` state and posts directly to the CGEvent tap with zero SwiftUI involvement.

---

## AppleEvent Handler Cost Analysis

A read-only AppleEvent handler performs:

1. **Dispatch**: macOS routes the `aeEvent` to the registered handler (~0.01–0.05 ms)
2. **Snapshot copy**: Copy the latest `TabletPoint`/`LiveButtonState` struct (~0.001 ms)
3. **Reply descriptor**: Pack results into an `AEDesc` (~0.01–0.03 ms)

**Total per call:** ~0.02–0.08 ms

At 60 queries/second (every 16ms, a reasonable polling rate), total handler CPU is ~5 ms/s — essentially unmeasurable.

---

## Why Read-Only Is Safe

- **No input path contention**: AppleEvent handlers run on the main runloop alongside IOHID callbacks. Since handlers only *read* a snapshot and never mutate shared state that the input path uses, there is no locking or race risk.
- **Copy-on-read isolation**: The handler reads from the latest `livePoint`/`liveButtons` snapshot, which is a plain struct (`Sendable`). No mutation occurs.
- **No timing impact**: CGEvent posting is unaffected. The tap path has no dependency on any state an AppleEvent handler could read.
- **No background threads**: No polling timers, no background work queue. Idle cost is exactly zero.

---

## Implementation Sketch

### Components needed

1. **sdef file** — `MockTab.sdef` defining terminology (4-char codes for properties)
2. **`NSAppleEventManager` handler** — registered at app startup in `AppDelegate`
3. **Handler dispatch table** — maps 4-char codes to property readers
4. **Snapshot accessor** — reads current state from `TabletManager.shared`

### Example terminology (sdef excerpt)

```
type TabletState = record
    x: integer
    y: integer
    pressure: double
    normalizedPressure: double
    tiltX: double
    tiltY: double
    rotation: double
    inProximity: boolean
    tipDown: boolean
    button1Down: boolean
    button2Down: boolean
end record

 MockTab application
     property currentPosition: TabletState
     property buttonState: record
     property activeDeviceName: text
     property batteryPercent: integer or null
```

### Read path (no locking needed)

```swift
func handleGetProperty(_ event: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    // Read from TabletManager.shared.livePoint (plain struct copy)
    // Pack into reply AEDesc
    // Return
}
```

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Handler blocks main runloop | Very Low | Read-only; instant struct copy |
| Polling script hammers CPU | Low | Script's choice; our cost per call is fixed tiny |
| Memory fragmentation from frequent AEDesc | Low | Avoid allocating per-call; reuse reply descriptor |
| Conflicts with SwiftUI @Published | None | Separate paths; read-only, copy-on-read |

---

## Relationship to CLI Work

The CLI planning (Phase 2, deferred) includes `mocktab-cli status` and `mocktab-cli watch` commands. AppleEvents scripting complements but does not overlap with CLI — CLI is for terminal-based automation, AppleEvents is for Script Editor/Automator/AppleScript-based workflow. Both could coexist.

CLI JSON export/import (Phase 1) is lower-priority than AppleEvents read support for the use case described (reading live values from external scripts).

---

## Deferred Until

- GUI stabilization (per CLI Phase 2 deferral reasoning)
- No concrete user demand yet (no scripts filed as issue/request)
- Could be implemented in 3–5 hours given clean existing state

---

## References

- `MockTab/Driver/TabletManager.swift` — `livePoint`, `liveButtons`, UI throttle architecture
- `MockTab/Driver/DeviceContext.swift` — per-device state isolation
- `MockTab/Driver/TabletPoint.swift` — `TabletPoint` and `LiveButtonState` struct definitions
- `MockTab/Driver/InputInjector.swift` — CGEvent tap path (independent of @Published)
- `Notes/CLI-Feasibility.md` — Phase 2 deferral context