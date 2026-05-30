# Contributing to MockTab

MockTab is a native macOS driver for older Wacom drawing tablets.

MockTab ships under GPL-3.0-or-later.

## Contribution Process

- **Bug reports** for specific, reproducible problems on supported hardware.
- **Device-support requests** for unrecognized Wacom tablets. The *Collect Device Data…* button in the Info pane produces the JSON capture the device support template requires.
- **Translation corrections** for the German, Japanese, or Spanish locales.
- **Decoder work** belongs on [TabletKit](https://github.com/Cyzor/TabletKit) — see its [`CONTRIBUTING.md`](https://github.com/Cyzor/TabletKit/blob/main/CONTRIBUTING.md) for the capture and submission process.

## How to file a bug report

1. Reproduce the issue and note the steps.
2. In MockTab, open the Info pane and press **Copy Diagnostics** to bundle your driver state into a text block.
3. Open an issue using the bug report template. Include: macOS version, tablet model, steps to reproduce, and the diagnostics output.

## How to request device support

1. In MockTab, open the Info pane and press **Collect Device Data…**. This produces a JSON file with the device's HID descriptor, USB strings, and a short input report capture.
2. Open an issue using the [Device support template](.github/ISSUE_TEMPLATE/device-support.yml) and attach the JSON file.

## Translations

- **Corrections** to an existing locale: open a pull request against the relevant `.strings` files.
- **New locales**: open an issue first to confirm the locale is feasible before starting work.

## Pull Request Characteristics

- One sentence on what the PR does.
- macOS version and hardware tested on.
- Steps to verify the change.

Not in Scope:

- **Feature requests filed as Issues.** Issues track confirmed work; open an issue to propose a feature only if you're prepared to help build it.


## Forking

MockTab is GPL-3.0-or-later. Fork, modify, and redistribute under the same terms.

To build something without GPL obligations, consider using [TabletKit](https://github.com/Cyzor/TabletKit) directly.  The decoder layer ships as a separate MPL-2.0 Swift package, usable from any macOS app without GPL contamination.