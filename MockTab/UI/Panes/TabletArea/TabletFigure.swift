// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

// MARK: - TabletFigure

/// A tablet drawn from a kit of parts: a body, its active surface, and the
/// keys, rings, dials, and strips along its edges. One recipe covers every
/// model, so none needs artwork of its own.
///
/// Where the controls sit comes from `TabletLayoutTable`, generated from
/// libwacom. The surface takes the shape the area editor uses, and its size
/// in millimeters sets the bezel's proportions.
struct TabletFigure: Equatable {
    enum Side: Equatable, CaseIterable { case left, right, top, bottom }

    /// How long each key in a run is along its edge, next to how deep it is.
    enum KeyShape: Equatable { case short, square, long }

    enum Control: Equatable {
        case keys(count: Int, shape: KeyShape)
        /// Keys packed in two directions, like a rocker or a four-way pad.
        case cluster
        case ring
        case dial
        case strip
    }

    struct Part: Equatable {
        var control: Control
        var side: Side
        /// 0 nearest the body's edge, counting inward.
        var lane: Int
        /// Span along the edge as fractions of it, from the top or left.
        var start: Double
        var end: Double
    }

    var parts: [Part]
    /// Active surface in millimeters, turned with the figure.
    var surfaceMM: CGSize
    var isPenDisplay: Bool
    /// The edge with a deeper bezel on a figure with no controls, so it still
    /// shows which way it's turned. Bottom in landscape.
    var chin: Side? = nil
    /// Which control each part and key drives, one per part, for the Buttons
    /// pane's diagram. With them, the bezel draws every key on its own and
    /// tags each shape with its target; without them it draws as always.
    var controls: [PartControls]? = nil

    struct PartControls: Equatable {
        /// The part's keys and their grid, from `TabletLayoutIdentity`.
        var entry: TabletLayoutIdentity.Entry
        /// The ring, dial, or strip the part is, if it's one.
        var control: ControlTarget?
        /// Each of the part's keys by letter.
        var keys: [Character: ControlTarget] = [:]
    }
}

// MARK: - Lookup

extension TabletFigure {
    /// With no tablet bound, the area editor takes the Intuos Pro M's shape,
    /// so the figure does too.
    static let fallbackProductID = 0x0357

    /// `layoutProductID` is nil for models outside the table, which draw as a
    /// plain body. `aspect` is the surface's width over its height, the shape
    /// the area editor gets, so the two line up.
    init(layoutProductID: Int?, surfaceMM: CGSize?, aspect: Double, isPenDisplay: Bool) {
        let aspect = aspect > 0 ? aspect : 1.5
        // Size only sets proportions, so a 150 mm short side stands in when it's unknown.
        let width = surfaceMM?.width ?? (aspect >= 1 ? 150 * aspect : 150)
        let parts = layoutProductID.flatMap { Self.layouts[$0] } ?? []
        self.init(
            parts: parts,
            surfaceMM: CGSize(width: width, height: width / aspect),
            isPenDisplay: isPenDisplay,
            chin: parts.isEmpty ? .bottom : nil)
    }

    /// Parts by product ID, read once from the generated table.
    static let layouts: [Int: [Part]] = parseLayouts(TabletLayoutTable.packed)

    static func parseLayouts(_ text: String) -> [Int: [Part]] {
        var layouts: [Int: [Part]] = [:]
        for line in text.split(separator: "\n") {
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let parts = halves[1].split(separator: ",").compactMap(Part.init(token:))
            for id in halves[0].split(separator: " ") {
                if let productID = Int(id, radix: 16) { layouts[productID] = parts }
            }
        }
        return layouts
    }
}

extension TabletFigure.Part {
    /// Reads one table entry, like `k4fL0 160-357`.
    init?(token: Substring) {
        let fields = token.split(separator: " ")
        guard fields.count == 2 else { return nil }
        var code = fields[0]
        let control: TabletFigure.Control
        switch code.popFirst() {
        case "k":
            let digits = code.prefix(while: \.isNumber)
            code = code.dropFirst(digits.count)
            guard let count = Int(digits), count > 0 else { return nil }
            switch code.popFirst() {
            case "f": control = .keys(count: count, shape: .short)
            case "s": control = .keys(count: count, shape: .square)
            case "w": control = .keys(count: count, shape: .long)
            default: return nil
            }
        case "c": control = .cluster
        case "r": control = .ring
        case "d": control = .dial
        case "s": control = .strip
        default: return nil
        }
        let side: TabletFigure.Side
        switch code.popFirst() {
        case "L": side = .left
        case "R": side = .right
        case "T": side = .top
        case "B": side = .bottom
        default: return nil
        }
        let span = fields[1].split(separator: "-")
        guard let lane = Int(code), span.count == 2,
              let start = Int(span[0]), let end = Int(span[1]), start < end
        else { return nil }
        self.init(control: control, side: side, lane: lane,
                  start: Double(start) / 1000, end: Double(end) / 1000)
    }
}

// MARK: - Orientation

extension TabletFigure {
    /// The figure as it looks with the tablet turned to `orientation`. Matches
    /// `DisplayMapper.orient`: portrait is a quarter turn counterclockwise.
    func oriented(_ orientation: TabletOrientation) -> TabletFigure {
        let turns: Int
        switch orientation {
        case .landscape: turns = 0
        case .portrait: turns = 1
        case .landscapeFlipped: turns = 2
        case .portraitFlipped: turns = 3
        }
        var figure = self
        for _ in 0..<turns { figure = figure.turnedCounterclockwise() }
        return figure
    }

    /// A quarter turn counterclockwise, taking a point (x, y) on the unit
    /// square to (y, 1 − x): the left edge becomes the bottom, read the same
    /// way, while the bottom and top edges reverse as they become the right
    /// and left.
    private func turnedCounterclockwise() -> TabletFigure {
        var figure = self
        // Turning reverses top and bottom runs, so targets would land on the wrong keys.
        figure.controls = nil
        figure.chin = chin.map { side in
            switch side {
            case .left: return .bottom
            case .bottom: return .right
            case .right: return .top
            case .top: return .left
            }
        }
        figure.parts = parts.map { part in
            var turned = part
            switch part.side {
            case .left: turned.side = .bottom
            case .right: turned.side = .top
            case .bottom, .top:
                turned.side = part.side == .bottom ? .right : .left
                turned.start = 1 - part.end
                turned.end = 1 - part.start
            }
            return turned
        }
        figure.surfaceMM = CGSize(width: surfaceMM.height, height: surfaceMM.width)
        return figure
    }
}

// MARK: - Layout

extension TabletFigure {
    enum Style {
        /// The quiet body behind the area editor, in real proportions.
        case bezel
        /// The orientation picture, drawn on a fixed grid.
        case glyph
        /// The list icon, simpler still, in whole points.
        case icon
    }

    struct Shape: Equatable {
        enum Kind: Equatable {
            case key, cluster, ring, dial, strip, mark
            /// A ring's center button, inside the ring's hole.
            case center
        }
        var kind: Kind
        var rect: CGRect
        /// The control it stands for, on a figure with `controls`.
        var target: ControlTarget? = nil
    }

    /// The figure laid out in points.
    struct Drawing: Equatable {
        var body: CGRect
        /// Glyph only: the outline's inner edge.
        var opening: CGRect
        var surface: CGRect
        /// One band per edge that holds controls.
        var bands: [CGRect]
        var shapes: [Shape]
        /// Points per unit: millimeters for the bezel, grid units for the
        /// glyph, and one for the icon.
        var unit: CGFloat

        static let empty = Drawing(body: .zero, opening: .zero, surface: .zero, bands: [], shapes: [], unit: 0)
    }

    /// Lays the figure out centered in `rect`. The bezel snaps its body and
    /// controls to `scale`'s pixel grid but leaves its surface exact, so the area
    /// editor lands on it. The glyph and icon keep to their own grids.
    func drawing(_ style: Style, in rect: CGRect, scale: CGFloat) -> Drawing {
        switch style {
        case .bezel: return bezel(in: rect, scale: scale)
        case .glyph: return glyph(in: rect)
        case .icon: return icon(in: rect)
        }
    }

    /// The four L-shaped corner marks of a tablet's surface, as eight bars.
    fileprivate static func cornerMarks(in r: CGRect, length: Double, thickness: Double) -> [Shape] {
        let corners = [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                       (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)]
        return corners.flatMap { x, y, dx, dy -> [Shape] in
            let across = CGRect(x: dx > 0 ? x : x - length, y: dy > 0 ? y : y - thickness, width: length, height: thickness)
            let down = CGRect(x: dx > 0 ? x : x - thickness, y: dy > 0 ? y : y - length, width: thickness, height: length)
            return [Shape(kind: .mark, rect: across), Shape(kind: .mark, rect: down)]
        }
    }
}

// MARK: - Hit testing

extension TabletFigure.Drawing {
    /// Most a hit area reaches past its shape, in points.
    static let hitSlop: CGFloat = 4

    /// Where each targeted key, strip, and center button answers a click: its
    /// shape, grown by up to `hitSlop` but never past half the gap to another
    /// targeted shape, so no two areas overlap. Rings and dials answer within
    /// their circle instead; see `target(at:)`.
    func hitAreas() -> [(target: ControlTarget, rect: CGRect)] {
        let targeted = shapes.filter { $0.target != nil }
        return targeted.compactMap { shape in
            guard let target = shape.target, shape.kind != .ring, shape.kind != .dial else { return nil }
            var reach = Self.hitSlop
            for other in targeted where other != shape {
                // A center sits inside its ring, which isn't a neighbor.
                if shape.kind == .center, other.kind == .ring || other.kind == .dial { continue }
                let a = shape.rect, b = other.rect
                let apart = max(b.minX - a.maxX, a.minX - b.maxX, b.minY - a.maxY, a.minY - b.maxY)
                reach = min(reach, max(apart, 0) / 2)
            }
            return (target, shape.rect.insetBy(dx: -reach, dy: -reach))
        }
    }

    /// The control under `point`, or nil. One pass over 20 or so shapes.
    func target(at point: CGPoint) -> ControlTarget? {
        for area in hitAreas() where area.rect.contains(point) { return area.target }
        for shape in shapes where shape.kind == .ring || shape.kind == .dial {
            guard let target = shape.target else { continue }
            let r = shape.rect
            if hypot(point.x - r.midX, point.y - r.midY) <= r.width / 2 { return target }
        }
        return nil
    }
}

// MARK: - Bezel

extension TabletFigure {
    /// The bezel's sizes in millimeters.
    private struct Metrics {
        /// Body edge to surface, on an edge without controls.
        var margin: Double
        /// Body edge to band.
        var inset: Double
        var band: Double
        /// A band with more than one lane.
        var wideBand: Double
        /// Extra margin on the chin's edge.
        var chin: Double
        /// Band to surface.
        var gutter: Double
        var keyDepth: Double
        /// The least gap between keys in a run.
        var keyGap: Double
        var partGap: Double
        var round: Double
        var stripDepth: Double
        var short: Double
        var square: Double
        var long: Double
    }

    /// Share of a ring's diameter its hole takes, as `TabletBezelView` draws it.
    static let ringHole = 1 - 2 * 0.27

    private var metrics: Metrics {
        let shortSide = min(surfaceMM.width, surfaceMM.height)
        let margin = isPenDisplay ? max(8, shortSide * 0.045) : max(9, shortSide * 0.07)
        let band = min(max(shortSide * 0.14, 18), 32)
        let key = band * 0.5
        return Metrics(
            margin: margin, inset: margin / 2, band: band, wideBand: band * 1.45, chin: margin * 1.2,
            gutter: margin / 2, keyDepth: key, keyGap: key * 0.2, partGap: key * 0.35, round: band * 0.82,
            stripDepth: band * 0.2, short: key * 0.75, square: key, long: key * 2.2)
    }

    private func laneCount(_ side: Side) -> Int {
        (parts.filter { $0.side == side }.map(\.lane).max() ?? -1) + 1
    }

    private func depths(_ m: Metrics) -> [Side: Double] {
        var depths: [Side: Double] = [:]
        for side in Side.allCases where laneCount(side) > 0 {
            depths[side] = laneCount(side) > 1 ? m.wideBand : m.band
        }
        return depths
    }

    /// How far in from the body's edge the surface starts.
    private func extent(_ side: Side, depths: [Side: Double], metrics m: Metrics) -> Double {
        if let depth = depths[side] { return m.inset + depth + m.gutter }
        return m.margin + (side == chin ? m.chin : 0)
    }

    /// The bezel's body in millimeters. The glyph takes its silhouette.
    private var bodyMM: CGSize {
        let m = metrics, depths = depths(m)
        func extent(_ side: Side) -> Double { self.extent(side, depths: depths, metrics: m) }
        return CGSize(width: surfaceMM.width + extent(.left) + extent(.right),
                      height: surfaceMM.height + extent(.top) + extent(.bottom))
    }

    private func bezel(in rect: CGRect, scale: CGFloat) -> Drawing {
        let m = metrics, depths = depths(m), size = bodyMM
        let unit = min(rect.width / size.width, rect.height / size.height)
        // Layout can propose nothing at first; draw nothing until it doesn't.
        guard unit > 0, unit.isFinite else { return .empty }
        let scale = max(scale, 1)
        func snap(_ v: Double) -> Double { (v * scale).rounded() / scale }
        /// A length in millimeters as whole pixels, never less than one.
        func pixels(_ mm: Double) -> Double { max((mm * unit * scale).rounded(), 1) / scale }
        func extent(_ side: Side) -> Double { self.extent(side, depths: depths, metrics: m) * unit }

        let exact = CGRect(x: rect.midX - size.width * unit / 2, y: rect.midY - size.height * unit / 2,
                           width: size.width * unit, height: size.height * unit)
        let surface = CGRect(
            x: exact.minX + extent(.left), y: exact.minY + extent(.top),
            width: exact.width - extent(.left) - extent(.right),
            height: exact.height - extent(.top) - extent(.bottom))
        // Whole pixels, so the outline lands crisply on the grid.
        let body = CGRect(x: snap(exact.minX), y: snap(exact.minY),
                          width: snap(exact.maxX) - snap(exact.minX), height: snap(exact.maxY) - snap(exact.minY))

        // Side bands run the body's height between insets; top and bottom
        // bands stop short of any side band.
        var bands: [Side: CGRect] = [:]
        let inset = m.inset * unit
        for side in Side.allCases {
            guard let mm = depths[side] else { continue }
            let depth = mm * unit
            switch side {
            case .left:
                bands[side] = CGRect(x: body.minX + inset, y: body.minY + inset, width: depth, height: body.height - 2 * inset)
            case .right:
                bands[side] = CGRect(x: body.maxX - inset - depth, y: body.minY + inset, width: depth, height: body.height - 2 * inset)
            case .top, .bottom:
                let x0 = depths[.left] != nil ? surface.minX : body.minX + inset
                let x1 = depths[.right] != nil ? surface.maxX : body.maxX - inset
                let y = side == .top ? body.minY + inset : body.maxY - inset - depth
                bands[side] = CGRect(x: x0, y: y, width: x1 - x0, height: depth)
            }
        }

        var shapes: [Shape] = []
        for side in Side.allCases {
            guard let band = bands[side] else { continue }
            let edgeParts = parts.indices.filter { parts[$0].side == side }.map { (index: $0, part: parts[$0]) }
            shapes += place(edgeParts, side: side, band: band, body: body,
                            metrics: m, unit: unit, pixels: pixels, snap: snap)
        }
        return Drawing(
            body: body, opening: body, surface: surface,
            bands: Side.allCases.compactMap { bands[$0] }, shapes: shapes, unit: unit)
    }

    /// Lays one edge's parts into its band, lane by lane.
    private func place(
        _ edgeParts: [(index: Int, part: Part)], side: Side, band: CGRect, body: CGRect, metrics m: Metrics, unit: Double,
        pixels: (Double) -> Double, snap: (Double) -> Double
    ) -> [Shape] {
        let vertical = side == .left || side == .right
        let laneCount = (edgeParts.map(\.part.lane).max() ?? 0) + 1
        // A lane of strips needs half the depth of one with keys.
        let weights = (0..<laneCount).map { lane in
            edgeParts.filter { $0.part.lane == lane }.allSatisfy { $0.part.control == .strip } ? 1.0 : 2.0
        }
        let bandDepth = vertical ? band.width : band.height
        let totalWeight = laneCount > 1 ? weights.reduce(0, +) : 1
        // Along the edge, from the body's top or left.
        let edgeStart = vertical ? body.minY : body.minX
        let edgeLength = (vertical ? body.height : body.width) / unit
        let lo = ((vertical ? band.minY : band.minX) - edgeStart) / unit + m.partGap
        let hi = ((vertical ? band.maxY : band.maxX) - edgeStart) / unit - m.partGap

        var shapes: [Shape] = []
        var laneOffset = 0.0
        for lane in 0..<laneCount {
            let laneDepth = bandDepth * (laneCount > 1 ? weights[lane] / totalWeight : 1)
            // Lane 0 sits against the body's edge.
            let fromEdge = laneOffset + laneDepth / 2
            laneOffset += laneDepth
            let laneCenter: Double
            switch side {
            case .left: laneCenter = band.minX + fromEdge
            case .right: laneCenter = band.maxX - fromEdge
            case .top: laneCenter = band.minY + fromEdge
            case .bottom: laneCenter = band.maxY - fromEdge
            }
            let items = edgeParts.filter { $0.part.lane == lane }.sorted { $0.part.start < $1.part.start }
                .map { size($0.part, controls: controls?[$0.index], edgeLength: edgeLength,
                            laneDepth: laneDepth / unit, metrics: m) }
            for item in arrange(items, lo: lo, hi: hi, edgeLength: edgeLength, metrics: m) {
                // Whole-pixel shapes, centered on where the part belongs.
                let length = item.drawnLength(pixels: pixels)
                let start = snap(edgeStart + (item.position + item.length / 2) * unit - length / 2)
                shapes += item.shapes(
                    at: start, side: side, laneCenter: laneCenter, laneDepth: laneDepth / unit,
                    metrics: m, unit: unit, pixels: pixels, snap: snap)
            }
        }
        return shapes
    }

    /// A part sized for the bezel, before it's placed.
    private struct Item {
        var part: Part
        /// Length along the edge, in millimeters.
        var length: Double
        var keyCount = 0
        var keyLength = 0.0
        var keyGap = 0.0
        var controls: PartControls? = nil
        /// A ring or dial's diameter, in millimeters, when keys sit beside it.
        var round = 0.0
        /// Where it starts along the edge, in millimeters, once placed.
        var position = 0.0

        /// Length along the edge in whole pixels, as `shapes` draws it.
        func drawnLength(pixels: (Double) -> Double) -> Double {
            guard case .keys = part.control else { return pixels(length) }
            return Double(keyCount) * pixels(keyLength) + Double(keyCount - 1) * pixels(keyGap)
        }

        /// The item's shapes, starting `start` points along the edge.
        func shapes(
            at start: Double, side: Side, laneCenter: Double, laneDepth: Double,
            metrics m: Metrics, unit: Double, pixels: (Double) -> Double, snap: (Double) -> Double
        ) -> [Shape] {
            let vertical = side == .left || side == .right
            func rect(from a: Double, length: Double, depth: Double) -> CGRect {
                let across = snap(laneCenter - depth / 2)
                return vertical
                    ? CGRect(x: across, y: a, width: depth, height: length)
                    : CGRect(x: a, y: across, width: length, height: depth)
            }
            let keyDepth = pixels(min(m.keyDepth, laneDepth * 0.8))
            switch (part.control, controls?.entry) {
            case let (.keys, .run(letters)?):
                let length = pixels(keyLength), gap = pixels(keyGap)
                return (0..<keyCount).map { i in
                    Shape(kind: .key, rect: rect(from: start + Double(i) * (length + gap), length: length, depth: keyDepth),
                          target: i < letters.count ? controls?.keys[letters[i]] : nil)
                }
            case (.keys, _):
                let length = pixels(keyLength), gap = pixels(keyGap)
                return (0..<keyCount).map { i in
                    Shape(kind: .key, rect: rect(from: start + Double(i) * (length + gap), length: length, depth: keyDepth))
                }
            case let (.cluster, .cluster(grid)?):
                let columns = grid.rows.first?.count ?? 1
                let depth = pixels(min(laneDepth * 0.8, m.keyDepth * Double(columns)))
                return gridShapes(grid, start: start, length: pixels(length), widths: Array(repeating: depth / Double(columns),
                                  count: columns), side: side, laneCenter: laneCenter, metrics: m, pixels: pixels, snap: snap)
            case (.cluster, _):
                return [Shape(kind: .cluster, rect: rect(from: start, length: pixels(length), depth: keyDepth))]
            case let (.ring, .ring(_, .beside(grid))?), let (.dial, .dial(_, .beside(grid))?):
                // Keys in their own columns, the ring or dial in the rest.
                let key = pixels(m.keyDepth * 0.6), d = pixels(round)
                let widths = (0..<(grid.rows.first?.count ?? 0)).map { c in
                    grid.rows.contains { $0[c] == .body } ? d : key
                }
                return gridShapes(grid, start: start, length: pixels(length), widths: widths, side: side,
                                  laneCenter: laneCenter, metrics: m, pixels: pixels, snap: snap)
            case (.ring, _), (.dial, _):
                let d = pixels(length)
                let ring = rect(from: start, length: d, depth: d)
                var shapes = [Shape(kind: part.control == .ring ? .ring : .dial, rect: ring, target: controls?.control)]
                // A center button where the ring's hole is big enough to press.
                if case let .ring(_, .center(letter))? = controls?.entry, let target = controls?.keys[letter],
                   ring.width * TabletFigure.ringHole >= 10 {
                    let c = pixels(length * 0.34)
                    let center = CGRect(x: snap(ring.midX - c / 2), y: snap(ring.midY - c / 2), width: c, height: c)
                    shapes.append(Shape(kind: .center, rect: center, target: target))
                }
                return shapes
            case (.strip, _):
                let depth = pixels(min(m.stripDepth, laneDepth * 0.6))
                return [Shape(kind: .strip, rect: rect(from: start, length: pixels(length), depth: depth),
                              target: controls?.control)]
            }
        }

        /// A grid's keys, and the ring or dial among them, in rows along the
        /// edge and columns of `widths` points from the edge inward, each key
        /// filling its cells less a gap.
        private func gridShapes(
            _ grid: TabletLayoutIdentity.Grid, start: Double, length: Double, widths: [Double], side: Side,
            laneCenter: Double, metrics m: Metrics, pixels: (Double) -> Double, snap: (Double) -> Double
        ) -> [Shape] {
            let vertical = side == .left || side == .right
            let gap = pixels(m.keyGap * 0.6)
            let rows = grid.rows.count
            let total = widths.reduce(0, +) + Double(widths.count - 1) * gap
            // Column edges from the body's edge inward, then in points across the lane.
            var columnStarts: [Double] = []
            var offset = 0.0
            for w in widths { columnStarts.append(offset); offset += w + gap }
            let towardEdge = side == .left || side == .top
            func across(_ c: Int) -> (Double, Double) {
                let a = towardEdge ? laneCenter - total / 2 + columnStarts[c]
                    : laneCenter + total / 2 - columnStarts[c] - widths[c]
                return (a, widths[c])
            }
            let rowLength = (length - Double(rows - 1) * gap) / Double(rows)
            func along(_ r: Int) -> (Double, Double) { (start + Double(r) * (rowLength + gap), rowLength) }
            func cell(_ r: Int, _ c: Int) -> CGRect {
                let (a, l) = along(r), (x, w) = across(c)
                return vertical ? CGRect(x: x, y: a, width: w, height: l) : CGRect(x: a, y: x, width: l, height: w)
            }
            func snapped(_ r: CGRect) -> CGRect {
                let x0 = snap(r.minX), y0 = snap(r.minY)
                // pixels(0) is one pixel, the least a side may be.
                return CGRect(x: x0, y: y0, width: max(snap(r.maxX) - x0, pixels(0)),
                              height: max(snap(r.maxY) - y0, pixels(0)))
            }

            var shapes: [Shape] = []
            var body = CGRect.null
            var keys: [(Character, CGRect)] = []
            for (r, row) in grid.rows.enumerated() {
                for (c, cellKind) in row.enumerated() {
                    switch cellKind {
                    case .empty: break
                    case .body: body = body.union(cell(r, c))
                    case let .key(letter):
                        if let i = keys.firstIndex(where: { $0.0 == letter }) {
                            keys[i].1 = keys[i].1.union(cell(r, c))
                        } else {
                            keys.append((letter, cell(r, c)))
                        }
                    }
                }
            }
            if !body.isNull, let kind: Shape.Kind = part.control == .ring ? .ring : part.control == .dial ? .dial : nil {
                let d = pixels(round)
                shapes.append(Shape(kind: kind, rect: snapped(CGRect(x: body.midX - d / 2, y: body.midY - d / 2,
                                                                     width: d, height: d)),
                                    target: controls?.control))
            }
            for (letter, r) in keys {
                // Cells that a key spans merge across the gaps between them.
                shapes.append(Shape(kind: .key, rect: snapped(r), target: controls?.keys[letter]))
            }
            return shapes
        }
    }

    private func size(_ part: Part, controls: PartControls?, edgeLength: Double, laneDepth: Double,
                      metrics m: Metrics) -> Item {
        var item = size(part, keepEveryKey: controls != nil, edgeLength: edgeLength, laneDepth: laneDepth, metrics: m)
        item.controls = controls
        switch (part.control, controls?.entry) {
        case let (.ring, .ring(_, .beside(grid))?), let (.dial, .dial(_, .beside(grid))?):
            // The ring shrinks to leave room for its keys' columns.
            let keyColumns = (grid.rows.first?.indices ?? 0..<0).filter { c in !grid.rows.contains { $0[c] == .body } }.count
            item.round = max(min(m.round, laneDepth * 0.92 - Double(keyColumns) * (m.keyDepth * 0.6 + m.keyGap * 0.6)),
                             m.keyDepth * 0.6)
            item.length = max(item.round, Double(grid.rows.count) * m.keyDepth * 0.6
                              + Double(grid.rows.count - 1) * m.keyGap * 0.6)
        default: break
        }
        return item
    }

    private func size(_ part: Part, keepEveryKey: Bool, edgeLength: Double, laneDepth: Double, metrics m: Metrics) -> Item {
        let span = (part.end - part.start) * edgeLength
        switch part.control {
        case let .keys(count, shape):
            let longest: Double
            switch shape {
            case .short: longest = m.short
            case .square: longest = m.square
            case .long: longest = m.long
            }
            // Keys spread across their span, no longer than their shape allows.
            let shortest = m.keyDepth * 0.3
            // A diagram keeps every key, so each lines up with its target.
            var shown = count
            while !keepEveryKey, shown > 1, Double(shown) * shortest + Double(shown - 1) * m.keyGap > span { shown -= 1 }
            let length = max(min(longest, (span - Double(shown - 1) * m.keyGap) / Double(shown)), shortest)
            let gap = shown > 1 ? max(m.keyGap, (span - Double(shown) * length) / Double(shown - 1)) : 0
            return Item(part: part, length: Double(shown) * length + Double(shown - 1) * gap,
                        keyCount: shown, keyLength: length, keyGap: gap)
        case .cluster:
            return Item(part: part, length: max(span, m.keyDepth * 0.6))
        case .ring, .dial:
            return Item(part: part, length: min(m.round, laneDepth * 0.92))
        case .strip:
            return Item(part: part, length: span)
        }
    }

    /// Places a lane's items between `lo` and `hi`, each centered where it
    /// belongs, with at least a part gap between neighbors.
    private func arrange(_ items: [Item], lo: Double, hi: Double, edgeLength: Double, metrics m: Metrics) -> [Item] {
        guard !items.isEmpty else { return [] }
        var items = items
        let gaps = Double(items.count - 1) * m.partGap
        let content = items.map(\.length).reduce(0, +)
        if content + gaps > hi - lo, content > 0 {
            // Too long for the band: shrink every part in proportion.
            let shrink = max((hi - lo - gaps) / content, 0.2)
            for i in items.indices {
                items[i].length *= shrink
                items[i].keyLength *= shrink
                items[i].keyGap *= shrink
            }
        }
        for i in items.indices {
            items[i].position = (items[i].part.start + items[i].part.end) / 2 * edgeLength - items[i].length / 2
        }
        // Push apart forward, then pull back from the far end.
        for i in items.indices {
            let floor = i == 0 ? lo : items[i - 1].position + items[i - 1].length + m.partGap
            items[i].position = max(items[i].position, floor)
        }
        for i in items.indices.reversed() {
            let ceiling = i == items.count - 1 ? hi : items[i + 1].position - m.partGap
            items[i].position = max(min(items[i].position, ceiling - items[i].length), lo)
        }
        return items
    }
}

// MARK: - Glyph

extension TabletFigure {
    /// The glyph's grid. A unit is a hundredth of the glyph's long side: half
    /// a point in the orientation picker's 50-point frame, so one pixel at 2x.
    /// Every length is a whole number of units, so every edge lands on a pixel
    /// and spacing is identical in every orientation.
    private enum Grid {
        static let side = 100
        static let outline = 3
        /// Outline to panels, and band to surface.
        static let gap = 3
        /// Outline to screen on a figure with no controls, which has no bands
        /// to give it structure.
        static let bezel = 6
        /// Extra bezel on the chin's edge.
        static let chin = 6
        static let band = 18
        /// A band thinned to keep the surface in shape.
        static let thinBand = 14
        /// Between shapes along a band.
        static let spacing = 4
        /// Beside a circle, whose curve reads as farther away.
        static let roundSpacing = 3
        /// Band ends to the first and last shapes.
        static let clearance = 3
        static let markLength = 10
        static let markThickness = 3
        static let markInset = 5
        /// Short sides come in these steps, so near twins draw alike.
        static let step = 6
    }

    /// The glyph body's size in grid units, and each banded edge's depth.
    private func glyphFrame() -> (width: Int, height: Int, depths: [Side: Int]) {
        var depths: [Side: Int] = [:]
        for side in Side.allCases where parts.contains(where: { $0.side == side }) { depths[side] = Grid.band }
        let aspect = surfaceMM.width / max(surfaceMM.height, 1)
        let short: Int, wide: Bool
        if parts.isEmpty {
            // The screen is the whole likeness, so the bezel wraps its real shape.
            let ratio = min(max(max(aspect, 1 / aspect), 1.25), 1.8)
            let frame = 2 * (Grid.outline + Grid.bezel)
            let screen = Int((Double(Grid.side - frame) / ratio / 2).rounded()) * 2
            short = screen + frame + (chin == nil ? 0 : Grid.chin)
            wide = aspect >= 1
        } else {
            // A figure with controls takes the bezel's silhouette, which also
            // settles which way a square surface faces.
            let body = bodyMM
            let ratio = min(max(max(body.width, body.height) / min(body.width, body.height), 1.28), 1.85)
            short = Int((Double(Grid.side) / ratio / Double(Grid.step)).rounded()) * Grid.step
            wide = body.width >= body.height
        }
        let (width, height) = wide ? (Grid.side, short) : (short, Grid.side)

        // Bands are exaggerated; thin the ones that would squeeze the surface
        // past the square root of its real aspect.
        func extent(_ side: Side) -> Int { glyphExtent(side, depths: depths) }
        let w = Double(width - extent(.left) - extent(.right))
        let h = Double(height - extent(.top) - extent(.bottom))
        for side in (w / h < aspect.squareRoot() ? [Side.left, .right] : [.top, .bottom]) where depths[side] != nil {
            depths[side] = Grid.thinBand
        }
        return (width, height, depths)
    }

    /// How far in from the body's edge the surface starts, in grid units.
    private func glyphExtent(_ side: Side, depths: [Side: Int]) -> Int {
        if let depth = depths[side] { return Grid.outline + Grid.gap + depth + Grid.gap }
        if !parts.isEmpty { return Grid.outline + Grid.gap }
        return Grid.outline + Grid.bezel + (side == chin ? Grid.chin : 0)
    }

    /// A part as glyph shapes along its band, in grid units.
    private struct GlyphItem {
        var part: Part
        var kind: Shape.Kind
        var count = 1
        /// One shape's length along the band and depth across it.
        var along: Int
        var across: Int
        /// Where the first shape starts along the band, once placed.
        var position = 0

        var round: Bool { kind == .ring || kind == .dial }
        var length: Int { count * along + (count - 1) * Grid.spacing }
    }

    /// Glyph vocabulary: flat keys are bars as wide as a ring is round, so a
    /// column of keys and a ring reads as one; square keys and clusters are
    /// squares; strips are pills thick enough to read.
    private func glyphItem(_ part: Part, column: Int, edgeLength: Int) -> GlyphItem {
        let span = (part.end - part.start) * Double(edgeLength)
        switch part.control {
        case let .keys(count, shape):
            let size: (along: Int, across: Int)
            switch shape {
            case .short: size = (4, column)
            case .square: size = (column - 2, column - 2)
            case .long: size = (14, column - 2)
            }
            // As many keys as the span holds, with some slack, and never
            // fewer than two, so a family reads alike at any size.
            var shown = count
            while shown > min(count, 2), Double(shown * size.along + (shown - 1) * Grid.spacing) > span * 1.1 {
                shown -= 1
            }
            return GlyphItem(part: part, kind: .key, count: shown, along: size.along, across: size.across)
        case .cluster: return GlyphItem(part: part, kind: .cluster, along: column, across: column)
        case .ring: return GlyphItem(part: part, kind: .ring, along: column, across: column)
        case .dial: return GlyphItem(part: part, kind: .dial, along: column, across: column)
        case .strip: return GlyphItem(part: part, kind: .strip, along: 20, across: 6)
        }
    }

    private static func spacing(_ a: GlyphItem, _ b: GlyphItem) -> Int {
        a.round || b.round ? Grid.roundSpacing : Grid.spacing
    }

    /// Places a band's items between `lo` and `hi`. Neighbors that sit close
    /// on the tablet chain together, and chains less than a quarter of the
    /// band apart join, so a band reads as one evenly spaced row unless its
    /// groups are clearly apart; each chain centers where its parts belong.
    private func arrangeGlyph(_ items: [GlyphItem], lo: Int, hi: Int, edgeLength: Int) -> [GlyphItem] {
        guard !items.isEmpty else { return [] }
        var items = items
        func total() -> Int {
            items.map(\.length).reduce(0, +)
                + zip(items, items.dropFirst()).map { Self.spacing($0, $1) }.reduce(0, +)
        }
        // Too long for the band: fewer keys, from the longest run; then long
        // keys turn square and strips shorten; then neighboring clusters
        // merge; and only then do shapes at the end drop.
        while total() > hi - lo,
              let i = items.indices.filter({ items[$0].count > 1 }).max(by: { items[$0].count < items[$1].count }) {
            items[i].count -= 1
        }
        if total() > hi - lo {
            for i in items.indices where items[i].kind == .key { items[i].along = min(items[i].along, items[i].across) }
        }
        for i in items.indices where items[i].kind == .strip && total() > hi - lo {
            items[i].along = max(12, items[i].along - (total() - (hi - lo)))
        }
        while total() > hi - lo,
              let i = items.indices.dropLast().first(where: { items[$0].kind == .cluster && items[$0 + 1].kind == .cluster }) {
            items.remove(at: i + 1)
        }
        while total() > hi - lo, items.count > 1 { items.removeLast() }

        var chains: [[Int]] = []
        for i in items.indices {
            if let last = chains.last?.last, items[i].part.start - items[last].part.end < 0.12 {
                chains[chains.count - 1].append(i)
            } else {
                chains.append([i])
            }
        }
        func length(_ chain: [Int]) -> Int {
            chain.map { items[$0].length }.reduce(0, +)
                + zip(chain, chain.dropFirst()).map { Self.spacing(items[$0], items[$1]) }.reduce(0, +)
        }
        func center(_ chain: [Int]) -> Double {
            (items[chain.first!].part.start + items[chain.last!].part.end) / 2 * Double(edgeLength)
        }
        var lengths = chains.map(length)
        var starts = chains.indices.map { center(chains[$0]) - Double(lengths[$0]) / 2 }
        func resolve() {
            for c in chains.indices {
                let floor = c == 0 ? Double(lo) : starts[c - 1] + Double(lengths[c - 1] + Grid.spacing)
                starts[c] = max(starts[c], floor)
            }
            for c in chains.indices.reversed() {
                let ceiling = c == chains.count - 1 ? Double(hi) : starts[c + 1] - Double(Grid.spacing)
                starts[c] = max(min(starts[c], ceiling - Double(lengths[c])), Double(lo))
            }
        }
        resolve()
        let apart = max(Double(2 * Grid.spacing), Double(hi - lo) / 4)
        var joined = true
        while joined {
            joined = false
            for c in chains.indices.dropLast() where starts[c + 1] - starts[c] - Double(lengths[c]) < apart {
                let middle = (starts[c] + starts[c + 1] + Double(lengths[c + 1])) / 2
                chains[c] += chains.remove(at: c + 1)
                lengths.remove(at: c + 1)
                starts.remove(at: c + 1)
                lengths[c] = length(chains[c])
                starts[c] = middle - Double(lengths[c]) / 2
                resolve()
                joined = true
                break
            }
        }

        // A chain sitting about mid-edge centers exactly, so a ring there
        // lands on the centerline with its keys balanced above and below.
        let middle = Double(lo + hi) / 2
        for c in chains.indices where abs(starts[c] + Double(lengths[c]) / 2 - middle) < Double(edgeLength) / 10 {
            starts[c] = middle - Double(lengths[c]) / 2
        }
        resolve()

        var placed: [GlyphItem] = []
        for (c, chain) in chains.enumerated() {
            var position = Int(starts[c].rounded())
            for (k, i) in chain.enumerated() {
                if k > 0 { position += Self.spacing(items[chain[k - 1]], items[i]) }
                var item = items[i]
                item.position = position
                position += item.length
                placed.append(item)
            }
        }
        return placed
    }

    private func glyph(in rect: CGRect) -> Drawing {
        let (w, h, depths) = glyphFrame()
        let unit = min(rect.width, rect.height) / Double(Grid.side)
        guard unit > 0, unit.isFinite else { return .empty }
        // Both sides are even, so centering leaves whole units on each side.
        let ox = rect.midX - Double(w) * unit / 2, oy = rect.midY - Double(h) * unit / 2
        func r(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
            CGRect(x: ox + Double(x) * unit, y: oy + Double(y) * unit, width: Double(width) * unit, height: Double(height) * unit)
        }
        func extent(_ side: Side) -> Int { glyphExtent(side, depths: depths) }
        let (left, right, top, bottom) = (extent(.left), extent(.right), extent(.top), extent(.bottom))
        let edge = Grid.outline + Grid.gap

        var bands: [Side: (x: Int, y: Int, width: Int, height: Int)] = [:]
        for side in Side.allCases {
            guard let d = depths[side] else { continue }
            switch side {
            case .left: bands[side] = (edge, edge, d, h - 2 * edge)
            case .right: bands[side] = (w - edge - d, edge, d, h - 2 * edge)
            case .top, .bottom:
                let x0 = depths[.left] != nil ? left : edge
                let x1 = depths[.right] != nil ? w - right : w - edge
                bands[side] = (x0, side == .top ? edge : h - edge - d, x1 - x0, d)
            }
        }

        var shapes: [Shape] = []
        for side in Side.allCases {
            guard let band = bands[side], let depth = depths[side] else { continue }
            let vertical = side == .left || side == .right
            let column = depth == Grid.band ? 10 : 8
            let edgeLength = vertical ? h : w
            let start = vertical ? band.y : band.x, length = vertical ? band.height : band.width
            let acrossStart = vertical ? band.x : band.y
            // One column per band: strips lead where they share a stretch with keys.
            let items = parts.filter { $0.side == side }
                .sorted { ($0.start, $0.control == .strip ? 0 : 1) < ($1.start, $1.control == .strip ? 0 : 1) }
                .map { glyphItem($0, column: column, edgeLength: edgeLength) }
            let placed = arrangeGlyph(items, lo: start + Grid.clearance, hi: start + length - Grid.clearance,
                                      edgeLength: edgeLength)
            for item in placed {
                let across = acrossStart + (depth - item.across) / 2
                for k in 0..<item.count {
                    let along = item.position + k * (item.along + Grid.spacing)
                    let frame = vertical ? r(across, along, item.across, item.along) : r(along, across, item.along, item.across)
                    shapes.append(Shape(kind: item.kind, rect: frame))
                }
            }
        }

        let surface = r(left, top, w - left - right, h - top - bottom)
        if !isPenDisplay {
            let inset = Double(Grid.markInset) * unit
            shapes += Self.cornerMarks(in: surface.insetBy(dx: inset, dy: inset),
                                       length: Double(Grid.markLength) * unit,
                                       thickness: Double(Grid.markThickness) * unit)
        }
        return Drawing(
            body: r(0, 0, w, h),
            opening: r(Grid.outline, Grid.outline, w - 2 * Grid.outline, h - 2 * Grid.outline),
            surface: surface,
            bands: Side.allCases.compactMap { side in bands[side].map { r($0.x, $0.y, $0.width, $0.height) } },
            shapes: shapes, unit: unit)
    }
}

// MARK: - Icon

extension TabletFigure {
    /// The icon's grid. A unit is half a point, one pixel at 2x. Panels take
    /// even sizes so their edges land on whole points at 1x too; controls may
    /// sit on any unit.
    private enum IconGrid {
        static let outline = 2
        static let gap = 2
        static let band = 10
        /// Across a band, every shape, leaving two units each side.
        static let shape = 6
        /// Between shapes in a group.
        static let spacing = 2
        /// The least room between groups, so separate groups stay apart.
        static let groupGap = 4
        /// Band ends to the first and last shapes.
        static let clearance = 2
        /// Extra bezel on the chin's edge.
        static let chin = 2
        /// Long sides for the smallest and largest tablets, so size reads too.
        static let shortest = 44, longest = 56
    }

    /// How far in from the body's edge the surface starts, in grid units.
    private func iconExtent(_ side: Side) -> Int {
        let g = IconGrid.self
        if parts.contains(where: { $0.side == side }) { return g.outline + 2 * g.gap + g.band }
        return g.outline + g.gap + (side == chin ? g.chin : 0)
    }

    /// A list icon: the glyph's outline and panels with simpler controls,
    /// sized by the tablet's physical size. Lanes merge and corner marks drop.
    private func icon(in rect: CGRect) -> Drawing {
        let g = IconGrid.self
        let unit = 0.5
        func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
        let body = bodyMM
        let (lowest, highest) = parts.isEmpty ? (1.25, 1.8) : (1.28, 1.85)
        let ratio = min(max(max(body.width, body.height) / min(body.width, body.height), lowest), highest)
        let wide = body.width >= body.height
        let room = (along: Int((wide ? rect.width : rect.height) / unit), across: Int((wide ? rect.height : rect.width) / unit))
        let size = max(surfaceMM.width, surfaceMM.height)
        var long = even(Double(g.shortest) + Double(g.longest - g.shortest) * min(max((size - 150) / 380, 0), 1))
        long = min(long, room.along / 2 * 2, even(Double(room.across) * ratio))
        // Bands on both long sides would crush the surface; the body deepens
        // and lengthens instead.
        let across = wide ? iconExtent(.top) + iconExtent(.bottom) : iconExtent(.left) + iconExtent(.right)
        let short = min(max(even(Double(long) / ratio), across + 12), room.across / 2 * 2)
        long = max(long, min(even(Double(short) * 1.25), room.along / 2 * 2))
        var (w, h) = wide ? (long, short) : (short, long)
        // Room for each band's shapes at their preferred sizes, groups apart:
        // the body grows up to two points before any key drops, so size
        // still reads.
        func preferred(_ side: Side) -> Int {
            let items = iconItems(parts.filter { $0.side == side })
            guard !items.isEmpty else { return 0 }
            let gaps = zip(items, items.dropFirst()).map { $1.part.start - $0.part.end < 0.12 ? g.spacing : g.groupGap }
            return items.map(\.length).reduce(0, +) + gaps.reduce(0, +) + 2 * g.clearance
        }
        let edge = g.outline + g.gap
        let sideBands = (left: parts.contains { $0.side == .left }, right: parts.contains { $0.side == .right })
        let needH = max(preferred(.left), preferred(.right)) + 2 * edge
        let needW = max(preferred(.top), preferred(.bottom))
            + (sideBands.left ? iconExtent(.left) : edge) + (sideBands.right ? iconExtent(.right) : edge)
        let roomW = Int(rect.width / unit) / 2 * 2, roomH = Int(rect.height / unit) / 2 * 2
        h = min(max(h, min((needH + 1) / 2 * 2, h + 4)), roomH)
        w = min(max(w, min((needW + 1) / 2 * 2, w + 4)), roomW)
        // Still a tablet's shape: the long side keeps a quarter's lead.
        if wide {
            w = max(w, min(even(Double(h) * 1.25), roomW))
            h = min(h, even(Double(w) / 1.25))
        } else {
            h = max(h, min(even(Double(w) * 1.25), roomH))
            w = min(w, even(Double(h) / 1.25))
        }
        guard w > 0, h > 0 else { return .empty }
        // Whole points, so panels stay on the 1x grid.
        let ox = (rect.midX - Double(w) * unit / 2).rounded(), oy = (rect.midY - Double(h) * unit / 2).rounded()
        func r(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> CGRect {
            CGRect(x: ox + Double(x) * unit, y: oy + Double(y) * unit, width: Double(width) * unit, height: Double(height) * unit)
        }
        let (left, right, top, bottom) = (iconExtent(.left), iconExtent(.right), iconExtent(.top), iconExtent(.bottom))
        let banded = Set(parts.map(\.side))

        var bands: [CGRect] = []
        var shapes: [Shape] = []
        for side in Side.allCases where banded.contains(side) {
            let vertical = side == .left || side == .right
            let band: (x: Int, y: Int, width: Int, height: Int)
            switch side {
            case .left: band = (edge, edge, g.band, h - 2 * edge)
            case .right: band = (w - edge - g.band, edge, g.band, h - 2 * edge)
            case .top, .bottom:
                let x0 = banded.contains(.left) ? left : edge
                let x1 = banded.contains(.right) ? w - right : w - edge
                band = (x0, side == .top ? edge : h - edge - g.band, x1 - x0, g.band)
            }
            bands.append(r(band.x, band.y, band.width, band.height))
            let start = vertical ? band.y : band.x
            let length = vertical ? band.height : band.width
            let acrossStart = (vertical ? band.x : band.y) + (g.band - g.shape) / 2
            for item in arrangeIcon(parts.filter { $0.side == side }, lo: start + g.clearance,
                                    hi: start + length - g.clearance, edgeLength: vertical ? h : w) {
                shapes.append(Shape(kind: item.kind, rect: vertical
                    ? r(acrossStart, item.start, g.shape, item.length)
                    : r(item.start, acrossStart, item.length, g.shape)))
            }
        }
        return Drawing(
            body: r(0, 0, w, h),
            opening: r(g.outline, g.outline, w - 2 * g.outline, h - 2 * g.outline),
            surface: r(left, top, w - left - right, h - top - bottom),
            bands: bands, shapes: shapes, unit: unit)
    }

    /// An icon shape along its band, in grid units.
    private struct IconItem {
        var part: Part
        var kind: Shape.Kind
        var count = 1
        /// One shape's length along the band.
        var along: Int
        var start = 0
        var length: Int { count * along + (count - 1) * IconGrid.spacing }
    }

    /// A band's shapes at their preferred sizes, in order along it.
    private func iconItems(_ edgeParts: [Part]) -> [IconItem] {
        let g = IconGrid.self
        return edgeParts
            .sorted { ($0.start, $0.control == .strip ? 0 : 1) < ($1.start, $1.control == .strip ? 0 : 1) }
            .map { part in
                switch part.control {
                case .ring, .dial: return IconItem(part: part, kind: .dial, along: g.shape)
                case .cluster: return IconItem(part: part, kind: .cluster, along: g.shape)
                case .strip: return IconItem(part: part, kind: .strip, along: 12)
                case let .keys(count, shape):
                    switch shape {
                    case .short: return IconItem(part: part, kind: .key, count: min(count, 2), along: 2)
                    case .square: return IconItem(part: part, kind: .cluster, count: min(count, 2), along: g.shape)
                    case .long: return IconItem(part: part, kind: .key, count: min(count, 4), along: 8)
                    }
                }
            }
    }

    /// One edge's controls between `lo` and `hi`. Rings and dials are dots,
    /// clusters squares, and strips pills; flat and square keys show two to a
    /// run, and long keys up to four, where they fit. Groups that sit apart on the tablet stay apart, and positions
    /// round evenly about the band's middle, so mirrored layouts stay mirrored.
    private func arrangeIcon(_ edgeParts: [Part], lo: Int, hi: Int, edgeLength: Int) -> [(kind: Shape.Kind, start: Int, length: Int)] {
        let g = IconGrid.self
        var items = iconItems(edgeParts)
        func span(_ list: [IconItem]) -> Int {
            list.map(\.length).reduce(0, +) + max(list.count - 1, 0) * g.spacing
        }
        // Too long: runs lose keys, longest first, then long keys and strips
        // shorten, and only then do shapes at the end drop.
        while span(items) > hi - lo, let most = items.map(\.count).max(), most > 1 {
            for i in items.indices where items[i].count == most { items[i].count -= 1 }
        }
        while span(items) > hi - lo, let longest = items.filter({ $0.kind != .dial && $0.along > g.shape }).map(\.along).max() {
            for i in items.indices where items[i].along == longest { items[i].along -= 2 }
        }
        while span(items) > hi - lo, items.count > 1 { items.removeLast() }
        guard !items.isEmpty else { return [] }

        // Groups: neighbors that sit close on the tablet.
        var groups: [[Int]] = []
        for i in items.indices {
            if let last = groups.last?.last, items[i].part.start - items[last].part.end < 0.12 {
                groups[groups.count - 1].append(i)
            } else {
                groups.append([i])
            }
        }
        let middle = Double(lo + hi) / 2
        // Rounding away from the middle treats both halves alike.
        func place(_ center: Double, _ length: Int) -> Int {
            let offset = center - middle - Double(length) / 2
            return Int(middle) + Int(offset.rounded(.toNearestOrAwayFromZero))
        }
        func center(_ group: [Int]) -> Double {
            (items[group.first!].part.start + items[group.last!].part.end) / 2 * Double(edgeLength)
        }
        let lengths = groups.map { span($0.map { items[$0] }) }
        var starts = groups.indices.map { place(center(groups[$0]), lengths[$0]) }
        // Groups too close to read apart push away from each other evenly.
        for k in groups.indices.dropLast() where starts[k + 1] - starts[k] - lengths[k] < g.groupGap {
            let need = g.groupGap - (starts[k + 1] - starts[k] - lengths[k])
            starts[k] -= (need + 1) / 2
            starts[k + 1] += (need + 1) / 2
        }
        // A group about mid-edge centers exactly.
        for k in groups.indices where abs(Double(starts[k]) + Double(lengths[k]) / 2 - middle) < Double(edgeLength) / 10 {
            starts[k] = place(middle, lengths[k])
        }
        // Keep inside the band, from both ends.
        for k in groups.indices {
            starts[k] = max(starts[k], k == 0 ? lo : starts[k - 1] + lengths[k - 1] + g.groupGap)
        }
        for k in groups.indices.reversed() {
            starts[k] = max(min(starts[k], (k == groups.count - 1 ? hi : starts[k + 1] - g.groupGap) - lengths[k]), lo)
        }

        var placed: [(kind: Shape.Kind, start: Int, length: Int)] = []
        for (k, group) in groups.enumerated() {
            var position = starts[k]
            for i in group {
                for _ in 0..<items[i].count {
                    placed.append((items[i].kind, position, items[i].along))
                    position += items[i].along + g.spacing
                }
            }
        }
        return placed
    }
}
