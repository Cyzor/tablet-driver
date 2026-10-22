// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Standalone checks for where a tablet's controls sit.
//
// Compiled against the real TabletFigure.swift, the generated layout table,
// TabletLayoutIdentity.swift, TabletControlMap.swift, TabletOrientation.swift,
// and TabletKit. Run via tools/tests/tablet-position-tests/run.sh. Exits
// non-zero on failure.

import CoreGraphics
import Foundation
import TabletKit

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (line \(line)): \(message())\n".utf8))
}

private func hex(_ id: Int) -> String { String(format: "%04X", id) }

private func describe(_ t: ControlTarget) -> String {
    switch t {
    case let .expressKey(i): return "K\(i)"
    case let .bezel(i): return "B\(i)"
    case let .ringCenter(i): return "C\(i)"
    case let .ring(i): return "R\(i)"
    case let .dial(i): return "D\(i)"
    case let .strip(i): return "S\(i)"
    }
}

/// The model's figure in Landscape with its control map, as the Buttons pane builds it.
private func figure(_ productID: Int) -> TabletFigure? {
    guard let controls = TabletControlMap.figureControls(productID: productID) else { return nil }
    let spec = WacomDeviceRegistry.spec(for: productID)
    let mm = spec?.activeWidthMM.flatMap { w in spec?.activeHeightMM.map { CGSize(width: w, height: $0) } }
    let aspect = spec.map { $0.maxY > 0 ? Double($0.maxX) / Double($0.maxY) : 1.5 } ?? 1.5
    var figure = TabletFigure(layoutProductID: productID, surfaceMM: mm, aspect: aspect,
                              isPenDisplay: spec?.isPenDisplay ?? false)
    figure.controls = controls
    return figure
}

private let ids = Set(TabletLayoutIdentity.all.keys).union(TabletLayoutExtras.productIDs).sorted()
private var models = 0
// Models whose reading order isn't their numbering, which is why a control's
// number comes from its place in Landscape, not from reading order.
private var readOutOfOrder = 0

for id in ids {
    guard let figure = figure(id), let controls = figure.controls else { continue }
    models += 1
    let name = WacomDeviceRegistry.spec(for: id)?.name ?? "?"
    let order = figure.controlsInReadingOrder()

    // Every control the map drives is drawn, once.
    let mapped = Set(controls.flatMap { ($0.control.map { [$0] } ?? []) + Array($0.keys.values) })
    expect(Set(order) == mapped && order.count == mapped.count,
           "\(hex(id)) \(name): drawn \(order.map(describe)) vs mapped \(mapped.map(describe).sorted())")

    if Dictionary(grouping: order, by: \.kind).values.contains(where: { $0.map(\.index) != $0.map(\.index).sorted() }) {
        readOutOfOrder += 1
    }

    // Every orientation lines up one to one, and Landscape keeps today's numbering.
    for orientation in TabletOrientation.allCases {
        guard let eq = figure.landscapeEquivalents(turnedTo: orientation) else {
            expect(false, "\(hex(id)) \(name): \(orientation) doesn't line up with Landscape")
            continue
        }
        expect(Set(eq.keys) == mapped && Set(eq.values) == mapped && eq.allSatisfy { $0.key.kind == $0.value.kind },
               "\(hex(id)) \(name): \(orientation) isn't one to one within each kind")
        if orientation == .landscape {
            expect(eq.allSatisfy { $0.key == $0.value }, "\(hex(id)) \(name): Landscape renumbers a control")
        }
    }
}
expect(models > 90, "only \(models) models have a drawing and a control map")

// MARK: - Layouts, one of each kind

private func equivalents(_ id: Int, _ orientation: TabletOrientation) -> [ControlTarget: ControlTarget] {
    figure(id)?.landscapeEquivalents(turnedTo: orientation) ?? [:]
}

private func keys(_ map: [ControlTarget: ControlTarget], _ count: Int) -> [Int] {
    (0..<count).map { map[.expressKey($0)]?.index ?? -1 }
}

// PTH-860, keys down the left edge: Portrait keeps their order, a half turn
// reverses it. Cyzor's screenshots: Portrait's leftmost key is Key 1,
// Portrait Flipped's is Key 8.
expect(keys(equivalents(0x0358, .portrait), 8) == Array(0..<8), "PTH-860 Portrait keeps key order")
expect(keys(equivalents(0x0358, .landscapeFlipped), 8) == Array((0..<8).reversed()), "PTH-860 flipped reverses keys")
expect(keys(equivalents(0x0358, .portraitFlipped), 8) == Array((0..<8).reversed()), "PTH-860 Portrait Flipped reverses keys")
expect(equivalents(0x0358, .landscapeFlipped)[.ringCenter(0)] == .ringCenter(0), "PTH-860 ring center stays")

// CTL-4100, keys along the top: Portrait reverses them, Portrait Flipped doesn't.
expect(keys(equivalents(0x0374, .portrait), 4) == [3, 2, 1, 0], "CTL-4100 Portrait reverses keys")
expect(keys(equivalents(0x0374, .landscapeFlipped), 4) == [3, 2, 1, 0], "CTL-4100 flipped reverses keys")
expect(keys(equivalents(0x0374, .portraitFlipped), 4) == [0, 1, 2, 3], "CTL-4100 Portrait Flipped keeps key order")

// PTK-870, two pads and two dials along the top: each quarter turn moves a
// pad's keys one place, and a half turn trades the two sides.
expect(keys(equivalents(0x03F9, .landscapeFlipped), 8) == [6, 7, 4, 5, 2, 3, 0, 1], "PTK-870 flipped turns and trades pads")
expect(keys(equivalents(0x03F9, .portrait), 8) == [7, 4, 5, 6, 3, 0, 1, 2], "PTK-870 Portrait turns each pad a quarter")
expect(equivalents(0x03F9, .landscapeFlipped)[.dial(1)] == .dial(0), "PTK-870 flipped trades dials")
expect(equivalents(0x03F9, .portrait)[.dial(1)] == .dial(0), "PTK-870 Portrait reads the right dial first")
expect(equivalents(0x03F9, .landscapeFlipped)[.ringCenter(1)] == .ringCenter(0), "PTK-870 flipped trades dial toggles")

// Intuos3 6×8, keys and a strip on each side: a half turn trades the sides
// and reverses the keys, though the keys don't read in their numbering.
expect(keys(equivalents(0x00B1, .landscapeFlipped), 8) == Array((0..<8).reversed()), "Intuos3 flipped reverses keys")
expect(equivalents(0x00B1, .landscapeFlipped)[.strip(1)] == .strip(0), "Intuos3 flipped trades strips")

print("tablet-position-tests: \(models) models line up in every orientation (\(readOutOfOrder) read out of numbering order)")
print("tablet-position-tests: \(checks - failures) of \(checks) checks passed")
exit(failures == 0 ? 0 : 1)
