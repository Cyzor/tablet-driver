# Contributing to MockTab

MockTab is a macOS driver for older Wacom drawing tablets. It ships
under GPL-3.0-or-later.

## Getting the code running

```sh
git clone --recurse-submodules https://github.com/Cyzor/tablet-driver.git
cd tablet-driver
open MockTab.xcodeproj
```

Requires Xcode 15 or later. Select the **MockTab** scheme and build. Run the
decoder test suite with `cd TabletKit && swift test`. App-side logic that has no
XCTest target has standalone checks under `tools/` — run
`tools/calibration-tests/run.sh` (calibration fitting math),
`tools/descriptor-opacity-tests/run.sh` (HID descriptor readability),
`tools/discovery-accumulator-tests/run.sh` (device-data collection analysis), and
`tools/touch-state-tracker-tests/run.sh` (touch gesture intent).
See the [README's Building from source section](README.md#building-from-source)
for more detail.

## Reading the code

[`Architecture.md`](Architecture.md) has a pipeline diagram, the threading
rules, and a "Where to start" table mapping common goals to files — read that
before diving into `MockTab/` or `TabletKit/`. Adding a new tablet model is
its own guide: [`TabletKit/Extending-Support.md`](TabletKit/Extending-Support.md).

## What's welcome first

These are the easiest PRs to review and merge, roughly in order of how much
context they need:

- **Device fixture tests and registry rows** — the decoder test suite in
  `TabletKit/Tests/` is fixture-based; adding a captured report as a new
  fixture is low-risk and highly valued.
- **Translation corrections** for the German, Japanese, or Spanish locales.
- **Documentation fixes** — typos, stale info, unclear steps.
- **Device-support requests** for unrecognized tablets — see below.
- **Bug reports** for specific, reproducible problems on supported hardware.
- **Decoder work** belongs on [TabletKit](https://github.com/Cyzor/TabletKit)
  — see its [`Contributing.md`](https://github.com/Cyzor/TabletKit/blob/main/Contributing.md)
  for the capture and submission process.

## How to file a bug report

1. Reproduce the issue and note the steps.
2. In MockTab, open the Info pane and press **Copy Diagnostics** to bundle your driver state into a text block.
3. Open an issue using the [bug report template](.github/ISSUE_TEMPLATE/bug-report.yml). Include: macOS version, tablet model, steps to reproduce, and the diagnostics output.

## How to request device support

1. In MockTab, open the Info pane and press **Collect Device Data…**. Use the tablet as prompted. This produces a JSON file with the device's HID descriptor, USB strings, and a summary of what it sent.
2. Open an issue using the [Device support template](.github/ISSUE_TEMPLATE/device-support.yml) and attach the JSON file.

## Translations

- **Corrections** to an existing locale: open a pull request against the relevant `.strings` files.
- **New locales**: open an issue first to confirm the locale is feasible before starting work.

## Pull Request Characteristics

- One sentence on what the PR does.
- macOS version and hardware tested on.
- Steps to verify the change.

**Feature requests as standalone issues aren't tracked** — issues here are for
confirmed work (bugs, device support, translations), so an untracked feature
request tends to sit unanswered. If you want a feature, the fastest path is
proposing it alongside a willingness to help build it.

## Forking

MockTab is GPL-3.0-or-later. Fork, modify, and redistribute under the same terms.

To build something without GPL obligations, consider using [TabletKit](https://github.com/Cyzor/TabletKit) directly.  The decoder layer ships as a separate MPL-2.0 Swift package, usable from any macOS app without GPL contamination.