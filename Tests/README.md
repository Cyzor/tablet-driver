# MockTab Tests

SwiftPM-based unit tests for the pure-logic parts of MockTab (decoders, helpers).
Lives alongside `MockTab.xcodeproj`; the Xcode build is unaffected.

## Run

```sh
swift test          # from the project root
swift test --filter IntuosV1DecoderTests   # one suite
```

## Layout

- `Package.swift` (project root) — defines the `MockTabDecoders` library
  target (vendoring a minimal slice of `MockTab/Driver/`) and the
  `MockTabDecodersTests` test target.
- `Tests/MockTabDecodersTests/` — test files. One per decoder family.

## Why a SwiftPM sidecar instead of an Xcode test target?

Adding a test target inside `MockTab.xcodeproj` requires hand-editing
`project.pbxproj` (risky) or clicking through Xcode's UI (one-time, but
not scriptable). A sidecar Package.swift gives us `swift test` from CLI
today without touching the Xcode project. If/when the test surface
grows beyond pure decoders, revisit this choice.

## Adding a test

1. Find the decoder file under `MockTab/Driver/Decoders/`.
2. Read the byte-layout comments at the top of the file.
3. Add a `Tests/MockTabDecodersTests/<Name>Tests.swift` with:
   ```swift
   @testable import MockTabDecoders
   import XCTest
   ```
4. `swift test` to run.

## Adding a new module to the package

If a test needs a type that lives outside the currently-vendored files,
edit `Package.swift`: add the file path to the `sources:` list and
remove it from `exclude:`. Be wary of pulling in AppKit/SwiftUI types —
the package builds cleanly today because the vendored slice is
pure-logic; introducing UI dependencies will break that.

## Why XCTest "No such module" appears in SourceKit

SourceKit (the LSP backing your editor) doesn't always pick up SwiftPM
test-target dependencies. The error is editor-only — `swift build` and
`swift test` resolve XCTest correctly.
