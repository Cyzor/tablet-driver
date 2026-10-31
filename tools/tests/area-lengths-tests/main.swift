// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Checks for the Tablet Area pane's typed sizes. Run via
// tools/tests/area-lengths-tests/run.sh.

import Foundation

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
}

/// Stands in for the pane's spoken sizes, which pull in SwiftUI.
enum AreaSpokenSize {
    case millimeters(CGSize)
    func length(of fraction: Double, horizontal: Bool) -> String { "" }
}

private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

// Either mark is the decimal point, whatever the region uses.
for (locale, text, value) in [
    ("de_DE", "12.5", 12.5), ("de_DE", "12,5", 12.5), ("de_DE", "1.234,5", 1234.5),
    ("en_US", "8,8", 8.8), ("en_US", "8.8", 8.8), ("en_US", "1,234.5", 1234.5),
    ("fr_FR", "12.5", 12.5), ("ja_JP", "224", 224), ("ar_SA", "١٢٫٥", 12.5),
] {
    let got = AreaLengths.decimal(text, locale: Locale(identifier: locale))
    expect(near(got, value), "\(locale) \"\(text)\" reads \(got.map { "\($0)" } ?? "nil"), not \(value)")
}
expect(AreaLengths.decimal("") == nil, "empty text reads as no number")
expect(AreaLengths.decimal("abc") == nil, "letters read as no number")

// Typed units, on a 224 × 148 mm surface.
let lengths = AreaLengths(surfaceMM: CGSize(width: 224, height: 148))
expect(near(lengths.fraction(fromTyped: "112 mm", horizontal: true), 0.5), "112 mm is half the width")
expect(near(lengths.fraction(fromTyped: "7,4cm", horizontal: false), 0.5), "7,4 cm is half the height")
expect(near(lengths.fraction(fromTyped: "7.4cm", horizontal: false), 0.5), "7.4 cm is half the height")
expect(near(lengths.fraction(fromTyped: "50%", horizontal: true), 0.5), "50% is half")
expect(near(lengths.fraction(fromTyped: "4.41in", horizontal: true), 4.41 * 25.4 / 224), "inches convert")
expect(lengths.fraction(fromTyped: "0 mm", horizontal: true) == nil, "zero is refused")
expect(lengths.fraction(fromTyped: "-5 mm", horizontal: true) == nil, "negative is refused")

// Unknown surface: only percentages make sense.
let unknown = AreaLengths(surfaceMM: nil)
expect(near(unknown.fraction(fromTyped: "40 mm", horizontal: true), 0.4), "an unknown surface reads units as percent")

if failures == 0 {
    print("area-lengths-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("area-lengths-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
