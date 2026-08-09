[about]

## Drawing Tablets

A drawing tablet is an input device with a stylus that reports absolute position, pressure, tilt, and rotation.

## MockTab

MockTab is a macOS driver for Wacom and Xencelabs drawing tablets. It targets USB and Bluetooth tablets from the Wacom Intuos, Cintiq, Bamboo, and Intuos Pro families — focusing on hardware that Wacom's own driver no longer supports on modern macOS releases — as well as Xencelabs pen tablets and pen displays.

[tabletArea]

## Active Area

The active area is the portion of the tablet surface that maps to the screen. Pen input outside this rectangle has no effect.

**Resizing** – Drag any handle in the preview to reposition or resize the active area. Hold **Shift** while dragging a corner to lock the aspect ratio to the display's proportions. Exact values can also go into the Width and Height fields.

**Proportional mapping** – Keeps the tablet-to-screen ratio proportional so the cursor travels equal distances horizontally and vertically. Disable this option to deliberately stretch or compress the mapping.

**Reset to Full Area** – Restores the active area to the entire tablet surface. This action supports undo (⌘Z).

## Calibration (Pen Displays)

The **Calibrate…** button opens a full-screen overlay where crosshair targets appear for tapping with the pen tip. This process corrects the parallax gap between the pen tip and the on-screen cursor that the display glass introduces.

After calibration, **Pointer Offset** adjusts any small constant offset that remains, for example when parallax shifts slightly at different viewing angles.

[penFeel]

## Pressure Curve

The pressure curve controls how pen pressure maps to output pressure. A concave curve (pulled up) makes light strokes register heavier; a convex curve (pushed down) requires more force for the same effect.

**Presets** – Linear, Soft, and Firm. Choosing a preset sets the curve; adjusting a curve point switches to a custom shape automatically.

## Pressure Smoothing

Dampens pressure noise near the low end of the sensor's range, which otherwise shows up as uneven line width on slow, light strokes. Firm pressure is left alone.

## Stabilization

Reduces cursor wobble from hand tremor. Higher values smooth more aggressively but may add input lag.

## Double-Click Distance

This setting controls how close two taps must be to count as a double-click. Increase the value if double-clicks fail to register; decrease it if accidental double-clicks occur during normal drawing. Drag to Off to disable position snapping.

## Movement

**Invert Rotation Direction** – reverses the pen's twist direction. Enable per-app for apps that interpret rotation backwards (e.g. Krita).

**Art Pen: Swap Tilt with Rotation** – feeds barrel rotation into Photoshop's Pen Tilt control by sending fake tilt data, at the cost of suppressing real tilt while it's on. Use in Brush Dynamics → Shape Dynamics → Angle → Pen Tilt. When enabled, Tilt Offset and Tilt Magnitude sliders appear to fine-tune the fake tilt signal.

**Relative Cursor Movement** – switches from absolute mode (each point on the tablet maps to a fixed point on screen, like a stylus) to relative mode (the cursor moves by the distance you move the pen, like a mouse).

## Pan View

Sets how fast content pans while a Pan View button is held. Assign the Pan View action to any pen barrel, express key, or puck button in Button Mapping to use it.

## Click Behavior

**Tip-up Assist** – holds the pen click open briefly after the tip lifts, if you're still moving quickly, to prevent unintended stroke breaks during fast drawing. Drag to Off to disable.

**Drag Threshold** – requires the pen to move a minimum distance before a tap becomes a drag, absorbing tremor at tip-down so light taps don't turn into accidental drags. Drag to Off to disable.

[buttons]

## Pen Diagram

Press any button while the window is open to highlight its position; this helps identify which physical button maps to which assignment slot. Clicking a part of the diagram — the tip, the eraser, or a barrel button — starts recording a new assignment for it.

**Hover drag** – Hold Button 1 (the lower barrel button) while the pen hovers above the surface to move the cursor without tip contact and perform drag gestures in mid-air.

## Assignment Types

- **Mouse buttons** – Left, Right, Middle click, or Double-click  
- **Keyboard shortcuts** – click the shortcut field and press any key combination  
- **Modifier holds** – ⌘ ⌥ ⇧ ⌃ held for as long as the button remains pressed  
- **Special actions** – Toggle Display, Eraser, Touch Ring mode selection  

## Touch Ring and Dial

Rings, dials, and touch strips support multiple mode slots. Each mode appears as a one-line summary; click a mode row — or its wedge in the diagram beside the list — to open its settings in place: the action, its speed, and the shortcuts for each direction. Assign Touch Ring Mode → **Cycle** to a button to step through modes, or **Jump to Mode** to jump directly to a specific mode.

## Lighting

Some devices have configurable lights. On hardware with a lit dial ring, each mode's settings include the color and brightness shown while that mode is active. Pen displays with backlit bezel buttons have a **Button Backlight** row. The hardware keeps its last color until you change it.

## Eraser

The eraser tip has its own binding, configured in the pen section. Some drawing apps switch to their eraser tool automatically when they receive eraser proximity events.

## Per-App Overrides

The app override bar at the top assigns different buttons for a specific application. Overrides activate automatically when that app moves to the foreground. Global settings apply in all other cases.

[touch]

## Touch

Tablets with a capacitive touch surface report finger contacts alongside pen input. MockTab keeps this disabled by default. Enable **Enable finger touch** to use it.  Response varies by app.

**Tap to click** – A brief touch with no significant motion produces a left click.

**Cursor speed** – Scales pointer movement from a single-finger drag. Lower values allow fine control, while higher values cover more distance with less motion.

## Gestures

**Two-finger scroll** – Swipe two fingers in one direction. Apps generally treat these as trackpad scrolling.

**Pinch to zoom** – Spread or pinch two fingers to zoom.

**Rotate** – Place two fingers on the tablet and twist either clockwise or counter-clockwise to rotate the view.

**Reverse direction** – On: content moves opposite to finger motion, like a conventional mouse wheel.

**Momentum Scrolling** – Two-finger scroll coasts briefly after you lift your fingers, the same as trackpad inertia. Turn off for apps that don't handle the effect well.

## Touch Area

The touch area operates independently from the pen’s active area. Drag the handles in the preview to crop the available touch surface. Finger input outside the rectangle has no effect.

**Reset to Full Surface** – Restores the touch area to the entire touch-capable region.

## Limitations

MockTab doesn't currently support Mission Control, Spaces, Launchpad, or App Exposé from touch.

[display]

## Display Mapping

Display mapping determines which screen the tablet treats as active.

**All Displays** – Shift-click any display in the diagram to span the entire desktop proportionally. Suits workflows that move across multiple monitors.

**Single Display** – Click a display in the diagram to map the active area to just that display.

**Toggle Display** – Assign the Toggle Display action to an express key or barrel button to cycle through connected displays without opening settings.

[devices]

## Connected Devices

The Devices pane lists every tablet and pen tool that MockTab has detected. Each row shows the device name, connection type (USB or Bluetooth), and current status.

Selecting a device row reveals model-specific settings and tools in the details pane on the right.

Disconnected devices remain in the list so their profiles remain available for inspection or adjustment even while unplugged. When a listed device reconnects, MockTab applies its saved settings automatically.

## Conflict Detection

If another tablet driver (such as the official Wacom driver) runs at the same time, MockTab attempts to detect the conflict and show a warning.

[profiles]

## Profiles

A profile is a snapshot of tablet settings: active area, pressure curve, button assignments, and display mapping. Switching profiles applies all of these settings immediately.

**Auto-Switch** – Automatically switches to the matching profile when its tablet connects.

## Creating and Renaming

Click **Create Profile** to capture the current settings. Double-click a profile name to rename it.

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

**Collect Device Data** records what the tablet sends while you use it. The result is a compact JSON file you can attach to a request to add or improve support for a device.

[website]

## mocktab.org

The MockTab website at [mocktab.org](https://mocktab.org) provides documentation, release notes, and the full list of supported hardware.

## GitHub

Bug reports and questions go to [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues).

## Acknowledgments

MockTab's device data and protocol research draw on the work of two open-source projects: [OpenTabletDriver](https://opentabletdriver.net/), whose device configurations cover tablet models across many vendors, and [the Linux Wacom Project](https://linuxwacom.github.io/), the authoritative source for Wacom device dimensions via its libwacom library.
