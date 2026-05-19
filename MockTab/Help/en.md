[about]

## Drawing Tablets

A drawing tablet is an input device with a stylus that reports absolute position, pressure, tilt, and rotation.

## MockTab

MockTab is a native macOS driver for Wacom drawing tablets. It targets USB and Bluetooth tablets from the Intuos, Cintiq, Bamboo, and Intuos Pro families, focusing on hardware that Wacom's own driver no longer supports on modern macOS releases.

[tabletArea]

## Active Area

The active area is the portion of the tablet surface that maps to the screen. Pen input outside this rectangle has no effect.

**Resizing** – Drag any handle in the preview to reposition or resize the active area. Hold **Shift** while dragging a corner to lock the aspect ratio to the display's proportions. Exact values can also go into the Width and Height fields.

**Lock Aspect Ratio** – Keeps the tablet-to-screen ratio proportional so the cursor travels equal distances horizontally and vertically. Disable this option to deliberately stretch or compress the mapping.

**Reset to Full** – Restores the active area to the entire tablet surface. This action supports undo (⌘Z).

## Calibration (Pen Displays)

The **Calibrate** button opens a full-screen overlay where crosshair targets appear for tapping with the pen tip. This process corrects the parallax gap between the pen tip and the on-screen cursor that the display glass introduces.

After calibration, **Manual Fine-Tune** adjusts any small constant offset that remains, for example when parallax shifts slightly at different viewing angles.

[penFeel]

## Pressure Curve

The pressure curve controls how pen pressure maps to output pressure. A concave curve (pulled up) makes light strokes register heavier; a convex curve (pushed down) requires more force for the same effect.

**Tip Feel presets** – Linear, Soft, and Firm. Choosing a preset sets the curve; adjusting a curve point switches to a custom shape automatically.

## Smoothing

Smoothing reduces high-frequency jitter in the input signal.

## Double-Click Distance

This setting controls how close two taps must be to count as a double-click. Increase the value if double-clicks fail to register; decrease it if accidental double-clicks occur during normal drawing.

[buttons]

## Pen Diagram

Press any button while the window is open to highlight its position; this helps identify which physical button maps to which assignment slot.

**Hover drag** – Hold Button 1 (the lower barrel button) while the pen hovers above the surface to move the cursor without tip contact and perform drag gestures in mid-air.

## Assignment Types

- **Mouse buttons** – Left, Right, Middle click, or Double-click  
- **Keyboard shortcuts** – click the shortcut field and press any key combination  
- **Modifier holds** – ⌘ ⌥ ⇧ ⌃ held for as long as the button remains pressed  
- **Special actions** – Display Toggle, Eraser, Touch Ring mode selection  

## Touch Ring

The ring supports multiple mode slots.  Assign **Ring Cycle** to a button to step through modes, or **Ring: Slot N** to jump directly to a specific slot.

## Eraser

The eraser tip has its own binding, configured in the pen section. Some drawing apps switch to their eraser tool automatically when they receive eraser proximity events.

## Per-App Overrides

The app override bar at the top assigns different buttons for a specific application. Overrides activate automatically when that app moves to the foreground. Global settings apply in all other cases.

[display]

## Display Mapping

Display mapping determines which screen the tablet treats as active.

**All Displays** – The tablet spans the entire desktop proportionally. This mode suits workflows that move across multiple monitors.

**Single Display** – The active area maps to one specific display. Selecting a display from the list updates the preview to show the mapping.

**Display Toggle** – Assign the Display Toggle action to an express key or barrel button to cycle through connected displays without opening settings.

[devices]

## Connected Devices

The Devices pane lists every tablet and pen tool that MockTab has detected. Each row shows the device name, connection type (USB or Bluetooth), and current status.

Selecting a device row reveals model-specific settings and tools in the details pane on the right.

Disconnected devices remain in the list so their profiles remain available for inspection or adjustment even while unplugged. When a listed device reconnects, MockTab applies its saved settings automatically.

[tools]

## Conflict Detection

If another tablet driver (such as the official Wacom driver) runs at the same time, MockTab attempts to detect the conflict and show a warning.

[profiles]

## Profiles

A profile is a snapshot of tablet settings: active area, pressure curve, button assignments, and display mapping. Switching profiles applies all of these settings immediately.

**Auto-restore** – When enabled on a profile, MockTab automatically activates that profile when the associated tablet connects.

## Creating and Renaming

Click **Save as New Profile** to capture the current settings. Double-click a profile name to rename it.

## Per-App Overrides in Profiles

Profiles store their own per-app overrides. Switching profiles also switches to the overrides associated with the active profile.

## Import / Export

Drag a profile card to Finder to export it as a JSON file. Drag a JSON file onto the profile list to import it. Exported files work as backups and as a way to share profiles between machines.

[scratchpad]

## Scratchpad

The scratchpad is a pressure-sensitive test canvas. It provides a quick way to verify that the pen registers pressure, tilt, and motion correctly.

Stroke opacity and width both respond to tip pressure. Tilt affects the stroke angle when the pen supports tilt input. The pane does not retain strokes; closing or clearing the pane discards its contents.

**Clear** – Removes all strokes from the canvas.

[info]

## Live Input

The Info pane displays real-time values from the pen: X/Y position, pressure, tilt, rotation, hover distance, and button state. These values update continuously while the pen remains in range.

This view helps diagnose unexpected behavior, for example by confirming whether pressure reaches its maximum value or whether the tablet reports tilt.

## Collect Device Data

**Collect Device Data** runs a guided capture session that records the raw HID reports from the tablet. The result is a compact JSON file suitable for attaching to feature requests that aim to add or improve support for a device.

[website]

## mocktab.org

The MockTab website at [mocktab.org](https://mocktab.org) provides documentation, release notes, and the full list of supported hardware.

## GitHub

Bug reports and questions go to [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues).