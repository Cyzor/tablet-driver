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
XCTest target has standalone checks under `tools/tests/` — run all of them with
`tools/tests/run-all-tests.sh`, or run an individual harness directly by name
(e.g. `tools/tests/calibration-tests/run.sh`).
See the [README's Build from source section](README.md#build-from-source)
for more detail.

## Reading the code

[`Architecture.md`](Architecture.md) has a pipeline diagram, the threading
rules, and a "Where to start" table mapping common goals to files — read that
before diving into `MockTab/` or `TabletKit/`. Adding a new tablet model is
its own guide: [`TabletKit/Extending-Support.md`](TabletKit/Extending-Support.md).

## Where to start

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
2. In MockTab, open the Info pane and press **Copy Diagnostics** to bundle your driver state into a text block. If the bug looks tablet-specific (protocol quirks, wrong dimensions, a decoder issue), also press **Collect Device Data…** to produce a JSON file with the device's HID descriptor and a report capture. Attach both.
3. Open an issue using the [bug report template](.github/ISSUE_TEMPLATE/bug-report.yml). Include: macOS version, tablet model, steps to reproduce, and the diagnostics output.

## How to request device support

1. In MockTab, open the Info pane and press **Collect Device Data…**. Use the tablet as prompted. This produces a JSON file with the device's HID descriptor, USB strings, and a summary of what it sent.
2. Open an issue using the [Device support template](.github/ISSUE_TEMPLATE/device-support.yml) and attach the JSON file.

## Translations

All UI text lives in one file, [`MockTab/Localizable.xcstrings`](MockTab/Localizable.xcstrings): a
String Catalog, not `.strings` files. Source strings are literal English
text passed to `String(localized: "...", comment: "...")` in the Swift code, not
symbolic keys. Currently covers German, Japanese, and Spanish, at varying
completeness. Many entries have English and only one or two of the other
three languages filled in.

- **Corrections** to an existing locale: easiest done in Xcode — open
  `Localizable.xcstrings`, it opens as a table editor with one row per
  string and a column per language. Edit the target-language cell and save.
  You can also edit the JSON directly; each entry's `localizations` dict has
  one key per language code, each holding a `stringUnit.value` and a
  `stringUnit.state` (`"translated"` once reviewed, `"new"` if untouched —
  set it to `"translated"` when you fill one in).
- **Filling in missing translations**: open the catalog in Xcode and filter
  by state to find strings still marked `new` or missing a language
  entirely — these are the untranslated gaps, and PRs closing them are
  welcome even without a matching code change.
- **New locales**: open an issue first to confirm the locale is feasible.
  Translations should be concise, informal, and idiomatic.
- **If you're adding or changing a `String(localized:)` call**: Xcode
  regenerates catalog entries automatically on build, so don't hand-edit the
  English source string in the JSON — change the Swift call site and let the
  build add the new entry, then translate it. One exception: a control's
  *display label* used for preset import/export round-tripping must not be
  the only thing carrying its identity across locales — see the encoded/decode
  split in `ButtonBinding`/`TouchRingMode` and the note in
  `tools/tests/preset-locale-tests/main.swift`.

## Pull requests

- One sentence on what the PR does.
- macOS version and hardware tested on.
- Steps to verify the change.

**Feature requests as standalone issues aren't tracked** — issues here are for
confirmed work (bugs, device support, translations), so an untracked feature
request may remain unaddressed for a while. The most direct path would be to
propose a new feature alongside a willingness to help build it.

## Forking

MockTab is GPL-3.0-or-later. Fork, modify, and redistribute under the same terms.

To build something without GPL obligations, consider using [TabletKit](https://github.com/Cyzor/TabletKit) directly.  The decoder layer ships as a separate MPL-2.0 Swift package, usable from any macOS app without GPL contamination.