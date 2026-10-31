// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Standalone checks for TabletFigure.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real TabletFigure.swift, the generated TabletLayoutTable.swift,
// TabletLayoutIdentity.swift, and TabletOrientation.swift. Run via tools/tests/tablet-figure-tests/run.sh.
// Exits non-zero on failure.

import CoreGraphics
import Foundation

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (line \(line)): \(message())\n".utf8))
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

private typealias Part = TabletFigure.Part

private func figure(_ parts: [Part], mm: CGSize = CGSize(width: 224, height: 148), display: Bool = false) -> TabletFigure {
    TabletFigure(parts: parts, surfaceMM: mm, isPenDisplay: display)
}

// MARK: - Table

private func testTableParses() {
    let text = TabletLayoutTable.packed + "\n" + TabletLayoutExtras.packed
    var ids = 0
    for line in text.split(separator: "\n") {
        let halves = line.split(separator: ":", maxSplits: 1)
        expect(halves.count == 2, "line has ids and parts: \(line)")
        guard halves.count == 2 else { continue }
        let tokens = halves[1].split(separator: ",")
        let parsed = tokens.compactMap(Part.init(token:))
        expect(parsed.count == tokens.count, "every part parses: \(line)")
        for id in halves[0].split(separator: " ") {
            ids += 1
            expect(Int(id, radix: 16) != nil, "id is hex: \(id)")
        }
    }
    expect(TabletFigure.layouts.count == ids, "one layout per id (\(TabletFigure.layouts.count) of \(ids))")
    for (pid, parts) in TabletFigure.layouts {
        expect(!parts.isEmpty, String(format: "%04X has parts", pid))
        for p in parts {
            expect(p.start >= 0 && p.end <= 1 && p.start < p.end, String(format: "%04X span in range", pid))
            expect(p.lane >= 0 && p.lane < 3, String(format: "%04X lane in range", pid))
        }
    }
    expect(TabletFigure.layouts[TabletFigure.fallbackProductID] != nil, "fallback model has a layout")

    // Redrawn Wacom layouts parse whole and take the generated row's place,
    // followed by any added parts.
    let added = TabletFigure.parseLayouts(TabletLayoutExtras.addedParts)
    for line in TabletLayoutExtras.replaced.split(separator: "\n") {
        let halves = line.split(separator: ":", maxSplits: 1)
        let tokens = halves.count == 2 ? halves[1].split(separator: ",") : []
        expect(!tokens.isEmpty && tokens.compactMap(Part.init(token:)).count == tokens.count,
               "every redrawn part parses: \(line)")
        for id in halves.first?.split(separator: " ") ?? [] {
            let pid = Int(id, radix: 16) ?? -1
            expect(TabletFigure.layouts[pid] == tokens.compactMap(Part.init(token:)) + (added[pid] ?? []),
                   "\(id) takes the redrawn layout")
        }
    }
    let strips = TabletFigure.layouts[0x00CC]?.filter { $0.control == .strip } ?? []
    expect(strips.count == 2 && strips.allSatisfy(\.isBehind), "21UX2 strips sit on the back")
}

private func testTokens() {
    let run = Part(token: "k4fL0 160-357")
    expect(run == Part(control: .keys(count: 4, shape: .short), side: .left, lane: 0, start: 0.16, end: 0.357), "run token")
    expect(Part(token: "sR1 425-575")?.control == .strip, "strip token")
    expect(Part(token: "k4sT0 275-426")?.control == .keys(count: 4, shape: .square), "square keys, not a strip")
    expect(Part(token: "dT0 509-635")?.control == .dial, "dial token")
    expect(Part(token: "cB2 10-20")?.lane == 2, "lane digit")
    expect(Part(token: "xL0 1-2") == nil, "unknown control")
    expect(Part(token: "rL0 500-400") == nil, "backward span")
    expect(Part(token: "k0fL0 1-2") == nil, "empty run")
}

// MARK: - Orientation

private func testOrientationTurns() {
    let left = Part(control: .ring, side: .left, lane: 0, start: 0.2, end: 0.4)
    let top = Part(control: .ring, side: .top, lane: 0, start: 0.2, end: 0.3)
    let f = figure([left, top])

    // DisplayMapper.orient takes raw (x, y) to (y, 1 − x) in portrait.
    let portrait = f.oriented(.portrait)
    expect(portrait.parts[0].side == .bottom && near(portrait.parts[0].start, 0.2) && near(portrait.parts[0].end, 0.4),
           "portrait: left edge becomes the bottom, read the same way")
    expect(portrait.parts[1].side == .left && near(portrait.parts[1].start, 0.7) && near(portrait.parts[1].end, 0.8),
           "portrait: top edge becomes the left, reversed")
    expect(portrait.surfaceMM == CGSize(width: 148, height: 224), "portrait swaps the surface")

    let flipped = f.oriented(.landscapeFlipped)
    expect(flipped.parts[0].side == .right && near(flipped.parts[0].start, 0.6) && near(flipped.parts[0].end, 0.8),
           "flipped: left becomes right, reversed")
    expect(flipped.surfaceMM == f.surfaceMM, "flipped keeps the surface")

    let other = f.oriented(.portraitFlipped)
    expect(other.parts[0].side == .top && near(other.parts[0].start, 0.6) && near(other.parts[0].end, 0.8),
           "portrait flipped: left becomes the top, reversed")
    expect(f.oriented(.landscape) == f, "landscape is unchanged")
}

// MARK: - Layout

private func controls(_ d: TabletFigure.Drawing) -> [TabletFigure.Shape] {
    d.shapes.filter { $0.kind != .mark }
}

private func testLayoutInvariants() {
    let rects = [CGRect(x: 2, y: 2, width: 516, height: 196), CGRect(x: 2, y: 2, width: 296, height: 196)]
    var checked = 0
    for (pid, parts) in TabletFigure.layouts.sorted(by: { $0.key < $1.key }) {
        for display in [false, true] {
            let base = figure(parts, mm: CGSize(width: 300, height: 190), display: display)
            for orientation in TabletOrientation.allCases {
                let f = base.oriented(orientation)
                let name = String(format: "%04X %@", pid, String(describing: orientation))
                for scale in [1.0, 2.0] {
                    for (style, rect) in [(TabletFigure.Style.glyph, CGRect(x: 0, y: 0, width: 50, height: 50))]
                        + rects.map({ (TabletFigure.Style.bezel, $0) }) {
                        let d = f.drawing(style, in: rect, scale: scale)
                        let slack = 1 / scale
                        expect(rect.insetBy(dx: -slack, dy: -slack).contains(d.body), "\(name): body fits")
                        expect(d.body.insetBy(dx: -slack, dy: -slack).contains(d.surface), "\(name): surface inside body")
                        let shapes = controls(d)
                        let ring = shapes.filter { $0.kind == .ring }.count + shapes.filter { $0.kind == .dial }.count
                        expect(ring == parts.filter { $0.control == .ring || $0.control == .dial }.count,
                               "\(name): every ring and dial drawn")
                        for (i, a) in shapes.enumerated() {
                            expect(a.rect.width >= slack - 1e-9 && a.rect.height >= slack - 1e-9, "\(name): shape at least a pixel")
                            expect(d.bands.contains { $0.insetBy(dx: -slack, dy: -slack).contains(a.rect) },
                                   "\(name) \(style): shape inside a band")
                            expect(!d.surface.insetBy(dx: slack, dy: slack).intersects(a.rect), "\(name) \(style): shape clear of the surface")
                            for b in shapes[(i + 1)...] {
                                let overlap = a.rect.intersection(b.rect)
                                expect(overlap.isNull || overlap.width * overlap.height <= slack * slack / 4,
                                       "\(name) \(style) @\(scale)x: shapes don't overlap")
                            }
                        }
                        if style == .bezel {
                            let aspect = f.surfaceMM.width / f.surfaceMM.height
                            expect(near(d.surface.width / d.surface.height, aspect, 1e-6),
                                   "\(name): bezel surface keeps the editor's shape")
                        }
                        checked += 1
                    }
                }
            }
        }
    }
    expect(checked > 0, "layouts checked")
}

private func testIntuosProGlyph() {
    // The hand-drawn glyph this replaces: two keys, the ring, two keys.
    let parts = TabletFigure.layouts[0x0357] ?? []
    let f = TabletFigure(layoutProductID: 0x0357, surfaceMM: CGSize(width: 224, height: 148),
                         aspect: 44800.0 / 29600.0, isPenDisplay: false)
    expect(f.parts == parts, "lookup finds the layout")
    let d = f.drawing(.glyph, in: CGRect(x: 0, y: 0, width: 50, height: 50), scale: 2)
    let keys = d.shapes.filter { $0.kind == .key }
    let rings = d.shapes.filter { $0.kind == .ring }
    expect(keys.count == 4 && rings.count == 1, "glyph shows four keys and a ring (\(keys.count), \(rings.count))")
    if let ring = rings.first {
        expect(keys.filter { $0.rect.maxY <= ring.rect.minY }.count == 2, "two keys above the ring")
        expect(keys.filter { $0.rect.minY >= ring.rect.maxY }.count == 2, "two keys below the ring")
        expect(keys.allSatisfy { $0.rect.maxX <= d.surface.minX }, "keys left of the surface")
        // Optically even: 2 pt between keys, a pixel less beside the ring.
        let column = (keys + rings).sorted { $0.rect.minY < $1.rect.minY }
        let gaps = zip(column, column.dropFirst()).map { $1.rect.minY - $0.rect.maxY }
        expect(gaps == [2, 1.5, 1.5, 2], "keys and ring optically evenly spaced (\(gaps))")
    }
    expect(d.shapes.filter { $0.kind == .mark }.count == 8, "four corner marks")

    let bezel = f.drawing(.bezel, in: CGRect(x: 2, y: 2, width: 516, height: 196), scale: 2)
    expect(bezel.shapes.filter { $0.kind == .key }.count == 8, "bezel shows all eight keys")
}

private func testPlainFigure() {
    let plain = TabletFigure(layoutProductID: nil, surfaceMM: nil, aspect: 16.0 / 9.0, isPenDisplay: true)
    expect(plain.parts.isEmpty, "no layout, no parts")
    let glyph = plain.drawing(.glyph, in: CGRect(x: 0, y: 0, width: 50, height: 50), scale: 2)
    expect(glyph.bands.isEmpty, "no bands")
    expect(glyph.shapes.isEmpty, "a pen display's glyph is a filled screen")
    let tablet = TabletFigure(layoutProductID: nil, surfaceMM: nil, aspect: 1.6, isPenDisplay: false)
    expect(tablet.drawing(.glyph, in: CGRect(x: 0, y: 0, width: 50, height: 50), scale: 2).shapes.allSatisfy { $0.kind == .mark },
           "a tablet's glyph keeps its corner marks")
    let missing = TabletFigure(layoutProductID: 0xFFFF, surfaceMM: nil, aspect: 1.5, isPenDisplay: false)
    expect(missing.parts.isEmpty, "an unknown model draws plain")
    let fallback = TabletFigure(layoutProductID: TabletFigure.fallbackProductID, surfaceMM: nil, aspect: 1.5, isPenDisplay: false)
    let empty = fallback.drawing(.bezel, in: .zero, scale: 2)
    expect(empty.body == .zero && empty.shapes.isEmpty, "no room, nothing drawn")
}

// MARK: - Chin and glyph proportions

private func testChin() {
    let plain = TabletFigure(layoutProductID: nil, surfaceMM: CGSize(width: 527, height: 296),
                             aspect: 105000.0 / 59000.0, isPenDisplay: true)
    expect(plain.chin == .bottom, "a figure with no controls gets a chin at the bottom")
    expect(plain.oriented(.portrait).chin == .right, "portrait turns the chin to the right")
    expect(plain.oriented(.landscapeFlipped).chin == .top, "flipped puts the chin on top")
    expect(plain.oriented(.portraitFlipped).chin == .left, "portrait flipped turns the chin to the left")
    let banded = TabletFigure(layoutProductID: 0x0357, surfaceMM: nil, aspect: 1.5, isPenDisplay: false)
    expect(banded.chin == nil, "controls show the orientation, so no chin")

    let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
    for (orientation, deep) in [(TabletOrientation.landscape, TabletFigure.Side.bottom), (.portrait, .right),
                                (.landscapeFlipped, .top), (.portraitFlipped, .left)] {
        let d = plain.oriented(orientation).drawing(.glyph, in: rect, scale: 2)
        let bezels: [TabletFigure.Side: Double] = [
            .left: d.surface.minX - d.body.minX, .right: d.body.maxX - d.surface.maxX,
            .top: d.surface.minY - d.body.minY, .bottom: d.body.maxY - d.surface.maxY]
        let others = Set(bezels.filter { $0.key != deep }.map(\.value))
        expect(others.count == 1 && bezels[deep]! > others.first! * 1.5,
               "\(orientation): an even bezel, deepest on the chin's side (\(bezels))")
    }
    let bezel = plain.drawing(.bezel, in: CGRect(x: 0, y: 0, width: 500, height: 200), scale: 2)
    expect(bezel.body.maxY - bezel.surface.maxY > (bezel.surface.minY - bezel.body.minY) * 1.5,
           "the bezel's chin is deeper too")
}

private func testGlyphProportions() {
    let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
    for (pid, parts) in TabletFigure.layouts {
        let f = TabletFigure(parts: parts, surfaceMM: CGSize(width: 300, height: 190), isPenDisplay: false)
        for orientation in TabletOrientation.allCases {
            let d = f.oriented(orientation).drawing(.glyph, in: rect, scale: 2)
            let long = max(d.body.width, d.body.height) / min(d.body.width, d.body.height)
            expect(long >= 1.2 && long <= 1.86, String(format: "%04X glyph keeps a tablet's proportions (%.2f)", pid, long))
            let landscapeBody = d.body.width >= d.body.height
            let turned = orientation == .portrait || orientation == .portraitFlipped
            expect(landscapeBody != turned, String(format: "%04X glyph turns with the tablet", pid))
        }
    }
    // Every glyph sits on its grid, and its spacing is optically even: within
    // a row, gaps between straight shapes match, and gaps beside circles are
    // one unit less.
    for (pid, parts) in TabletFigure.layouts {
        for display in [false, true] {
            let f = TabletFigure(parts: parts, surfaceMM: CGSize(width: 300, height: 190), isPenDisplay: display)
            for orientation in TabletOrientation.allCases {
                let d = f.oriented(orientation).drawing(.glyph, in: rect, scale: 2)
                let name = String(format: "%04X %@", pid, String(describing: orientation))
                let edges = [d.body, d.opening, d.surface] + d.bands + d.shapes.map(\.rect)
                expect(edges.allSatisfy { r in [r.minX, r.minY, r.maxX, r.maxY].allSatisfy { near(($0 * 2).rounded(), $0 * 2) } },
                       "\(name): every edge on the half-point grid")
                for band in d.bands {
                    let vertical = band.height > band.width
                    let row = controls(d).filter { band.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) }
                        .sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
                    func gap(_ a: TabletFigure.Shape, _ b: TabletFigure.Shape) -> Double {
                        vertical ? b.rect.minY - a.rect.maxY : b.rect.minX - a.rect.maxX
                    }
                    func round(_ shape: TabletFigure.Shape) -> Bool { shape.kind == .ring || shape.kind == .dial }
                    let pairs: [(gap: Double, round: Bool)] = zip(row, row.dropFirst())
                        .map { a, b in (gap(a, b), round(a) || round(b)) }
                        .filter { $0.gap < 5 }
                    let straight = Set(pairs.filter { !$0.round }.map { $0.gap })
                    let curved = Set(pairs.filter { $0.round }.map { $0.gap })
                    expect(straight.count <= 1 && curved.count <= 1, "\(name): even gaps in a row \(pairs.map { $0.gap })")
                    if let a = straight.first, let b = curved.first {
                        expect(near(a - b, d.unit), "\(name): a unit less beside a circle")
                    }
                }
            }
        }
    }

    // A square surface turns with its bands.
    let square = TabletFigure(layoutProductID: 0x00B3, surfaceMM: CGSize(width: 305, height: 305),
                              aspect: 1, isPenDisplay: false)
    for orientation in TabletOrientation.allCases {
        let d = square.oriented(orientation).drawing(.glyph, in: rect, scale: 2)
        let turned = orientation == .portrait || orientation == .portraitFlipped
        expect((d.body.width > d.body.height) != turned, "a square tablet's glyph turns with its bands, \(orientation)")
    }

    // The Intuos Pro family's ring sits on the band's centerline in every
    // orientation, keys balanced above and below.
    for (pid, w, h, aspect) in [(0x0357, 224.0, 148.0, 44800.0 / 29600.0), (0x0358, 311, 216, 62200.0 / 43200.0),
                                (0x0028, 325, 203, 65024.0 / 40640.0)] {
        let f = TabletFigure(layoutProductID: pid, surfaceMM: CGSize(width: w, height: h), aspect: aspect, isPenDisplay: false)
        for orientation in TabletOrientation.allCases {
            let d = f.oriented(orientation).drawing(.glyph, in: rect, scale: 2)
            guard let ring = d.shapes.first(where: { $0.kind == .ring }), let band = d.bands.first else { continue }
            let vertical = band.height > band.width
            expect(near(vertical ? ring.rect.midY : ring.rect.midX, vertical ? band.midY : band.midX),
                   String(format: "%04X ring on the centerline, %@", pid, String(describing: orientation)))
        }
    }

    // Near twins draw the same: the PTH-660 and PTH-860 differ only in size.
    let medium = TabletFigure(layoutProductID: 0x0357, surfaceMM: CGSize(width: 224, height: 148),
                              aspect: 44800.0 / 29600.0, isPenDisplay: false)
    let largeSibling = TabletFigure(layoutProductID: 0x0358, surfaceMM: CGSize(width: 311, height: 216),
                                    aspect: 62200.0 / 43200.0, isPenDisplay: false)
    for orientation in TabletOrientation.allCases {
        expect(medium.oriented(orientation).drawing(.glyph, in: rect, scale: 2)
                == largeSibling.oriented(orientation).drawing(.glyph, in: rect, scale: 2),
               "PTH-660 and PTH-860 glyphs match, \(orientation)")
    }

    // A larger tablet's shorter key runs still show two keys each, like its smaller siblings.
    let large = TabletFigure(layoutProductID: 0x0028, surfaceMM: CGSize(width: 325, height: 203),
                             aspect: 65024.0 / 40640.0, isPenDisplay: false)
    let keys = large.drawing(.glyph, in: rect, scale: 2).shapes.filter { $0.kind == .key }
    expect(keys.count == 4, "the PTH-850 glyph shows two keys each side of its ring (\(keys.count))")
}

// MARK: - Icon

private func testIcon() {
    let rect = CGRect(x: 0, y: 0, width: 28, height: 22)
    func contains(_ outer: CGRect, _ inner: CGRect) -> Bool { outer.insetBy(dx: -1e-9, dy: -1e-9).contains(inner) }
    for (pid, parts) in TabletFigure.layouts {
        for size in [CGSize(width: 150, height: 95), CGSize(width: 325, height: 203), CGSize(width: 519, height: 324),
                     CGSize(width: 305, height: 305)] {
            let d = TabletFigure(parts: parts, surfaceMM: size, isPenDisplay: false).drawing(.icon, in: rect, scale: 1)
            let name = String(format: "%04X icon at %.0f mm", pid, size.width)
            expect(contains(rect, d.body), "\(name) fits its frame (\(d.body))")
            let long = max(d.body.width, d.body.height) / min(d.body.width, d.body.height)
            expect(long >= 1.15 && long <= 1.95, String(format: "%@ keeps a tablet's proportions (%.2f)", name, long))
            expect(d.surface.width >= 6 && d.surface.height >= 4, "\(name) keeps a surface (\(d.surface))")
            let panels = [d.body, d.opening, d.surface] + d.bands
            expect(panels.allSatisfy { r in [r.minX, r.minY, r.maxX, r.maxY].allSatisfy { near($0.rounded(), $0) } },
                   "\(name): every panel edge on a whole point")
            for (i, shape) in d.shapes.enumerated() {
                expect(d.bands.contains { contains($0.insetBy(dx: 0.99, dy: 0.99), shape.rect) },
                       "\(name): \(shape.kind) sits inside a band with a point to spare")
                for other in d.shapes[(i + 1)...] {
                    expect(!shape.rect.insetBy(dx: -0.99, dy: -0.99).intersects(other.rect),
                           "\(name): shapes keep a point apart")
                }
            }
            expect(!parts.isEmpty == !d.shapes.isEmpty, "\(name): a tablet with controls shows some")
        }
    }
    // Size reads too: a large tablet's icon is longer than a small one's.
    func long(_ pid: Int, _ w: Double, _ h: Double) -> Double {
        let d = TabletFigure(layoutProductID: pid, surfaceMM: CGSize(width: w, height: h), aspect: w / h, isPenDisplay: false)
            .drawing(.icon, in: rect, scale: 2)
        return d.body.width
    }
    expect(long(0x0357, 224, 148) < long(0x0358, 311, 216), "the PTH-860 icon is longer than the PTH-660's")
    expect(long(0x0374, 152, 95) < long(0x00F4, 519, 324), "a Cintiq 24HD icon is longer than an Intuos S's")
    // The Intuos Pro ring sits mid-band, keys either side.
    let pro = TabletFigure(layoutProductID: 0x0358, surfaceMM: CGSize(width: 311, height: 216), aspect: 311.0 / 216, isPenDisplay: false)
    let d = pro.drawing(.icon, in: rect, scale: 2)
    if let ring = d.shapes.first(where: { $0.kind == .dial }), let band = d.bands.first {
        expect(near(ring.rect.midY, band.midY), "the PTH-860 icon's ring on the centerline")
        let keys = d.shapes.filter { $0.kind == .key }
        let above = keys.filter { $0.rect.maxY <= ring.rect.minY }.count
        expect(above > 0 && above * 2 == keys.count, "keys balanced each side of the ring (\(above) of \(keys.count))")
    } else {
        expect(false, "the PTH-860 icon shows its ring")
    }
    // A plain display keeps a chin.
    let plain = TabletFigure(layoutProductID: nil, surfaceMM: CGSize(width: 527, height: 296), aspect: 527.0 / 296, isPenDisplay: true)
        .drawing(.icon, in: rect, scale: 2)
    expect(plain.body.maxY - plain.surface.maxY > plain.surface.minY - plain.body.minY, "a plain display's icon has a chin")
    // Mirrored layouts stay mirrored: the PTK-870's two groups on its top edge.
    let ptk = TabletFigure(layoutProductID: 0x03F9, surfaceMM: CGSize(width: 349, height: 195), aspect: 349.0 / 195, isPenDisplay: false)
        .drawing(.icon, in: rect, scale: 2)
    if let band = ptk.bands.first {
        let xs = ptk.shapes.map { $0.rect }.sorted { $0.minX < $1.minX }
        let mirrored = zip(xs, xs.reversed()).allSatisfy { near($0.minX - band.minX, band.maxX - $1.maxX) && near($0.width, $1.width) }
        expect(xs.count == 4 && mirrored, "the PTK-870 icon's top row is mirrored (\(xs.map(\.minX)))")
        let gaps = zip(xs, xs.dropFirst()).map { $1.minX - $0.maxX }
        expect(gaps.count == 3 && gaps[1] > gaps[0], "its two groups read apart (\(gaps))")
    }
}

// MARK: - Identity

private typealias Identity = TabletLayoutIdentity

/// Models where libwacom draws one key twice, matching the generator's exceptions.
private let doubledKeys: [Int: Set<Character>] = [0x003A: ["B"]]

private func testIdentityTable() {
    var ids: [Int] = []
    for line in (TabletLayoutTable.identity + "\n" + TabletLayoutExtras.identity).split(separator: "\n") {
        let parsed = Identity.parse(line: line)
        expect(parsed != nil, "identity line parses: \(line)")
        ids += parsed?.ids ?? []
    }
    expect(Set(ids).count == ids.count, "each model has one identity line")
    expect(Set(ids) == Set(TabletFigure.layouts.keys), "every layout has an identity, and nothing else does")
    expect(Identity.all.count == ids.count, "the loader reads every line")

    for (pid, identity) in Identity.all.sorted(by: { $0.key < $1.key }) {
        let name = String(format: "%04X", pid)
        guard let parts = TabletFigure.layouts[pid] else { continue }
        // Parts added to a libwacom layout come last and drive nothing.
        let added = TabletFigure.parseLayouts(TabletLayoutExtras.addedParts)[pid]?.count ?? 0
        expect(identity.entries.count + added == parts.count, "\(name): one entry per part")
        var numbers: [String: Set<Int>] = [:]
        for (entry, part) in zip(identity.entries, parts) {
            switch (entry, part.control) {
            case let (.run(letters), .keys(count, _)):
                expect(letters.count == count, "\(name): run of \(count) names \(letters.count) keys")
            case (.cluster, .cluster): break
            case let (.ring(n, _), .ring): numbers["r", default: []].insert(n)
            case let (.dial(n, _), .dial): numbers["d", default: []].insert(n)
            case let (.strip(n), .strip): numbers["s", default: []].insert(n)
            default: expect(false, "\(name): \(entry) doesn't match \(part.control)")
            }
        }
        // Rings, dials, and strips number from 1 without gaps or repeats.
        for (kind, n) in numbers {
            let count = identity.entries.filter { e in
                switch (e, kind) {
                case (.ring, "r"), (.dial, "d"), (.strip, "s"): return true
                default: return false
                }
            }.count
            expect(n == Set(1...max(count, 1)) && n.count == count, "\(name): \(kind) numbered 1 to \(count) (\(n.sorted()))")
        }

        // Every letter from A to the last, once, apart from known doubles.
        let letters = identity.letters
        let unique = Set(letters)
        let expected = Set((0..<unique.count).map { Character(UnicodeScalar(UInt8(65 + $0))) })
        expect(unique == expected, "\(name): letters run from A without gaps (\(String(letters.sorted())))")
        let doubled = Set(letters.filter { l in letters.filter { $0 == l }.count > 1 })
        expect(doubled == doubledKeys[pid] ?? [], "\(name): no key named twice (\(String(doubled.sorted())))")

        for (letter, mode) in identity.modeSwitches {
            expect(unique.contains(letter), "\(name): mode key \(letter) is a drawn key")
            let target: (String, Int)
            switch mode.control {
            case let .ring(n): target = ("r", n)
            case let .dial(n): target = ("d", n)
            case let .strip(n): target = ("s", n)
            }
            expect(numbers[target.0]?.contains(target.1) == true, "\(name): mode key \(letter) targets a drawn control")
        }
        if let codes = identity.evdevCodes {
            expect(codes.count == unique.count, "\(name): one evdev code per key (\(codes.count) of \(unique.count))")
        }
    }
}

private func testIdentityTokens() {
    let parsed = Identity.parse(line: "03F7 03F9: c .D./AIC/.B.; d 1; d 2; c .H./EJG/.F. | m I=d1 J=d2")
    expect(parsed?.ids == [0x03F7, 0x03F9], "ids")
    if let identity = parsed?.identity {
        expect(identity.entries.count == 4, "four entries")
        expect(identity.entries[0] == .cluster(Identity.Grid(rows: [[.empty, .key("D"), .empty],
                                                                   [.key("A"), .key("I"), .key("C")],
                                                                   [.empty, .key("B"), .empty]])), "cluster grid")
        expect(identity.entries[0].letters == ["D", "A", "I", "C", "B"], "grid letters in reading order")
        expect(identity.entries[1] == .dial(1, .none), "dial with no keys")
        expect(identity.modeSwitches["J"] == Identity.ModeSwitch(control: .dial(2), mode: nil), "cycling mode key")
    }
    let ring = Identity.parse(line: "00F4: r 1 A@/B@/C@; k D | m A=r1.0 | ev 100 101 102 103")?.identity
    expect(ring?.entries.first == .ring(1, .beside(Identity.Grid(rows: [[.key("A"), .body], [.key("B"), .body],
                                                                       [.key("C"), .body]]))), "keys beside a ring")
    expect(ring?.modeSwitches["A"] == Identity.ModeSwitch(control: .ring(1), mode: 0), "mode key picks mode 0")
    expect(ring?.evdevCodes == [0x100, 0x101, 0x102, 0x103], "evdev codes in hex")
    expect(Identity.parse(line: "0357: k ABCD; r 1 I; k EFGH")?.identity.entries[1] == .ring(1, .center("I")), "center key")
    expect(Identity.parse(line: "0357: c AB/AC; k D")?.identity.entries[0].letters == ["A", "B", "C"],
           "a key spanning cells counts once")

    for bad in ["0357 k ABCD", "XYZ: k A", "0357: k abc", "0357: k", "0357: q A", "0357: c AB/C", "0357: c A",
                "0357: c A@", "0357: r 0", "0357: r 1 AB", "0357: s 1 A", "0357: k A | m A=x1", "0357: k A | m A=r1.x",
                "0357: k A | ev 1G", "0357: k A | zz 1", "0357: k A | m A=r1 A=r1", "0357: k A;; k B",
                "0357: k A || m A=r1", "0357: k A |"] {
        expect(Identity.parse(line: Substring(bad)) == nil, "rejects \(bad)")
    }
}

// MARK: - Golden drawings

/// Every layout drawn in every style, orientation, and scale the app uses,
/// compared exactly with golden-drawings.txt so a layout change shows up as a
/// reviewable diff. UPDATE_GOLDENS=1 rewrites the file instead.
private func testGoldenDrawings(directory: String) {
    func r(_ rect: CGRect) -> String { "\(rect.minX) \(rect.minY) \(rect.width) \(rect.height)" }
    func line(_ d: TabletFigure.Drawing) -> String {
        var fields = ["body \(r(d.body))", "opening \(r(d.opening))", "surface \(r(d.surface))", "unit \(d.unit)"]
        fields += d.bands.map { "band \(r($0))" }
        fields += d.shapes.map { "\($0.kind) \(r($0.rect))" }
        return fields.joined(separator: " | ")
    }

    // One figure per distinct layout, named by its first product ID, then plain bodies.
    var figures: [(String, TabletFigure)] = []
    for row in (TabletLayoutTable.packed + "\n" + TabletLayoutExtras.packed).split(separator: "\n") {
        guard let first = row.split(separator: ":").first?.split(separator: " ").first,
              let pid = Int(first, radix: 16), let parts = TabletFigure.layouts[pid] else { continue }
        for display in [false, true] {
            figures.append((String(format: "%04X %@", pid, display ? "display" : "tablet"),
                            figure(parts, mm: CGSize(width: 300, height: 190), display: display)))
        }
    }
    for (aspect, display) in [(1.6, false), (16.0 / 9.0, true)] {
        figures.append((String(format: "plain %.3f %@", aspect, display ? "display" : "tablet"),
                        TabletFigure(layoutProductID: nil, surfaceMM: nil, aspect: aspect, isPenDisplay: display)))
    }

    var out: [String] = []
    for (name, base) in figures {
        out.append("## \(name)")
        for orientation in TabletOrientation.allCases {
            let f = base.oriented(orientation)
            // The glyph and icon keep their own grids, so scale doesn't reach them.
            out.append("\(orientation) glyph 50x50: " + line(f.drawing(.glyph, in: CGRect(x: 0, y: 0, width: 50, height: 50), scale: 2)))
            out.append("\(orientation) icon 28x22: " + line(f.drawing(.icon, in: CGRect(x: 0, y: 0, width: 28, height: 22), scale: 2)))
            for scale in [1.0, 2.0] {
                for rect in [CGRect(x: 2, y: 2, width: 516, height: 196), CGRect(x: 2, y: 2, width: 296, height: 196)] {
                    out.append("\(orientation) bezel \(Int(rect.width))x\(Int(rect.height)) @\(Int(scale))x: "
                               + line(f.drawing(.bezel, in: rect, scale: scale)))
                }
            }
        }
    }
    let text = out.joined(separator: "\n") + "\n"
    let path = directory + "/golden-drawings.txt"

    if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("golden-drawings.txt rewritten (\(out.count) lines)")
        return
    }
    guard let golden = try? String(contentsOfFile: path, encoding: .utf8) else {
        expect(false, "no golden-drawings.txt; run with UPDATE_GOLDENS=1")
        return
    }
    let a = golden.split(separator: "\n", omittingEmptySubsequences: false)
    let b = text.split(separator: "\n", omittingEmptySubsequences: false)
    var section = "", differing = 0
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? String(a[i]) : "<end>"
        let y = i < b.count ? String(b[i]) : "<end>"
        if y.hasPrefix("## ") { section = y }
        guard x != y else { continue }
        differing += 1
        // The first few are enough to see what moved.
        if differing <= 3 {
            FileHandle.standardError.write(Data("golden line \(i + 1) in \(section)\n  expected: \(x)\n  got:      \(y)\n".utf8))
        }
    }
    expect(differing == 0, "drawings match golden-drawings.txt (\(differing) lines differ)")
}

testTableParses()
testTokens()
testIdentityTable()
testIdentityTokens()
testChin()
testGlyphProportions()
testOrientationTurns()
testLayoutInvariants()
testIntuosProGlyph()
testPlainFigure()
testIcon()
testGoldenDrawings(directory: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

if failures > 0 {
    print("tablet-figure-tests: \(failures) of \(checks) checks failed")
    exit(1)
}
print("tablet-figure-tests: all \(checks) checks passed")
