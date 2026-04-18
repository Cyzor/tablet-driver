// SPDX-License-Identifier: GPL-3.0-or-later
//
// MockTab — native macOS driver for supported drawing tablets
// Copyright (C) 2026
//
// This file is part of MockTab. MockTab is free software: you can
// redistribute it and/or modify it under the terms of the GNU General
// Public License as published by the Free Software Foundation, either
// version 3 of the License, or (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

// MARK: - Minimal SVG path-d parser
// Handles the command subset used by the pen and other SVG assets:
// M m L l H h V v C c S s Z z

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

// MARK: - Path+SVGData

extension Path {
    /// Creates a Path by parsing an SVG path `d` attribute string.
    ///
    /// Supports: M m L l H h V v C c S s Z z
    init(svgData d: String) {
        self.init(makeCGPath(d))
    }
}
