# Checking the oldest supported macOS

MockTab supports macOS 13 and later, but CI only runs on newer systems. Before a release, open the build in a macOS 13 virtual machine and go through this list. It takes about ten minutes. Repeat on macOS 14 when a change touches its version checks.

A virtual machine can't use a tablet, so this covers everything except tablet input.

## Setup, once

1. Install Tart: `brew install openai/tools/tart`
2. Download the VM, about 25 GB: `tools/release/floor-check.sh --setup 13`

## Each release

1. Run `tools/release/floor-check.sh 13`, or pass the path to a different exported `MockTab.app`.
2. Log in as `admin`, password `admin`.
3. Copy `MockTab.app` from `/Volumes/My Shared Files/mocktab` to Applications, then open it there.

## Checklist

**Launch**
- The app opens without a crash report or a Gatekeeper warning beyond the usual first-launch prompt.
- The menu bar icon appears, and its menu opens.

**Permissions**
- The Accessibility and Input Monitoring prompts appear when expected, and their buttons open the right System Settings pane.

**Settings window**
- Every tab that appears opens with no blank areas, clipped text, or overlapping controls.
- Resizing the window and switching tabs keeps each tab's layout.
- On macOS 13, the tablet-area and pressure-curve editors still work with the mouse. Arrow-key nudging is a macOS 14 feature there, and the system focus ring may show.

**Help and diagnostics**
- Help opens the help book, and its pages load.
- **Help › Collect Device Data…** opens and reports that no tablet is connected, without hanging.

**Intel**
- Quit MockTab. In Finder, choose **Get Info** on `MockTab.app`, select **Open using Rosetta**, and open it again. Repeat the Launch and Settings window checks. If Rosetta isn't installed, the system offers to install it.
- This works until macOS 28 removes Rosetta. After that, Intel builds can only be checked on an Intel Mac.

## Recording results

File anything that differs from the current macOS as an issue. Note the macOS version, and whether it happened under Rosetta.
