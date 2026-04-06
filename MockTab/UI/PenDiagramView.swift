// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

// MARK: - Minimal SVG path-d parser
// Handles the command subset used by GenericStylusPen.svg: M m L l H h V v C c S s Z z

private struct PathScanner {
    private let chars: [Character]
    private var pos: Int = 0
    private static let cmdSet = Set<Character>("MmLlHhVvCcSsZz")

    init(_ s: String) { chars = Array(s) }

    mutating func nextCommand() -> Character? {
        skipSep()
        guard pos < chars.count, Self.cmdSet.contains(chars[pos]) else { return nil }
        defer { pos += 1 }
        return chars[pos]
    }

    /// Peek: does the next non-separator character look like a number (not a command)?
    func hasMoreArgs() -> Bool {
        var p = pos
        while p < chars.count, chars[p].isWhitespace || chars[p] == "," { p += 1 }
        guard p < chars.count else { return false }
        let c = chars[p]
        return !Self.cmdSet.contains(c) && (c.isNumber || c == "-" || c == "+" || c == ".")
    }

    mutating func num() -> Double {
        skipSep()
        var s = ""
        if pos < chars.count, chars[pos] == "-" || chars[pos] == "+" {
            s.append(chars[pos]); pos += 1
        }
        var sawDot = false
        while pos < chars.count {
            let c = chars[pos]
            if c.isNumber { s.append(c); pos += 1 }
            else if c == ".", !sawDot { sawDot = true; s.append(c); pos += 1 }
            else { break }
        }
        if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
            s.append(chars[pos]); pos += 1
            if pos < chars.count, chars[pos] == "-" || chars[pos] == "+" { s.append(chars[pos]); pos += 1 }
            while pos < chars.count, chars[pos].isNumber { s.append(chars[pos]); pos += 1 }
        }
        return Double(s) ?? 0
    }

    mutating func pair() -> (Double, Double) { (num(), num()) }

    private mutating func skipSep() {
        while pos < chars.count, chars[pos].isWhitespace || chars[pos] == "," { pos += 1 }
    }
}

private func makeCGPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var sc = PathScanner(d)
    var cx = 0.0, cy = 0.0     // current point
    var sx = 0.0, sy = 0.0     // current subpath start
    var lcpx = 0.0, lcpy = 0.0 // last cubic cp2, for S/s reflection

    func resetLastCP() { lcpx = cx; lcpy = cy }

    while let cmd = sc.nextCommand() {
        switch cmd {

        case "M":
            let (x, y) = sc.pair()
            path.move(to: CGPoint(x: x, y: y))
            cx = x; cy = y; sx = x; sy = y; resetLastCP()
            // Subsequent coord pairs after M are implicit L
            while sc.hasMoreArgs() {
                let (x2, y2) = sc.pair()
                path.addLine(to: CGPoint(x: x2, y: y2))
                cx = x2; cy = y2; resetLastCP()
            }

        case "m":
            let (dx, dy) = sc.pair()
            let x = cx + dx, y = cy + dy
            path.move(to: CGPoint(x: x, y: y))
            cx = x; cy = y; sx = x; sy = y; resetLastCP()

        case "L":
            repeat {
                let (x, y) = sc.pair()
                path.addLine(to: CGPoint(x: x, y: y))
                cx = x; cy = y; resetLastCP()
            } while sc.hasMoreArgs()

        case "l":
            repeat {
                let (dx, dy) = sc.pair()
                let x = cx + dx, y = cy + dy
                path.addLine(to: CGPoint(x: x, y: y))
                cx = x; cy = y; resetLastCP()
            } while sc.hasMoreArgs()

        case "H":
            repeat {
                let x = sc.num()
                path.addLine(to: CGPoint(x: x, y: cy))
                cx = x; resetLastCP()
            } while sc.hasMoreArgs()

        case "h":
            repeat {
                let x = cx + sc.num()
                path.addLine(to: CGPoint(x: x, y: cy))
                cx = x; resetLastCP()
            } while sc.hasMoreArgs()

        case "V":
            repeat {
                let y = sc.num()
                path.addLine(to: CGPoint(x: cx, y: y))
                cy = y; resetLastCP()
            } while sc.hasMoreArgs()

        case "v":
            repeat {
                let y = cy + sc.num()
                path.addLine(to: CGPoint(x: cx, y: y))
                cy = y; resetLastCP()
            } while sc.hasMoreArgs()

        case "C":
            repeat {
                let (x1, y1) = sc.pair(), (x2, y2) = sc.pair(), (x, y) = sc.pair()
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
                lcpx = x2; lcpy = y2; cx = x; cy = y
            } while sc.hasMoreArgs()

        case "c":
            repeat {
                let (dx1, dy1) = sc.pair(), (dx2, dy2) = sc.pair(), (dx, dy) = sc.pair()
                let x2 = cx + dx2, y2 = cy + dy2, x = cx + dx, y = cy + dy
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: cx + dx1, y: cy + dy1),
                              control2: CGPoint(x: x2, y: y2))
                lcpx = x2; lcpy = y2; cx = x; cy = y
            } while sc.hasMoreArgs()

        case "S":
            repeat {
                let (x2, y2) = sc.pair(), (x, y) = sc.pair()
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: 2 * cx - lcpx, y: 2 * cy - lcpy),
                              control2: CGPoint(x: x2, y: y2))
                lcpx = x2; lcpy = y2; cx = x; cy = y
            } while sc.hasMoreArgs()

        case "s":
            repeat {
                let (dx2, dy2) = sc.pair(), (dx, dy) = sc.pair()
                let x2 = cx + dx2, y2 = cy + dy2, x = cx + dx, y = cy + dy
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: 2 * cx - lcpx, y: 2 * cy - lcpy),
                              control2: CGPoint(x: x2, y: y2))
                lcpx = x2; lcpy = y2; cx = x; cy = y
            } while sc.hasMoreArgs()

        case "Z", "z":
            path.closeSubpath()
            cx = sx; cy = sy; resetLastCP()

        default: break
        }
    }
    return path
}

// MARK: - PenDiagramView

/// Renders a schematic side-view of the stylus pen, rotated 90° so the tip
/// faces right and the eraser faces left.  Segments illuminate in accent colour
/// when the corresponding physical input is active.
struct PenDiagramView: View {
    let liveButtons: LiveButtonState

    // SVG viewBox origin and dimensions (GenericStylusPen.svg: 0 0 44 306)
    private static let svgW = 44.0
    private static let svgH = 306.0

    // Pre-parse once at app launch (static let is lazy in Swift)
    private static let bodyPath   = makeCGPath(
        "M7.59,116.69l1.94-93.67c.08-2.24,1.89-4,4.13-4h16.66c2.24,0,4.06,1.76,4.13,4l1.94,93.67" +
        "c.02,1.12-.88,2.04-1.99,2.04h-12.41s-12.41,0-12.41,0c-1.12,0-2.02-.92-1.99-2.04Z" +
        "M38.16,122.56c-.02-1.09-.91-1.96-1.99-1.96H7.83c-1.09,0-1.98.87-1.99,1.96l-2.1,134.31" +
        "c-.24,7.64,1.66,15.24,5.34,21.91.43.69,2.26,3.53,2.98,4.65.18.29.5.46.84.46h9.1s9.1,0,9.1,0" +
        "c.34,0,.66-.17.84-.46.72-1.12,2.55-3.97,2.98-4.65,3.69-6.66,5.58-14.27,5.34-21.91l-2.1-134.31Z")
    private static let eraserPath = makeCGPath(
        "M29.59,10.56c0-4.18-3.4-7.59-7.59-7.59-4.19,0-7.59,3.41-7.59,7.59v5.46" +
        "c0,.55.45,1,1,1h6.59s6.59,0,6.59,0c.55,0,1-.45,1-1v-5.46Z")
    private static let tipPath    = makeCGPath(
        "M22,285.59h7.43c.41,0,.64.46.4.79l-3.61,4.96c-1.04,1.43-2.64,2.15-4.23,2.15" +
        "-1.59,0-3.18-.72-4.23-2.15l-3.61-4.96c-.24-.33,0-.79.4-.79h7.43Z" +
        "M23.78,300.08l.29-4.86c.02-.33-.27-.59-.59-.52-.34.07-.84.13-1.48.13s-1.14-.06-1.48-.13" +
        "c-.32-.07-.61.19-.59.52l.29,4.86c.06.94.83,1.67,1.78,1.67h0c.94,0,1.72-.73,1.78-1.67Z")
    private static let btn2Path   = makeCGPath(
        "M26.9,222.18h-9.8l-.65-28.64c-.07-3.07,2.4-5.6,5.48-5.6h.15" +
        "c3.07,0,5.55,2.53,5.48,5.6l-.65,28.64Z")
    private static let btn1Path   = makeCGPath(
        "M22,251.92h0c-3.08,0-5.55-2.53-5.48-5.61l.58-24.13h9.8l.58,24.13" +
        "c.07,3.08-2.4,5.61-5.48,5.61Z")

    var body: some View {
        Canvas { context, size in
            // Scale to fit, preserving aspect ratio.
            // Pen is displayed rotated 90° counterclockwise: tip at left, eraser at right.
            // SVG (x,y) → display (-y·scale + tx,  x·scale + ty)
            let scale = min(size.width / Self.svgH, size.height / Self.svgW)
            let tx = (size.width + Self.svgH * scale) / 2.0
            let ty = (size.height - Self.svgW * scale) / 2.0
            var t = CGAffineTransform(a: 0, b: scale, c: -scale, d: 0, tx: tx, ty: ty)

            func draw(_ cgp: CGPath, fill: Color, stroke: Color) {
                guard let xp = cgp.copy(using: &t) else { return }
                let p = Path(xp)
                context.fill(p, with: .color(fill))
                context.stroke(p, with: .color(stroke), style: StrokeStyle(lineWidth: 1.0))
            }

            let passive   = Color.secondary.opacity(0.12)
            let bodyFill  = Color(NSColor.windowBackgroundColor)
            let strokeDim = Color.secondary
            let accent    = Color.accentColor

            draw(Self.bodyPath,   fill: bodyFill,  stroke: strokeDim)
            draw(Self.eraserPath, fill: liveButtons.eraserDown  ? accent : passive,
                                  stroke: liveButtons.eraserDown  ? accent : strokeDim)
            draw(Self.btn2Path,   fill: liveButtons.button2Down ? accent : passive,
                                  stroke: liveButtons.button2Down ? accent : strokeDim)
            draw(Self.btn1Path,   fill: liveButtons.button1Down ? accent : passive,
                                  stroke: liveButtons.button1Down ? accent : strokeDim)
            draw(Self.tipPath,    fill: liveButtons.tipDown     ? accent : passive,
                                  stroke: liveButtons.tipDown     ? accent : strokeDim)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 1)
        .animation(.easeOut(duration: 0.07), value: liveButtons)
    }
}
