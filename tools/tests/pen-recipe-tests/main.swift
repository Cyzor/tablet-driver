// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Standalone checks for PenRecipe.
//
// Compiled against the real PenRecipe.swift. Run via
// tools/tests/pen-recipe-tests/run.sh. Exits non-zero on failure.

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

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.6) -> Bool { abs(a - b) <= tolerance }

// MARK: - Artwork

/// Each barrel's outline passes through the artwork's own corners.
private func testArtwork() {
    // (recipe, points on the body's outline taken from the artwork)
    let barrels: [(String, PenRecipe, [CGPoint])] = [
        ("classic", .classic, [CGPoint(x: 11.47, y: 60), CGPoint(x: 15.5, y: 200), CGPoint(x: 18.87, y: 369.95), CGPoint(x: 0, y: 381.43)]),
        ("slim", .slim, [CGPoint(x: 9.9, y: 60), CGPoint(x: 12.6, y: 200), CGPoint(x: 15.0, y: 371.08), CGPoint(x: 0, y: 381.43)]),
        ("straight", .straight, [CGPoint(x: 10.4, y: 60), CGPoint(x: 12.1, y: 300), CGPoint(x: 0, y: 381.43)]),
        ("xencelabs", .xencelabs, [CGPoint(x: 11.6, y: 60), CGPoint(x: 14.6, y: 190), CGPoint(x: 18.19, y: 368.87), CGPoint(x: 0, y: 381.43)]),
    ]
    for (name, recipe, points) in barrels {
        let body = recipe.body
        for p in points {
            let inside = body.contains(CGPoint(x: p.x - 0.7, y: p.y - (p.x == 0 ? 0.7 : 0)))
            let outside = !body.contains(CGPoint(x: p.x + 0.7, y: p.y + (p.x == 0 ? 0.7 : 0)))
            expect(inside && outside, "\(name): outline passes through \(p)")
        }
        let box = body.boundingBoxOfPath
        expect(near(box.midX, 0, 0.01), "\(name): body centered")
        expect(PenRecipe.frame.contains(recipe.outline.boundingBoxOfPath), "\(name): outline fits the shared frame")
    }
    expect(PenRecipe.classic.eraserCap != nil && PenRecipe.slim.eraserCap == nil, "classic has an eraser, slim doesn't")
    // The Xencelabs pen's tip is shorter and its eraser larger than the classic's.
    let xTip = PenRecipe.xencelabs.tip.boundingBoxOfPath, cTip = PenRecipe.classic.tip.boundingBoxOfPath
    expect(near(cTip.height - xTip.height, 3.01, 0.05), "xencelabs: tip three units shorter")
    if let e = PenRecipe.xencelabs.eraserCap?.boundingBoxOfPath {
        expect(near(e.width, 11.4, 0.05) && near(e.minY, 28.52, 0.05), "xencelabs: eraser size and place (\(e))")
    }
}

// MARK: - Variants

private func testVariants() {
    var recipes: [(String, PenRecipe)] = []
    for (name, barrel) in [("classic", PenRecipe.classic), ("slim", .slim), ("straight", .straight), ("xencelabs", .xencelabs),
                           ("fat", .straight.girth(1.3)), ("thin", .straight.girth(0.85))] {
        for count in 0...5 {
            for eraser in [false, true] {
                var r = barrel.buttons(count)
                r.eraser = eraser
                recipes.append(("\(name) \(count) buttons\(eraser ? ", eraser" : "")", r))
            }
        }
    }
    for (name, r) in recipes {
        let count = r.buttonShapes.count
        let expected: Int
        switch r.buttons {
        case .none: expected = 0
        case .single: expected = 1
        case let .separate(n): expected = n
        case let .rocker(dot): expected = dot ? 3 : 2
        case .pairAndDot: expected = 3
        }
        expect(count == expected, "\(name): \(expected) buttons drawn (\(count))")
        expect(count <= 3, "\(name): at most three buttons, as the pane's parts allow")
        expect(Set(r.buttonShapes.map(\.number)) == Set((0..<count).map { $0 + 1 }), "\(name): buttons numbered from 1")
        // Buttons sit inside the body, apart from each other, button 1 nearest the tip.
        let body = r.body
        for (n, b) in r.buttonShapes {
            let box = b.boundingBoxOfPath
            for corner in [CGPoint(x: box.minX + 1, y: box.midY), CGPoint(x: box.maxX - 1, y: box.midY)] {
                expect(body.contains(corner), "\(name): button \(n) inside the body")
            }
        }
        // Toward the tip: a rocker's dot, then button 1, then on up.
        var order = r.buttonShapes.sorted { $0.number < $1.number }
        if r.buttons == .rocker(dot: true) || r.buttons == .pairAndDot { order.insert(order.removeLast(), at: 0) }
        let ys = order.map { $0.path.boundingBoxOfPath }
        for (a, b) in zip(ys, ys.dropFirst()) {
            expect(a.minY > b.maxY + 2, "\(name): buttons apart and in order from the tip")
        }
        // A click at each part's center finds that part.
        for (part, path) in r.parts {
            let box = path.boundingBoxOfPath
            let center = CGPoint(x: box.midX, y: part == .tip ? PenRecipe.coneTop + 6 : box.midY)
            expect(r.part(at: center) == part, "\(name): a click on \(part) finds it (\(String(describing: r.part(at: center))))")
        }
        expect(r.part(at: CGPoint(x: 0, y: 150)) == nil, "\(name): the bare barrel isn't a part")
        expect(PenRecipe.frame.contains(r.outline.boundingBoxOfPath), "\(name): outline fits the shared frame")
        expect(!r.bodyFill.isEmpty, "\(name): body drawn")
    }
}

testArtwork()
testVariants()

if failures > 0 {
    print("pen-recipe-tests: \(failures) of \(checks) checks failed")
    exit(1)
}
print("pen-recipe-tests: all \(checks) checks passed")
