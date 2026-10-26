# Checking the oldest supported macOS

MockTab supports macOS 13 and later, but CI only runs on newer systems. Before a release, open the build in a macOS 13 virtual machine and go through this list. It takes about ten minutes. Repeat on macOS 14 when a change touches its version checks.

The Tart virtual machine below has no tablet, so its list covers everything except tablet input. [Tablet input](#tablet-input) covers the rest in a UTM guest.

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

## Tablet input

Swift's concurrency runtime ships with macOS, so a threading mistake that crashes only on an older system won't show on a newer Mac. UTM 5.0.8 can hand a USB device to a macOS guest, which lets MockTab in the guest drive a real tablet. A macOS 15 guest drives a PTH-850; 13 and 14 are untested.

1. In UTM, create a macOS guest on the version to check.
2. Copy a signed, exported `MockTab.app` into the guest through a shared folder, move it to Applications, and open it.
3. Plug in a USB tablet, then connect it to the guest in UTM. Bluetooth stays with the host, so use a cable or a wireless kit receiver.

Then check:
- The tablet appears in Devices with the right name.
- The pen hovers and draws with pressure, and both side buttons work. Keys, rings, or strips work if the tablet has them.
- In the Buttons pane, pressing a key lights it.
- Disconnect the tablet from the guest, then connect it again. MockTab picks it up again without a crash.
- Quit MockTab. The cursor behaves normally.
- **Help › Collect Device Data…** lists the tablet.

If a guest on 13 takes the tablet, the whole list above can run there instead of in Tart.

## Recording results

File anything that differs from the current macOS as an issue. Note the macOS version, and whether it happened under Rosetta.
