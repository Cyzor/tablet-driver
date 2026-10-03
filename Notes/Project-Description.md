# Developer Notes

A few things about MockTab that the code doesn't make obvious: one easy-to-miss setup rule, how settings are stored, the hidden tuning settings, and how the app is built.

For the rest, start here:

- `Architecture.md` explains the two threads, follows a pen report from tablet to app, and shows where things live.
- `Notes/macOS-Tablet-Event-Synthesis.md` lists the event fields apps need to see pressure, tilt, and the pen's identity.
- The `Notes/Wacom-*-Protocol.md` pages and `Notes/Xencelabs-Protocol.md` describe each tablet's reports.

## Uninstall Wacom's Driver First

MockTab and Wacom's driver can't share a tablet. While Wacom's system extension is installed, macOS refuses MockTab's request to open the tablet, with the error `kIOReturnExclusiveAccess`.

## Listen in Every Run-Loop Mode

MockTab receives tablet reports through callbacks on a run loop. Schedule them in the common modes, never the default mode alone. This applies to `IOHIDManagerScheduleWithRunLoop` and to every `IOHIDDeviceScheduleWithRunLoop` call.

The reason: while you drag something, AppKit switches to a tracking mode, and default-mode callbacks stop. The report that says the pen lifted never arrives, so the mouse button stays down.

## Settings Storage

`TabletSettings` reads and writes `UserDefaults.standard` itself, rather than through `@AppStorage`.

A setting can be stored at several levels, and the most specific one wins:

1. For one app on one tablet, while that app is in front
2. For a saved profile
3. For one pen, by its serial number
4. For one tablet, under keys like `device-0x0357.smoothingStrength`
5. For every tablet, under the plain key

The diagram at the top of `TabletSettings.swift` shows the key for each level.

Each setting saves itself whenever it changes. While `reloadAll()` loads settings, it sets `isLoading`, so those loads aren't written straight back.

### Hidden Settings

A few settings have no control in the app. Set them in Terminal:

```
defaults write com.cyzor.mocktab touchOnsetDelayMs 20
```

This sets the plain key, so a value saved for a particular tablet, profile, or app still takes priority.

| Setting | Type | Default | What it does |
|---------|------|---------|--------------|
| `touchOnsetDelayMs` | Number, 0–500 | `40` | How long, in milliseconds, a finger rests before the cursor responds. Lower it for a quicker start. Raise it if a resting palm nudges the cursor. Even `0` waits about two reports. |
| `touchTapStabilizationPt` | Number, 0–4 | `1.5` | How far, in points, a finger can drift before the cursor follows. It soaks up the wobble when you lift from a tap and the first bit of a slow drag, without a jump when tracking starts. Above about 2 it feels sticky. `0` turns it off. Relative touch mode only. |
| `dropPhysicalModifiersFromMoveEvents` | Yes/No | `NO` | Leaves held keys (⇧ ⌘ ⌥ ⌃) off every pen movement, not just when MockTab's record of the keyboard may be out of date. A last resort if held keys stop registering. It costs Shift-to-constrain in Illustrator, Keynote, and Pages. Applies to all tablets. Relaunch after changing it. |
| `useRotationAsTilt` | Yes/No | `NO` | An old Photoshop workaround that sends an Art Pen's barrel rotation as tilt, in place of real tilt. Photoshop now reads rotation directly, so this should no longer be needed. Plain key only. Relaunch after changing it. |
| `rotationTiltOffsetDegrees` | Number | `0` | With `useRotationAsTilt`, degrees added to the rotation first. |
| `rotationTiltMagnitude` | Number, 0.1–1 | `0.8` | With `useRotationAsTilt`, how strong the resulting tilt is. |

To add a hidden setting:

1. Add a `@Published` property to `TabletSettings` that saves itself in `didSet`.
2. Load it in `reloadAll()` between `isLoading = true` and `isLoading = false`, and clamp it with `Swift.min` and `Swift.max`. If it loads outside that window, the first launch after a `defaults write` saves a copy for the current tablet, and that copy hides the plain key from then on.
3. If the pen thread reads it, add it to `InjectionSnapshot` and fill it in `makeInjectionSnapshot()`. Convert units there, such as milliseconds to seconds.
4. Add a row to the table above and mention it in the release notes. Nobody will find it otherwise.

## Pressure Curve

The pressure curve is a cubic Bézier (`BezierCurve`), inverted by bisection to find the output for each pressure.

When clamping values, write `Swift.min(Swift.max(…))`. Don't add a `clamped(to:)` extension: the name collides with one elsewhere in the package.

## Build Settings

- Bundle ID `com.cyzor.mocktab`, for macOS 13 and later, on Apple silicon and Intel
- Signed with Developer ID (team `3R62GZR6Q2`) and the hardened runtime
- Runs from the menu bar without a Dock icon (`LSUIElement`)
- Not sandboxed, because reading tablets and posting events both need access a sandbox doesn't allow
- Asks for Input Monitoring, to read the tablet, and Accessibility, to post events
- Build with `xcodebuild -scheme MockTab`, not `-target`
