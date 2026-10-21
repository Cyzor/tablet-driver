// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import TabletKit
import Testing

@Suite("Tablet figure with controls")
struct TabletFigureControlsTests {
    /// Every model with a map, drawn with its controls.
    private static let figures: [(name: String, map: TabletControlMap, figure: TabletFigure)] =
        WacomDeviceRegistry.knownDevices.compactMap { spec in
            guard spec.maxX > 0, spec.maxY > 0,
                  let map = TabletControlMap.forDevice(productID: spec.productID, spec: spec)
            else { return nil }
            let mm = spec.activeWidthMM.flatMap { w in spec.activeHeightMM.map { CGSize(width: w, height: $0) } }
            var figure = TabletFigure(layoutProductID: spec.productID, surfaceMM: mm,
                                      aspect: Double(spec.maxX) / Double(spec.maxY), isPenDisplay: spec.isPenDisplay)
            figure.controls = map.parts
            return (spec.name, map, figure)
        }

    /// The Tablet Area and Touch panes' bezel sizes, and a diagram-sized row.
    private static let frames = [CGRect(x: 2, y: 2, width: 516, height: 196), CGRect(x: 2, y: 2, width: 296, height: 196),
                                 CGRect(x: 2, y: 2, width: 596, height: 196)]

    private static func drawings() -> [(name: String, map: TabletControlMap, drawing: TabletFigure.Drawing, scale: CGFloat)] {
        figures.flatMap { f in
            frames.flatMap { frame in
                [1.0, 2.0].map { scale in
                    ("\(f.name) \(Int(frame.width))×\(Int(frame.height)) @\(Int(scale))x", f.map,
                     f.figure.drawing(.bezel, in: frame, scale: scale), scale)
                }
            }
        }
    }

    @Test("Every key is drawn once, tagged with its target")
    func everyKeyOnce() {
        #expect(!Self.figures.isEmpty)
        for (name, map, d, _) in Self.drawings() {
            let drawn = d.shapes.compactMap(\.target)
            #expect(Set(drawn).count == drawn.count, "\(name): no target twice")
            // A ring's center button shows only where its hole is big enough.
            let optional = Set(d.shapes.filter { $0.kind == .center }.compactMap(\.target))
                .union(map.parts.compactMap { part -> ControlTarget? in
                    if case let .ring(_, .center(letter)) = part.entry { return part.keys[letter] }
                    return nil
                })
            #expect(Set(drawn).subtracting(map.targets).isEmpty, "\(name): nothing drawn that isn't mapped")
            #expect(Set(map.targets).subtracting(drawn).subtracting(optional).isEmpty,
                    "\(name): missing \(Set(map.targets).subtracting(drawn).subtracting(optional))")
        }
    }

    @Test("Shapes stay in their bands, apart, and on whole pixels")
    func geometry() {
        for (name, _, d, scale) in Self.drawings() {
            let slack = 1 / scale
            let shapes = d.shapes.filter { $0.kind != .mark }
            for (i, a) in shapes.enumerated() {
                #expect(d.bands.contains { $0.insetBy(dx: -slack, dy: -slack).contains(a.rect) }, "\(name): \(a.kind) in a band")
                let r = a.rect
                #expect([r.minX, r.minY, r.maxX, r.maxY].allSatisfy { abs(($0 * scale).rounded() - $0 * scale) < 1e-6 },
                        "\(name): \(a.kind) on whole pixels \(r)")
                for b in shapes[(i + 1)...] {
                    // A center sits inside its ring or pad; a pad's keys share its circle.
                    if a.kind == .center || b.kind == .center { continue }
                    if case .wedge = a.kind, case .wedge = b.kind, a.rect == b.rect { continue }
                    let overlap = a.rect.intersection(b.rect)
                    #expect(overlap.isNull || overlap.width * overlap.height <= slack * slack / 4,
                            "\(name): \(a.kind) and \(b.kind) apart")
                }
            }
        }
    }

    @Test("Clicks land on the control under them")
    func hits() {
        for (name, _, d, _) in Self.drawings() {
            let areas = d.hitAreas()
            for (i, a) in areas.enumerated() {
                for b in areas[(i + 1)...] {
                    let overlap = a.rect.intersection(b.rect)
                    #expect(overlap.isNull || overlap.width * overlap.height < 1e-9, "\(name): \(a.target) and \(b.target) overlap")
                }
            }
            for shape in d.shapes {
                guard let target = shape.target else { continue }
                let r = shape.rect
                // A ring's middle may be its center button; aim at its band, and
                // at the middle of a pad key's quarter.
                let point: CGPoint
                switch shape.kind {
                case .ring, .dial: point = CGPoint(x: r.midX, y: r.minY + r.height * 0.1)
                case let .wedge(direction):
                    point = CGPoint(x: r.midX + cos(direction) * r.width * 0.35, y: r.midY + sin(direction) * r.width * 0.35)
                default: point = CGPoint(x: r.midX, y: r.midY)
                }
                #expect(d.target(at: point) == target, "\(name): \(shape.kind) answers for \(target)")
            }
            #expect(d.target(at: CGPoint(x: d.surface.midX, y: d.surface.midY)) == nil, "\(name): the surface answers nothing")
        }
    }

    @Test("A four-way cluster draws as a round pad the size of the dials")
    func pads() throws {
        let ptk = try #require(Self.figures.first { $0.name.contains("PTK-870") }?.figure)
        let d = ptk.drawing(.bezel, in: Self.frames[0], scale: 2)
        let wedges = d.shapes.filter { if case .wedge = $0.kind { return true } else { return false } }
        #expect(wedges.count == 8, "four keys around each of two pads")
        let dials = d.shapes.filter { $0.kind == .dial }
        #expect(dials.count == 2 && wedges.allSatisfy { w in dials.allSatisfy { abs($0.rect.width - w.rect.width) < 1 } },
                "pads and dials share one size")
        #expect(d.shapes.filter { $0.kind == .center }.compactMap(\.target) == [.ringCenter(0), .ringCenter(1)],
                "each pad's center is its dial's toggle")
    }

    @Test("The Pro 2 shows its ring's center, and the 24HD its mode keys")
    func specialKeys() throws {
        let frame = Self.frames[0]
        let pro = try #require(Self.figures.first { $0.name.contains("PTH-660") }?.figure)
        // A diagram 180 points tall leaves the ring's hole room for its center.
        let d = pro.drawing(.bezel, in: CGRect(x: 0, y: 0, width: 800, height: 180), scale: 2)
        #expect(d.shapes.contains { $0.kind == .center && $0.target == .ringCenter(0) })
        let hd = try #require(Self.figures.first { $0.name.contains("DTK-2400") }?.figure)
        let keys = hd.drawing(.bezel, in: frame, scale: 2).shapes.compactMap(\.target)
        #expect(keys.contains(.expressKey(0)) && keys.contains(.expressKey(10)) && keys.contains(.ring(1)))
    }

    @Test("Keys keep their distance from a centered ring, the same on both sides")
    func ringSpacing() throws {
        let pro = try #require(Self.figures.first { $0.name.contains("PTH-660") }?.figure)
        for scale in [1.0, 2.0] {
            let d = pro.drawing(.bezel, in: CGRect(x: 2, y: 2, width: 596, height: 196), scale: scale)
            let ring = try #require(d.shapes.first { $0.kind == .ring }).rect
            let keys = d.shapes.filter { $0.kind == .key }.map(\.rect)
            let above = ring.minY - (keys.filter { $0.maxY <= ring.minY }.map(\.maxY).max() ?? 0)
            let below = (keys.filter { $0.minY >= ring.maxY }.map(\.minY).min() ?? 0) - ring.maxY
            #expect(abs(above - below) < 1 / scale + 1e-9, "mirrored about the ring: \(above) above, \(below) below")
            #expect(min(above, below) >= 3 * d.grid - 1e-9, "at least three grid steps from the ring")
        }
    }

    @Test("A center button sits exactly in the middle of its ring or pad")
    func centersCentered() {
        for (name, _, d, _) in Self.drawings() {
            for c in d.shapes where c.kind == .center {
                guard let outer = d.shapes.first(where: {
                    $0.kind != .center && $0.rect.width > c.rect.width && $0.rect.contains(CGPoint(x: c.rect.midX, y: c.rect.midY))
                }) else { continue }
                #expect(abs(c.rect.midX - outer.rect.midX) < 1e-9 && abs(c.rect.midY - outer.rect.midY) < 1e-9, "\(name)")
            }
        }
    }

    @Test("Layouts libwacom lacks stay clear of Wacom's product IDs")
    func extrasStayClear() {
        let wacom = TabletFigure.parseLayouts(TabletLayoutTable.packed)
        for id in TabletLayoutExtras.productIDs {
            #expect(WacomDeviceRegistry.spec(for: id) == nil && wacom[id] == nil, "\(String(id, radix: 16)) is Wacom's")
            #expect(TabletFigure.layouts[id] != nil && TabletLayoutIdentity.all[id] != nil, "\(String(id, radix: 16)) reads")
        }
    }

    @Test("The Xencelabs Pen Display 24 draws its three bezel buttons")
    func xencelabsBezelButtons() throws {
        let parts = try #require(TabletControlMap.figureControls(productID: 0x520D))
        var figure = TabletFigure(layoutProductID: 0x520D, surfaceMM: CGSize(width: 527.04, height: 296.46),
                                  aspect: 105_000 / 59_000, isPenDisplay: true)
        figure.controls = parts
        for frame in Self.frames {
            for scale in [1.0, 2.0] {
                let d = figure.drawing(.bezel, in: frame, scale: scale)
                let buttons = d.shapes.filter { $0.kind == .button }
                #expect(buttons.map(\.target) == [.bezel(0), .bezel(1), .bezel(2)], "left to right")
                for b in buttons {
                    #expect(b.rect.width == b.rect.height, "round")
                    #expect(b.rect.maxY <= d.surface.minY && d.body.contains(b.rect), "on the top bezel")
                    #expect(d.target(at: CGPoint(x: b.rect.midX, y: b.rect.midY)) == b.target)
                }
                #expect(zip(buttons, buttons.dropFirst()).allSatisfy { $1.rect.minX - $0.rect.maxX >= d.grid },
                        "apart, not a block")
            }
        }
    }

    @Test("Turning a figure keeps each key on its own spot")
    func turnKeepsKeys() throws {
        for name in ["PTK-870", "PTH-850", "DTK-2400", "PTZ-631W"] {
            let figure = try #require(Self.figures.first { $0.name.contains(name) }?.figure)
            let flipped = figure.oriented(.landscapeFlipped)
            #expect(flipped.controls != nil, "\(name) keeps its controls")
            let frame = CGRect(x: 0, y: 0, width: 600, height: 180)
            let a = figure.drawing(.backdrop, in: frame, scale: 2), b = flipped.drawing(.backdrop, in: frame, scale: 2)
            // Where each target sits within the body, as a fraction of it.
            func spots(_ d: TabletFigure.Drawing) -> [ControlTarget: CGPoint] {
                d.shapes.reduce(into: [:]) { spots, shape in
                    guard let t = shape.target, shape.kind != .center else { return }
                    var x = shape.rect.midX, y = shape.rect.midY
                    // A pad's keys share its circle; aim at each one's quarter.
                    if case let .wedge(direction) = shape.kind {
                        x += cos(direction) * shape.rect.width * 0.35
                        y += sin(direction) * shape.rect.width * 0.35
                    }
                    spots[t] = CGPoint(x: (x - d.body.minX) / d.body.width, y: (y - d.body.minY) / d.body.height)
                }
            }
            let before = spots(a), after = spots(b)
            #expect(Set(before.keys) == Set(after.keys), "\(name): the same targets")
            for (t, p) in before {
                guard let q = after[t] else { continue }
                #expect(abs(q.x - (1 - p.x)) < 0.02 && abs(q.y - (1 - p.y)) < 0.02, "\(name): \(t) mirrored, \(p) → \(q)")
            }
        }
    }
}
