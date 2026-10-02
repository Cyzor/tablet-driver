# Contributing to MockTab

MockTab is a macOS driver for older Wacom drawing tablets. It ships
under GPL-3.0-or-later.

## Getting started

1. **Build it.**

   ```sh
   git clone --recurse-submodules https://github.com/Cyzor/tablet-driver.git
   cd tablet-driver
   open MockTab.xcodeproj
   ```

   You need Xcode 26 or later. Pick the **MockTab** scheme and build. In a
   fork, set signing to your own team under Signing & Capabilities.

2. **Run the tests.** Decoders first, then app logic:

   ```sh
   cd TabletKit && swift test && cd ..
   tools/tests/run-all-tests.sh
   ```

   Each harness in `tools/tests/` also runs alone, e.g.
   `tools/tests/calibration-tests/run.sh`.

3. **Read the "Following a…" sections of [`Architecture.md`](Architecture.md).**
   It follows a pen sample, a settings change, a device plugging in, and
   touch, file by file.

4. **Watch one pen report go by.** Set a breakpoint in
   `InputInjector.inject(point:settings:)`, run, and hover the pen. The call
   stack shows the whole path from `handleReport`.

5. **Read the logs.** Everything logs under the `com.cyzor.mocktab`
   subsystem:

   ```sh
   log stream --predicate 'subsystem == "com.cyzor.mocktab"'
   ```

6. **Make a capture.** **Help › Collect Device Data…** records a session to a
   zip on the Desktop. It's what users attach to bug reports, and the fastest
   way to see what a tablet sends.

Adding a tablet model has its own guide:
[`TabletKit/Extending-Support.md`](TabletKit/Extending-Support.md).

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
2. With the tablet connected, choose **Help › Collect Device Data…** and use the tablet as prompted. It saves a zip to the Desktop.
3. Open an issue using the [bug report template](.github/ISSUE_TEMPLATE/bug-report.yml). Include your macOS version, tablet model, and steps to reproduce, and attach the zip.

## How to request device support

1. Choose **Help › Collect Device Data…** and use the tablet as prompted. The zip holds the device's HID descriptor, USB strings, and a summary of what it sent.
2. Open an issue using the [Device support template](.github/ISSUE_TEMPLATE/device-support.yml) and attach the zip.

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

Have an idea? Use the [feature request form](https://github.com/Cyzor/tablet-driver/issues/new?template=feature-request.yml). Suggestions that come with an offer to help build them usually move fastest.

## Forking

MockTab is GPL-3.0-or-later. Fork, modify, and redistribute under the same terms.

To build something without GPL obligations, consider using [TabletKit](https://github.com/Cyzor/TabletKit) directly.  The decoder layer ships as a separate MPL-2.0 Swift package, usable from any macOS app without GPL contamination.