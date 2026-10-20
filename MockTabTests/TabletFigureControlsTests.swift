// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import TabletKit
import Testing

@Suite("Tablet figure with controls")
struct TabletFigureControlsTests {
    /// Every model with a family rule, drawn with its controls. The gate
    /// isn't applied, so unverified families' geometry is tested too.
    private static let figures: [(name: String, map: TabletControlMap, figure: TabletFigure)] =
        WacomDeviceRegistry.knownDevices.compactMap { spec in
            guard let family = TabletControlMap.family(for: spec),
                  let identity = TabletLayoutIdentity.all[spec.productID],
                  spec.maxX > 0, spec.maxY > 0
            else { return nil }
            let map = TabletControlMap.make(identity, family: family)
            let mm = spec.activeWidthMM.flatMap { w in spec.activeHeightMM.map { CGSize(width: w, height: $0) } }
            var figure = TabletFigure(layoutProductID: spec.productID, surfaceMM: mm,
                                      aspect: Double(spec.maxX) / Double(spec.maxY), isPenDisplay: spec.isPenDisplay)
            figure.controls = map.parts
            return (spec.name, map, figure)
        }

    /// The Tablet Area and Touch panes' bezel sizes, and a diagram-sized row.
    private static let frames = [CGRect(x: 2, y: 2, width: 516, height: 196), CGRect(x: 2, y: 2, width: 296, height: 196),
                                 CGRect(x: 2, y: 2, width: 596, height: 176)]

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
                    // A center sits inside its ring.
                    if a.kind == .center || b.kind == .center { continue }
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
                // A ring's middle may be its center button; aim at its band.
                let point = shape.kind == .ring || shape.kind == .dial ? CGPoint(x: r.midX, y: r.minY + r.height * 0.1)
                    : CGPoint(x: r.midX, y: r.midY)
                #expect(d.target(at: point) == target, "\(name): \(shape.kind) answers for \(target)")
            }
            #expect(d.target(at: CGPoint(x: d.surface.midX, y: d.surface.midY)) == nil, "\(name): the surface answers nothing")
        }
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

    @Test("Turning a figure drops its controls")
    func turnDropsControls() throws {
        let figure = try #require(Self.figures.first?.figure)
        #expect(figure.controls != nil)
        #expect(figure.oriented(.landscape).controls != nil)
        #expect(figure.oriented(.portrait).controls == nil)
    }
}
