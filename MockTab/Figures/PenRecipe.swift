// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

// MARK: - PenRecipe

/// A pen in the pen diagram's language: a body of straight runs, the shared
/// tip, an optional eraser stub, and slot buttons. A few numbers make each
/// barrel, and the tool's button count and eraser fill in the rest.
///
/// Units follow the original artwork: the pen stands upright, tip down,
/// centered on x = 0, with y growing toward the tip.
struct PenRecipe: Equatable {
    /// The body's top, and its half-widths down to the chamfer.
    var top: Double
    var topHalf: Double
    /// The rear body at the seam, and the front just below it. Equal for a
    /// barrel without a step.
    var seamHalf: Double
    var stepHalf: Double
    /// Where the front starts to flare, and its widest point.
    var waistY: Double
    var waistHalf: Double
    var flareY: Double
    var flareHalf: Double
    /// The body's bottom, where it meets the tip, and its half-width there.
    var chamferHalf: Double
    /// The tip cone's top.
    var tipHalf: Double
    var eraser: Bool
    var buttons: Buttons
    var seamY = 186.54
    var bottom = 381.43

    enum Buttons: Equatable {
        case none
        /// One long slot.
        case single
        /// Separate slots, button 1 nearest the tip.
        case separate(Int)
        /// A two-way rocker, with a third button as a dot below it.
        case rocker(dot: Bool)
        /// Two separate slots with a third button as a dot below them.
        case pairAndDot
        /// A two-way rocker, with a third button as a slot above it.
        case slotAndRocker
    }

    /// Clickable parts, matching the pane's binding rows.
    enum Part: Hashable { case tip, eraser, button(Int) }

    /// The gap between the body and the tip or eraser.
    static let partGap = 1.88
    /// Every cone ends here, so a longer body means a shorter cone.
    static let coneBottom = 399.85, coneBottomHalf = 4.225
    /// From the cone's end: the gap to the nib, and the nib's length.
    static let nibGap = 1.97, nibLength = 7.97, nibHalf = 2.07
    static let buttonCenter = 299.2, buttonHalf = 5.025, buttonRadius = 4.0
    static let eraserHalf = 5.7, eraserHeight = 11.16
    /// Every pen fits this box, so each draws at the same scale.
    static let frame = CGRect(x: -24, y: 24, width: 48, height: 392)

    /// A grip pen: wide, stepped at the seam, flared before the tip.
    static let classic = PenRecipe(
        top: 44.56, topHalf: 11.47, seamHalf: 13.53, stepHalf: 15.53,
        waistY: 337.12, waistHalf: 16.5, flareY: 369.95, flareHalf: 18.875,
        chamferHalf: 10.675, tipHalf: 8.41, eraser: true, buttons: .rocker(dot: true))
    /// Narrower, with a smaller flare.
    static let slim = PenRecipe(
        top: 44.56, topHalf: 9.0, seamHalf: 10.23, stepHalf: 12.55,
        waistY: 354.07, waistHalf: 13.865, flareY: 371.08, flareHalf: 15.015,
        chamferHalf: 11.025, tipHalf: 8.41, eraser: false, buttons: .separate(3))
    /// No step and no flare.
    static let straight = PenRecipe(
        top: 47.56, topHalf: 10.26, seamHalf: 12.015, stepHalf: 12.015,
        waistY: 374.47, waistHalf: 12.205, flareY: 374.47, flareHalf: 12.205,
        chamferHalf: 11.445, tipHalf: 9.65, eraser: false, buttons: .single)
    /// The Xencelabs 3 Button Pen: an Art Pen's shape with a third button, a
    /// higher seam, and a longer body over a shorter tip.
    static let xencelabs = PenRecipe(
        top: 44.56, topHalf: 11.465, seamHalf: 13.61, stepHalf: 14.56,
        waistY: 331.08, waistHalf: 15.85, flareY: 371.87, flareHalf: 18.19,
        chamferHalf: 10.79, tipHalf: 8.41, eraser: true, buttons: .pairAndDot,
        seamY: 178.53, bottom: 384.43)
    /// Art Pen 2: a straight taper that bends at the seam, a rocker with a
    /// slot above it, and no eraser.
    static let artPen2 = PenRecipe(
        top: 47.55, topHalf: 9.77, seamHalf: 11.45, stepHalf: 11.45,
        waistY: 369.65, waistHalf: 14.87, flareY: 369.65, flareHalf: 14.87,
        chamferHalf: 11.1, tipHalf: 9.65, eraser: false, buttons: .slotAndRocker,
        seamY: 183.51)

    /// The same pen with its body widened or narrowed; the tip, eraser, and
    /// buttons keep their size.
    func girth(_ k: Double) -> PenRecipe {
        var r = self
        r.topHalf *= k
        r.seamHalf *= k
        r.stepHalf *= k
        r.waistHalf *= k
        r.flareHalf *= k
        r.chamferHalf = max(r.chamferHalf * k, r.tipHalf + 1.5)
        return r
    }

    /// Buttons for `count`, in this barrel's style: a grip pen's rocker, or
    /// separate slots, with a single button as one long slot.
    func buttons(_ count: Int) -> PenRecipe {
        var r = self
        switch count {
        case ..<1: r.buttons = .none
        case 1: r.buttons = .single
        default:
            switch buttons {
            case .rocker: r.buttons = .rocker(dot: count >= 3)
            case .pairAndDot: r.buttons = count >= 3 ? .pairAndDot : .separate(2)
            case .slotAndRocker: r.buttons = count >= 3 ? .slotAndRocker : .rocker(dot: false)
            default: r.buttons = .separate(min(count, 3))
            }
        }
        return r
    }
}

// MARK: - Geometry

extension PenRecipe {
    /// A closed polygon with its corners eased by `radius`.
    private static func rounded(_ points: [CGPoint], radius: Double) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        path.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
        for i in 0..<n {
            path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius)
        }
        path.closeSubpath()
        return path
    }

    /// A slot rounded at one end only, cut from a capsule.
    private static func slot(_ rect: CGRect, keep: CGRect) -> CGPath {
        let r = rect.width / 2
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            .intersection(CGPath(rect: keep, transform: nil))
    }

    var body: CGPath {
        var right = [CGPoint(x: topHalf, y: top), CGPoint(x: seamHalf, y: seamY)]
        if stepHalf > seamHalf + 0.1 { right.append(CGPoint(x: stepHalf, y: seamY + 2)) }
        if waistY < flareY - 0.1 { right.append(CGPoint(x: waistHalf, y: waistY)) }
        right.append(CGPoint(x: flareHalf, y: flareY))
        right.append(CGPoint(x: chamferHalf, y: bottom))
        let left = right.reversed().map { CGPoint(x: -$0.x, y: $0.y) }
        return Self.rounded(right + left, radius: 2)
    }

    var coneTop: Double { bottom + Self.partGap }

    var tip: CGPath {
        let cone = Self.rounded([
            CGPoint(x: -tipHalf, y: coneTop), CGPoint(x: tipHalf, y: coneTop),
            CGPoint(x: Self.coneBottomHalf, y: Self.coneBottom), CGPoint(x: -Self.coneBottomHalf, y: Self.coneBottom),
        ], radius: 0.5)
        let h = Self.nibHalf, nibTop = Self.coneBottom + Self.nibGap
        let nib = Self.slot(CGRect(x: -h, y: nibTop - h, width: 2 * h, height: Self.nibLength + h),
                            keep: CGRect(x: -h, y: nibTop, width: 2 * h, height: Self.nibLength))
        return cone.union(nib)
    }

    var eraserCap: CGPath? {
        guard eraser else { return nil }
        let h = Self.eraserHalf, height = Self.eraserHeight, y = top - Self.partGap - height
        return Self.slot(CGRect(x: -h, y: y, width: 2 * h, height: height + h),
                         keep: CGRect(x: -h, y: y, width: 2 * h, height: height))
    }

    /// Button slots by number, 1 nearest the tip.
    var buttonShapes: [(number: Int, path: CGPath)] {
        let h = Self.buttonHalf, c = Self.buttonCenter
        func slot(_ y0: Double, _ y1: Double) -> CGPath {
            CGPath(roundedRect: CGRect(x: -h, y: y0, width: 2 * h, height: y1 - y0),
                   cornerWidth: Self.buttonRadius, cornerHeight: Self.buttonRadius, transform: nil)
        }
        switch buttons {
        case .none:
            return []
        case .single:
            return [(1, slot(c - 31.635, c + 31.635))]
        case let .separate(n):
            let length = 24.88, pitch = 32.16
            let first = c + Double(n - 1) * pitch / 2
            return (0..<n).map { i in
                let center = first - Double(i) * pitch
                return (i + 1, slot(center - length / 2, center + length / 2))
            }
        case let .rocker(dot):
            var shapes = Self.rocker(top: 264.16, split: 305.41, bottom: 333.09)
            if dot { shapes.append((3, Self.dot(at: 343.67, radius: 5.64))) }
            return shapes
        case .slotAndRocker:
            return Self.rocker(top: 269.16, split: 306.41, bottom: 334.08) + [(3, slot(237.72, 262.6))]
        case .pairAndDot:
            let length = 23.33
            return [(1, slot(311.81, 311.81 + length)), (2, slot(281.64, 281.64 + length)),
                    (3, Self.dot(at: 347.67, radius: 5.69))]
        }
    }

    /// A rocker's two halves: round outer ends, flat inner ends, narrowing
    /// slightly toward the split.
    private static func rocker(top: Double, split: Double, bottom: Double) -> [(number: Int, path: CGPath)] {
        let w = 5.55, n = 4.92, lowerTop = split + 4.94
        let upper = rounded([CGPoint(x: -n, y: split), CGPoint(x: -w, y: top),
                             CGPoint(x: w, y: top), CGPoint(x: n, y: split)], radius: 1)
            .intersection(CGPath(roundedRect: CGRect(x: -w, y: top, width: 2 * w, height: 60),
                                 cornerWidth: w, cornerHeight: w, transform: nil))
        let lower = rounded([CGPoint(x: -n, y: lowerTop), CGPoint(x: n, y: lowerTop),
                             CGPoint(x: w, y: bottom), CGPoint(x: -w, y: bottom)], radius: 1)
            .intersection(CGPath(roundedRect: CGRect(x: -w, y: bottom - 43.09, width: 2 * w, height: 43.09),
                                 cornerWidth: w, cornerHeight: w, transform: nil))
        return [(1, lower), (2, upper)]
    }

    private static func dot(at y: Double, radius r: Double) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
    }

    /// The parts that take a tone of their own, in drawing order. A button
    /// shows its face, one unit inside its slot.
    var parts: [(part: Part, path: CGPath)] {
        var parts: [(part: Part, path: CGPath)] = [(.tip, tip)]
        if let eraserCap { parts.append((.eraser, eraserCap)) }
        // Normalized, or the rocker's lower half loses an edge.
        parts += buttonShapes.map { (.button($0.number), $0.path.subtracting(Self.stroke($0.path, 2).normalized())) }
        return parts
    }

    private static func stroke(_ path: CGPath, _ width: Double) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    /// The outline: a band from two to four units outside every part.
    var outline: CGPath {
        let all = parts.map(\.path).reduce(body) { $0.union($1) }
        return all.union(Self.stroke(all, 8)).subtracting(all.union(Self.stroke(all, 4)))
    }

    /// The body, cut one unit clear of each slot; with the face's inset, a
    /// two-unit gap rings each button.
    var bodyFill: CGPath {
        buttonShapes.reduce(body) { $0.subtracting($1.path.union(Self.stroke($1.path, 2))) }
    }

    /// The part under `point`, padded so slim parts are easy to hit.
    func part(at point: CGPoint) -> Part? {
        // Buttons first: they sit on the body, and the dot is small.
        for (part, path) in parts.reversed() where path.union(Self.stroke(path, 4)).contains(point) {
            return part
        }
        return nil
    }
}
