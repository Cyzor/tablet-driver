[about]

## Drawing Tablets

A drawing tablet is an input device with a stylus that reports absolute position, pressure, tilt, and rotation.

## MockTab

MockTab is a macOS driver for Wacom and Xencelabs drawing tablets. It targets USB and Bluetooth tablets from the Wacom Intuos, Intuos Pro, Cintiq, Bamboo, and Graphire families, as well as some Xencelabs models. It focuses on hardware that Wacom's own driver no longer supports on modern macOS releases.

## Removing MockTab

Quit MockTab and move it to the Trash. To remove its settings as well, open each item below in the Finder with **Go to Folder** (⇧⌘G) and move it to the Trash:

- `~/Library/Preferences/com.cyzor.mocktab.plist` – settings  
- `~/Library/Application Support/com.cyzor.mocktab` – earlier settings, saved each time a different version starts  

[tabletArea]

## Active Area

The active area is the portion of the tablet surface that maps to the screen. Pen input outside this rectangle has no effect.

**Resizing** – Drag the area or its handles; it snaps to the screen area's shape when close (hold **⌘** to skip, **⇧** to keep its shape, **⌥** to resize from the center). Click the width or height below to type an exact size.

**Keyboard** – On macOS 14 and later, click the area and use the arrow keys to move it, or hold **⌥** to resize it. **⇧** takes bigger steps.

**Proportional mapping** – Keeps horizontal and vertical cursor travel equal. Turn it off to stretch or compress the mapping.

**Reset to Full Area** – Restores the full tablet surface. ⌘Z undoes it.

## Orientation

Choose the orientation that matches the tablet's current position (⌘⌥1 through ⌘⌥4 in the Tablet Area pane). Pen, touch, and tilt follow the choice, and the Buttons pane draws the tablet to match.

Turning the tablet moves each assignment to the key now in its place, in every profile and app override. Undo reverses both together.

**Turn Assignments Around** – Right-click the tablet drawing in the Buttons pane to swap each assignment to the opposite key without changing the orientation. Choose it again to restore them.

## Calibration (Pen Displays)

**Calibrate…** shows full-screen targets to tap with the pen tip. It corrects the gap the display glass puts between the pen tip and the cursor.

**Pointer Offset** fixes any small gap that remains, such as one that changes with viewing angle.

[penFeel]

## Pressure Curve

Pull the curve up to make light strokes heavier, or down to need more force. Linear, Soft, and Firm are presets.

On macOS 14 and later, click the curve and use the arrow keys to move the handle joined to the light end, or hold **⌥** to move the other one. **⇧** takes bigger steps.

## Pressure Smoothing

Evens out line width in slow, light strokes.

## Steadiness

Reduces cursor wobble from hand tremor, at the cost of some lag.

## Double-Click Distance

How close two taps must land to count as a double-click.

## Movement

**Invert Rotation Direction** – Change barrel rotation to produce clockwise or counter-clockwise motion.

**Relative Cursor Movement** – Moves the cursor like a mouse instead of mapping the tablet to the screen.

## Pan View

**Speed**, **Reverse Direction**, and **Momentum Scrolling** set how content moves while you hold a Pan View button. Assign Pan View in the Buttons pane.

## Click Behavior

**Require Contact** – Checked side-button actions wait for the tip to touch. Unchecked click actions also work while hovering, including drags.

**Tip-up Assist** – Keeps fast strokes from breaking when the tip briefly lifts.

**Drag Threshold** – Keeps a tap from turning into a small drag.

[buttons]

## Pen Diagram

Press any button while the window is open to highlight its position; this helps identify which physical button maps to which assignment slot. Click the tip, the eraser, or a barrel button in the diagram to record a new assignment for it.

## Mice

A Wacom mouse gets its own diagram and button rows. Its first three buttons start as Left, Right, and Middle Click.

## Tablet Diagram

The diagram depicts positions of a tablet's keys, rings, and dials. Click a component to assign an action.

## Assignment Types

- **Mouse buttons** – Left, Right, and Middle Click, Double Click, and Click Lock, which holds the left button down until the next press  
- **Keyboard shortcuts** – click the shortcut field and press any key combination  
- **Modifier holds** – ⌘ ⌥ ⇧ ⌃ held for as long as the button remains pressed  
- **Special actions** – Pan View, Eraser, Spacebar, Escape, F13 through F19, Toggle Display, Span Displays, Toggle Relative Mode, Show MockTab Settings, and ring, dial, and strip modes  
- **Open** – drag an app, file, link, or Keyboard Maestro macro onto a button's row. A question mark means its target is gone. To type or fix a URL, right-click the row and choose Edit URL  

To run a script, Automator workflow, or shortcut, save it as an app and drag that, or give it a keyboard shortcut in System Settings or Shortcuts and assign the shortcut.

## Touch Ring and Dial

Rings, dials, and touch strips each have their own modes. Click a mode, or its wedge in the diagram, to change its settings. To switch modes from a button, assign **Cycle** or **Jump to Mode**.

**Scroll** – Works like a scroll wheel. At 1×, each step scrolls one line.

**Zoom** and **Rotate** – Magnify or turn the canvas, the way a trackpad pinch or twist does. Speed runs from Off to Max; at Max, one turn of the ring turns the canvas all the way around. Support varies by app.

**Key** – Sends a keyboard shortcut for each direction.

## Key Displays

An Intuos4 with key displays shows each key's action beside it over USB, and the displays dim when idle.

## Lighting

Devices with a lit dial ring or backlit buttons let you set their color and brightness. The hardware keeps its last color until you change it.

## Eraser

The eraser end has its own assignment in the pen section. On a pen without one, set a side button to Eraser and hold it to erase with the tip.

## Per-App Overrides

The app override bar at the top assigns different buttons for a specific application. Overrides activate automatically when that app moves to the foreground. Global settings apply in all other cases.

**Reset** removes the current app's overrides. Hold **⌥** to change it to **Remove All**, which removes every app's overrides for this tablet.

[touch]

## Touch

Some tablets also sense your fingers. MockTab leaves touch off by default. Turn on **Enable Finger Touch** to use it. Response varies by app.

**Tap to Click** – A brief touch with no significant motion produces a left click.

**Two-Finger Right-Click** – A brief touch with two fingers, a fingertip's width apart, produces a right click.

**Three-Finger Drag** – Three fingers landing together hold the mouse button down. Move them to drag, and lift to let go.

**Cursor Speed** – Scales pointer movement from a single-finger drag. Lower values allow fine control, while higher values cover more distance with less motion.

## Gestures

**Two-Finger Scroll** – Swipe two fingers in one direction. Apps generally treat these as trackpad scrolling.

**Pinch to Zoom** – Spread or pinch two fingers to zoom.

**Rotate** – Place two fingers well apart on the tablet and swivel them about their center. Scroll, pinch, and rotate read the same two-finger gesture in different ways.

**Reverse Direction** – On: content moves opposite to finger motion, like a conventional mouse wheel.

**Momentum Scrolling** – Two-finger scroll coasts briefly after you lift your fingers, the same as trackpad inertia.

## Touch Area

The touch area operates independently from the pen’s active area. Drag the handles in the preview to crop the available touch surface. Finger input outside the rectangle has no effect. Modifier and arrow keys work as in the active area.

**Reset to Full Surface** – Restores the touch area to the entire touch-capable region.

## Limitations

MockTab doesn't support Mission Control, Spaces, Launchpad, or App Exposé from touch.

[display]

## Display Mapping

Display mapping determines which screen the tablet treats as active.

**Primary display** – Maps the tablet to your main display.

**A single display** – Choose a display by name to map the tablet to it alone.

**Toggle between displays** – A button press cycles the tablet between the displays you select. ⌘-click displays in the diagram to choose them, or Shift-click to select a range.

**Span selected displays** – Maps the tablet across the selected displays as one surface.

**All** – Maps the tablet across every display as one surface.

**Span Displays** – Press a button assigned to Span Displays to spread the pen across the displays selected under Active Displays, and press it again to return to your usual setting. With none selected, it spans every display.

## Screen Area

Like Active Area, but on the screen side: crops which part of the display the pen can reach.

**Select on Screen…** – Drag the region directly over your desktop, like the macOS screenshot tool.

**Use Whole Screen** – Restores the full display.

[devices]

## Connected Devices

The Devices pane lists every tablet and pen that MockTab has detected. Each row shows the device name, connection type (USB or Bluetooth), and current status.

Selecting a device row reveals model-specific settings and pens in the details pane on the right.

Disconnected devices remain in the list so their profiles remain available for inspection or adjustment even while unplugged. When a listed device reconnects, MockTab applies its saved settings automatically.

On an Intuos5 or Intuos Pro (2013) running on the Wacom wireless kit, the Info pane's **Battery** row sets how long the tablet sits unused before it sleeps.

## Conflict Detection

If another tablet driver (such as the official Wacom driver) runs at the same time, MockTab attempts to detect the conflict and show a warning.

[profiles]

## Profiles

A profile is a snapshot of tablet settings: active area, pressure curve, button assignments, and display mapping. Switching profiles applies all of these settings immediately.

## Creating and Renaming

Click **Create Profile** to capture the current settings. Double-click a profile name to rename it, or right-click a profile for more choices. Hold **⌥** while you open that menu to delete every profile for this tablet; **⌘Z** brings them back.

## Per-App Overrides in Profiles

Profiles store their own per-app overrides. Switching profiles also switches to the overrides associated with the active profile.

## Backup and Import

Drag the JSON tile to the Finder to save all settings, including serial numbers and app names. Drag a file onto the tile to import it and choose which tablets to bring in. The Profiles menu does the same. ⌥-click a tablet's checkbox to check or uncheck them all.

[scratchpad]

## Scratchpad

A test canvas for checking that the pen registers pressure and motion. MockTab doesn't save strokes.

[info]

## Live Input

The Info pane shows what the tablet reports. Gauges represent position, pressure, tilt, rotation, hover height, and touch activity.

## Collect Device Data

**Collect Device Data** records what the tablet sends while you use it. The result is a single zip file you can attach to a GitHub request or send by email, to add or improve support for a device.

## Updates

**Check Now** asks mocktab.org for a newer version, and **Check automatically** asks weekly. Nothing else goes online.

A badge on the menu bar and Dock icons means an update is available. **Install on Quit** installs it when MockTab quits, and **Install and Relaunch** installs it now.

Hold **⌥** to change **Check Now** to **Check for Pre-release**, which looks for a newer test version. Pre-releases may be incomplete. The **Check for Updates…** menu item changes the same way.

## Dock and Login

**Dock Icon** – Hides MockTab from the Dock. The menu bar icon stays.

**Launch at Login** – Opens MockTab when you log in.

**Grant…** opens System Settings for a missing permission.

[website]

## mocktab.org

The MockTab website at [mocktab.org](https://mocktab.org) provides documentation, release notes, and the full list of supported hardware.

## GitHub

Bug reports and questions go to [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver/issues).

## Acknowledgments

MockTab builds on open-source work. [OpenTabletDriver](https://opentabletdriver.net/) supplies configurations for tablets from many brands. [The Linux Wacom Project](https://linuxwacom.github.io/) supplies Wacom sizes and control layouts through libwacom, and documents Wacom's data formats through its input-wacom driver, which also ships in the Linux kernel, and its wacom-hid-descriptors collection.

## License

MockTab is free software under the [GNU General Public License, version 3 or later](https://www.gnu.org/licenses/gpl-3.0.html). Its source code is at [github.com/Cyzor/tablet-driver](https://github.com/Cyzor/tablet-driver). TabletKit, the library MockTab uses to read tablets, is under the [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/).

The tablet drawings use control layouts from libwacom:

Copyright © 2011 Red Hat, Inc.

Permission to use, copy, modify, distribute, and sell this software and its documentation for any purpose is hereby granted without fee, provided that the above copyright notice appear in all copies and that both that copyright notice and this permission notice appear in supporting documentation, and that the name of Red Hat not be used in advertising or publicity pertaining to distribution of the software without specific, written prior permission.  Red Hat makes no representations about the suitability of this software for any purpose.  It is provided "as is" without express or implied warranty.

THE AUTHORS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS, IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
