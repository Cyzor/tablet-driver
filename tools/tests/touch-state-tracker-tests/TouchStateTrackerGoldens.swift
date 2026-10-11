// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// TouchStateTrackerGoldens.swift — Whole-session characterization of
// TouchStateTracker.process.
//
// Each session is a scripted, synthetic gesture played at USB and Bluetooth
// cadence with seeded jitter. Every intent is written to goldens.txt, and any
// difference fails the run, so a refactor that changes behavior shows up.
// Synthetic input approximates real hands; where a session misbehaves, check
// it on hardware before trusting either the code or the session.
//
// UPDATE_GOLDENS=1 rewrites goldens.txt instead of comparing.

import Foundation

typealias Contacts = [(id: Int, screen: CGPoint)]

/// Points per millimeter on the touch surface, roughly a PTH-860 mapped to a
/// laptop display. Raw positions go to the tracker in millimeters.
private let ptPerMM = 8.0
private let touchDiagonalMM = 270.0

/// Deterministic generator, so jitter is identical on every run.
private struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func jitter(_ amplitude: Double) -> Double { (next() * 2 - 1) * amplitude }
}

private enum Cadence: String, CaseIterable {
    case usb, bluetooth

    /// Report times for a session lasting `duration` seconds. USB reports
    /// evenly; Bluetooth delivers pairs 0.5 ms apart, then waits.
    func times(_ duration: Double) -> [Double] {
        var out: [Double] = []
        var t = 0.0
        switch self {
        case .usb:
            while t <= duration { out.append(t); t += 0.005 }
        case .bluetooth:
            while t <= duration { out.append(t); out.append(t + 0.0005); t += 0.015 }
        }
        return out
    }
}

private struct Settings {
    var tapToClick = true
    var pinchZoom = true
    var rotate = true
    var twoFingerRightClick = true
    var threeFingerDrag = true
    var absolute = false
}

/// A finger's path: present from `down` to `up`, at `position(t)`.
private struct Finger {
    let id: Int
    let down: Double
    let up: Double
    let position: (Double) -> CGPoint
}

private struct Session {
    let name: String
    let duration: Double
    var settings = Settings()
    var jitter = 0.3
    let fingers: [Finger]
}

private func line(_ a: CGPoint, _ b: CGPoint, from t0: Double, to t1: Double) -> (Double) -> CGPoint {
    { t in
        let f = min(max((t - t0) / (t1 - t0), 0), 1)
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

private func still(_ p: CGPoint) -> (Double) -> CGPoint { { _ in p } }

private func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

private let sessions: [Session] = {
    var s: [Session] = []

    s.append(Session(name: "pointer slow drag", duration: 0.6, fingers: [
        Finger(id: 1, down: 0, up: 0.55, position: line(p(0, 0), p(60, 20), from: 0.05, to: 0.5)),
    ]))
    s.append(Session(name: "pointer fast flick", duration: 0.2, fingers: [
        Finger(id: 1, down: 0, up: 0.15, position: line(p(0, 0), p(300, -40), from: 0.04, to: 0.14)),
    ]))
    s.append(Session(name: "tap", duration: 0.2, fingers: [
        Finger(id: 1, down: 0, up: 0.09, position: still(p(0, 0))),
    ]))
    s.append(Session(name: "tap that creeps past the stabilization hold", duration: 0.25, fingers: [
        Finger(id: 1, down: 0, up: 0.2, position: line(p(0, 0), p(5, 3), from: 0.02, to: 0.18)),
    ]))
    s.append(Session(name: "slow press, no motion", duration: 0.6, fingers: [
        Finger(id: 1, down: 0, up: 0.5, position: still(p(0, 0))),
    ]))
    s.append(Session(name: "double tap", duration: 0.4, fingers: [
        Finger(id: 1, down: 0, up: 0.08, position: still(p(0, 0))),
        Finger(id: 2, down: 0.18, up: 0.26, position: still(p(1, 1))),
    ]))
    s.append(Session(name: "scroll down with fling", duration: 0.35, fingers: [
        Finger(id: 1, down: 0, up: 0.3, position: line(p(0, 0), p(4, 160), from: 0.05, to: 0.29)),
        Finger(id: 2, down: 0.01, up: 0.3, position: line(p(120, 0), p(124, 160), from: 0.05, to: 0.29)),
    ]))
    s.append(Session(name: "scroll, one finger lingers", duration: 0.6, fingers: [
        Finger(id: 1, down: 0, up: 0.3, position: line(p(0, 0), p(0, 120), from: 0.05, to: 0.29)),
        Finger(id: 2, down: 0.01, up: 0.5, position: line(p(120, 0), p(120, 120), from: 0.05, to: 0.29)),
    ]))
    s.append(Session(name: "diagonal scroll", duration: 0.4, fingers: [
        Finger(id: 1, down: 0, up: 0.35, position: line(p(0, 0), p(90, 70), from: 0.05, to: 0.33)),
        Finger(id: 2, down: 0.01, up: 0.35, position: line(p(120, 0), p(210, 70), from: 0.05, to: 0.33)),
    ]))
    s.append(Session(name: "slow scroll, then stop before lifting", duration: 0.7, fingers: [
        Finger(id: 1, down: 0, up: 0.65, position: line(p(0, 0), p(0, 40), from: 0.05, to: 0.4)),
        Finger(id: 2, down: 0.01, up: 0.65, position: line(p(120, 0), p(120, 40), from: 0.05, to: 0.4)),
    ]))
    s.append(Session(name: "pinch out", duration: 0.4, fingers: [
        Finger(id: 1, down: 0, up: 0.35, position: line(p(-60, 0), p(-160, 0), from: 0.05, to: 0.33)),
        Finger(id: 2, down: 0.01, up: 0.35, position: line(p(60, 0), p(160, 0), from: 0.05, to: 0.33)),
    ]))
    s.append(Session(name: "pinch out with rotate off", duration: 0.4,
                     settings: Settings(rotate: false), fingers: [
        Finger(id: 1, down: 0, up: 0.35, position: line(p(-60, 0), p(-160, 0), from: 0.05, to: 0.33)),
        Finger(id: 2, down: 0.01, up: 0.35, position: line(p(60, 0), p(160, 0), from: 0.05, to: 0.33)),
    ]))
    let r = 300.0
    s.append(Session(name: "rotate a quarter turn", duration: 0.5, fingers: [
        Finger(id: 1, down: 0, up: 0.45, position: { t in
            let a = Double.pi / 2 * min(max((t - 0.05) / 0.38, 0), 1)
            return p(r * cos(a), r * sin(a))
        }),
        Finger(id: 2, down: 0.01, up: 0.45, position: { t in
            let a = Double.pi / 2 * min(max((t - 0.05) / 0.38, 0), 1)
            return p(-r * cos(a), -r * sin(a))
        }),
    ]))
    s.append(Session(name: "pinch that gains a twist", duration: 0.6, fingers: [
        Finger(id: 1, down: 0, up: 0.55, position: { t in
            let d = 200 + 200 * min(max((t - 0.05) / 0.45, 0), 1)
            let a = 0.6 * min(max((t - 0.25) / 0.25, 0), 1)
            return p(d * cos(a), d * sin(a))
        }),
        Finger(id: 2, down: 0.01, up: 0.55, position: { t in
            let d = 200 + 200 * min(max((t - 0.05) / 0.45, 0), 1)
            let a = 0.6 * min(max((t - 0.25) / 0.25, 0), 1)
            return p(-d * cos(a), -d * sin(a))
        }),
    ]))
    s.append(Session(name: "two-finger tap", duration: 0.25, fingers: [
        Finger(id: 1, down: 0, up: 0.12, position: still(p(0, 0))),
        Finger(id: 2, down: 0.015, up: 0.125, position: still(p(120, 0))),
    ]))
    s.append(Session(name: "two-finger tap, fingers 4 mm apart", duration: 0.25, fingers: [
        Finger(id: 1, down: 0, up: 0.12, position: still(p(0, 0))),
        Finger(id: 2, down: 0.015, up: 0.125, position: still(p(32, 0))),
    ]))
    s.append(Session(name: "three-finger drag", duration: 0.5, fingers: [
        Finger(id: 1, down: 0, up: 0.45, position: line(p(0, 0), p(150, 60), from: 0.1, to: 0.4)),
        Finger(id: 2, down: 0.02, up: 0.45, position: line(p(120, 0), p(270, 60), from: 0.1, to: 0.4)),
        Finger(id: 3, down: 0.04, up: 0.45, position: line(p(240, 0), p(390, 60), from: 0.1, to: 0.4)),
    ]))
    s.append(Session(name: "three-finger drag, lead lifts first", duration: 0.5, fingers: [
        Finger(id: 1, down: 0, up: 0.25, position: line(p(0, 0), p(150, 0), from: 0.1, to: 0.4)),
        Finger(id: 2, down: 0.02, up: 0.45, position: line(p(120, 0), p(270, 0), from: 0.1, to: 0.4)),
        Finger(id: 3, down: 0.04, up: 0.45, position: line(p(240, 0), p(390, 0), from: 0.1, to: 0.4)),
    ]))
    s.append(Session(name: "late third finger during scroll", duration: 0.5, fingers: [
        Finger(id: 1, down: 0, up: 0.45, position: line(p(0, 0), p(0, 100), from: 0.05, to: 0.4)),
        Finger(id: 2, down: 0.01, up: 0.45, position: line(p(120, 0), p(120, 100), from: 0.05, to: 0.4)),
        Finger(id: 3, down: 0.25, up: 0.45, position: still(p(240, 50))),
    ]))
    s.append(Session(name: "second finger lands mid pointer drag", duration: 0.5, fingers: [
        Finger(id: 1, down: 0, up: 0.45, position: line(p(0, 0), p(100, 0), from: 0.05, to: 0.4)),
        Finger(id: 2, down: 0.2, up: 0.3, position: still(p(200, 80))),
    ]))
    s.append(Session(name: "absolute drag and tap", duration: 0.6,
                     settings: Settings(absolute: true), fingers: [
        Finger(id: 1, down: 0, up: 0.3, position: line(p(100, 100), p(160, 140), from: 0.05, to: 0.25)),
        Finger(id: 2, down: 0.45, up: 0.53, position: still(p(400, 300))),
    ]))
    s.append(Session(name: "everything off but scroll", duration: 0.4,
                     settings: Settings(tapToClick: false, pinchZoom: false, rotate: false,
                                        twoFingerRightClick: false, threeFingerDrag: false), fingers: [
        Finger(id: 1, down: 0, up: 0.35, position: line(p(-60, 0), p(-160, 0), from: 0.05, to: 0.33)),
        Finger(id: 2, down: 0.01, up: 0.35, position: line(p(60, 0), p(160, 0), from: 0.05, to: 0.33)),
    ]))
    return s
}()

private func fmt(_ v: Double) -> String {
    let s = String(format: "%.4f", v)
    return s == "-0.0000" ? "0.0000" : s
}

private func describe(_ intent: TouchStateTracker.Intent) -> String {
    func g(_ d: TouchStateTracker.GestureDelta?) -> String {
        d.map { "\(fmt($0.value)) \($0.phase)" } ?? "-"
    }
    switch intent {
    case .none: return "none"
    case let .pointerMove(dx, dy): return "pointerMove \(fmt(dx)) \(fmt(dy))"
    case let .pointerWarp(to): return "pointerWarp \(fmt(to.x)) \(fmt(to.y))"
    case .tapClick: return "tapClick"
    case .secondaryClick: return "secondaryClick"
    case let .dragDown(at): return "dragDown " + (at.map { "\(fmt($0.x)) \(fmt($0.y))" } ?? "here")
    case let .dragMove(dx, dy): return "dragMove \(fmt(dx)) \(fmt(dy))"
    case let .dragWarp(to): return "dragWarp \(fmt(to.x)) \(fmt(to.y))"
    case .dragUp: return "dragUp"
    case let .scrollDelta(dx, dy, phase): return "scroll \(fmt(dx)) \(fmt(dy)) \(phase)"
    case let .twoFingerGesture(m, r): return "gesture magnify \(g(m)) rotate \(g(r))"
    }
}

/// The gesture classes a session produced, for the cadence comparison.
private func kinds(_ intents: [TouchStateTracker.Intent]) -> [String] {
    var out: [String] = []
    for i in intents {
        let k: String?
        switch i {
        case .none: k = nil
        case .pointerMove, .pointerWarp: k = "pointer"
        case .tapClick: k = "tap"
        case .secondaryClick: k = "secondaryClick"
        case .dragDown, .dragMove, .dragWarp, .dragUp: k = "drag"
        case .scrollDelta: k = "scroll"
        case let .twoFingerGesture(m, r): k = (m != nil ? "magnify" : "") + (r != nil ? "rotate" : "")
        }
        if let k, out.last != k { out.append(k) }
    }
    return out
}

private func play(_ session: Session, _ cadence: Cadence, into out: inout [String]) -> [TouchStateTracker.Intent] {
    var rng = SeededRandom(state: (session.name + cadence.rawValue).hashValueStable)
    var tracker = TouchStateTracker()
    var intents: [TouchStateTracker.Intent] = []
    var lastMode = tracker.mode
    out.append("## \(session.name) [\(cadence.rawValue)]")
    let st = session.settings
    for t in cadence.times(session.duration) {
        var contacts: Contacts = []
        var raw: [Int: CGPoint] = [:]
        for f in session.fingers where t >= f.down && t < f.up {
            let base = f.position(t)
            let pt = CGPoint(x: base.x + rng.jitter(session.jitter), y: base.y + rng.jitter(session.jitter))
            contacts.append((id: f.id, screen: pt))
            raw[f.id] = CGPoint(x: pt.x / ptPerMM, y: pt.y / ptPerMM)
        }
        let intent = tracker.process(
            contacts: contacts,
            tapToClick: st.tapToClick,
            twoFingerScroll: true,
            reverseScrollDirection: false,
            sensitivity: 1,
            pinchZoom: st.pinchZoom,
            twoFingerRightClick: st.twoFingerRightClick,
            threeFingerDrag: st.threeFingerDrag,
            rotate: st.rotate,
            rawPositions: raw,
            touchDiagonal: touchDiagonalMM,
            absoluteTouch: st.absolute,
            now: t
        )
        intents.append(intent)
        if intent != .none || tracker.mode != lastMode {
            var entry = "\(fmt(t)) n=\(contacts.count) \(tracker.mode) \(describe(intent))"
            // The tracker clears release velocity on the next frame, so read it here.
            if case .scrollDelta(_, _, .ended) = intent {
                let v = tracker.releaseVelocity
                entry += " release \(fmt(v.dx)) \(fmt(v.dy))" + (tracker.releaseSuppressedByRecency ? " suppressed" : "")
            }
            out.append(entry)
            lastMode = tracker.mode
        }
    }
    return intents
}

private extension String {
    /// FNV-1a, since Swift's `hashValue` changes per process.
    var hashValueStable: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

/// Plays every session, compares with goldens.txt, and reports where USB and
/// Bluetooth cadence produce different gestures. Returns false on a mismatch.
func runGoldens(directory: String) -> Bool {
    var out: [String] = []
    var cadenceNotes: [String] = []
    for session in sessions {
        var perCadence: [Cadence: [String]] = [:]
        for c in Cadence.allCases { perCadence[c] = kinds(play(session, c, into: &out)) }
        if perCadence[.usb] != perCadence[.bluetooth] {
            cadenceNotes.append("  \(session.name): usb \(perCadence[.usb]!) vs bluetooth \(perCadence[.bluetooth]!)")
        }
    }
    let text = out.joined(separator: "\n") + "\n"
    let path = directory + "/goldens.txt"

    if !cadenceNotes.isEmpty {
        print("cadence changes the gesture in \(cadenceNotes.count) session(s):")
        cadenceNotes.forEach { print($0) }
    }
    if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("goldens.txt rewritten (\(out.count) lines)")
        return true
    }
    guard let golden = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("FAIL: no goldens.txt; run with UPDATE_GOLDENS=1\n".utf8))
        return false
    }
    if golden == text { return true }
    let a = golden.split(separator: "\n", omittingEmptySubsequences: false)
    let b = text.split(separator: "\n", omittingEmptySubsequences: false)
    var section = ""
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? String(a[i]) : "<end>"
        let y = i < b.count ? String(b[i]) : "<end>"
        if y.hasPrefix("## ") { section = y }
        if x != y {
            FileHandle.standardError.write(Data(
                "FAIL goldens line \(i + 1) in \(section)\n  expected: \(x)\n  got:      \(y)\n".utf8))
            break
        }
    }
    return false
}
