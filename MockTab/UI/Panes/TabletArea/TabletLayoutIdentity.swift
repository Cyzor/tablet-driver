// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which button each part of a model's layout stands for, read from
/// `TabletLayoutTable.identity`. Entries line up one for one with the
/// model's `TabletFigure.layouts` parts. Buttons are libwacom's letters, A on.
struct TabletLayoutIdentity: Equatable {
    /// One cell of a key grid.
    enum Cell: Equatable {
        case empty
        case key(Character)
        /// The ring or dial the keys sit beside.
        case body
    }

    /// Keys in rows along the edge, from the top or left, and columns from
    /// the edge inward. A letter in several cells is one key spanning them.
    struct Grid: Equatable {
        var rows: [[Cell]]

        /// Each key once, in reading order.
        var letters: [Character] {
            var seen: [Character] = []
            for case let .key(letter) in rows.joined() where !seen.contains(letter) { seen.append(letter) }
            return seen
        }
    }

    /// The keys that belong to a ring or dial.
    enum RingKeys: Equatable {
        case none
        /// One key set into its middle.
        case center(Character)
        /// Keys beside it, laid out around `Cell.body`.
        case beside(Grid)
    }

    enum Entry: Equatable {
        /// A run's keys from start to end.
        case run([Character])
        case cluster(Grid)
        /// Rings, dials, and strips are numbered from 1.
        case ring(Int, RingKeys)
        case dial(Int, RingKeys)
        case strip(Int)

        /// The keys this entry stands for, each once.
        var letters: [Character] {
            switch self {
            case let .run(letters): return letters
            case let .cluster(grid): return grid.letters
            case let .ring(_, keys), let .dial(_, keys):
                switch keys {
                case .none: return []
                case let .center(letter): return [letter]
                case let .beside(grid): return grid.letters
                }
            case .strip: return []
            }
        }
    }

    /// A key that switches a ring, dial, or strip's mode.
    struct ModeSwitch: Equatable {
        enum Control: Equatable { case ring(Int), dial(Int), strip(Int) }
        var control: Control
        /// The mode it picks, from 0; nil cycles through them.
        var mode: Int?
    }

    var entries: [Entry]
    var modeSwitches: [Character: ModeSwitch] = [:]
    /// Each button's evdev code from A on, when they aren't the ExpressKey defaults.
    var evdevCodes: [Int]? = nil

    /// Every key the entries use, in order. A key libwacom draws twice appears twice.
    var letters: [Character] { entries.flatMap(\.letters) }
}

// MARK: - Parsing

extension TabletLayoutIdentity {
    /// Identities by product ID, read once from the generated table and its extras.
    static let all: [Int: TabletLayoutIdentity] = {
        var all: [Int: TabletLayoutIdentity] = [:]
        for line in (TabletLayoutTable.identity + "\n" + TabletLayoutExtras.identity).split(separator: "\n") {
            guard let (ids, identity) = parse(line: line) else { continue }
            for id in ids { all[id] = identity }
        }
        return all
    }()

    /// Reads one table line, like `0357 0358: k ABCD; r 1 I; k EFGH | m I=r1`.
    /// Nil if any part of it is malformed; the tablet figure tests read
    /// every line, so a bad one fails there.
    static func parse(line: Substring) -> (ids: [Int], identity: TabletLayoutIdentity)? {
        let halves = line.split(separator: ":", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let idFields = halves[0].split(separator: " ")
        let ids = idFields.compactMap { Int($0, radix: 16) }
        guard !ids.isEmpty, ids.count == idFields.count else { return nil }

        let sections = halves[1].split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = sections.first else { return nil }
        let entries = first.split(separator: ";", omittingEmptySubsequences: false).map { Entry(token: $0.trimmingCharacters(in: .whitespaces)) }
        guard !entries.isEmpty, entries.allSatisfy({ $0 != nil }) else { return nil }
        var identity = TabletLayoutIdentity(entries: entries.compactMap { $0 })

        for section in sections.dropFirst() {
            let fields = section.split(separator: " ")
            switch fields.first {
            case "m"? where identity.modeSwitches.isEmpty && fields.count > 1:
                for field in fields.dropFirst() {
                    guard let (letter, mode) = ModeSwitch.parse(field), identity.modeSwitches[letter] == nil
                    else { return nil }
                    identity.modeSwitches[letter] = mode
                }
            case "ev"? where identity.evdevCodes == nil && fields.count > 1:
                let codes = fields.dropFirst().compactMap { Int($0, radix: 16) }
                guard codes.count == fields.count - 1 else { return nil }
                identity.evdevCodes = codes
            default:
                return nil
            }
        }
        return (ids, identity)
    }

    fileprivate static func isLetter(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        return ascii >= 65 && ascii <= 90
    }

    fileprivate static func number(_ s: Substring) -> Int? {
        guard let n = Int(s), n >= 1 else { return nil }
        return n
    }
}

extension TabletLayoutIdentity.Entry {
    init?(token: String) {
        let fields = token.split(separator: " ")
        guard let kind = fields.first else { return nil }
        switch (kind, fields.count) {
        case ("k", 2):
            let letters = Array(fields[1])
            guard letters.allSatisfy(TabletLayoutIdentity.isLetter) else { return nil }
            self = .run(letters)
        case ("c", 2):
            guard let grid = TabletLayoutIdentity.Grid(token: fields[1]),
                  !grid.rows.joined().contains(.body), grid.letters.count > 1
            else { return nil }
            self = .cluster(grid)
        case ("r", 2...3), ("d", 2...3):
            guard let n = TabletLayoutIdentity.number(fields[1]) else { return nil }
            var keys = TabletLayoutIdentity.RingKeys.none
            if fields.count == 3 {
                let text = fields[2]
                if text.count == 1, let letter = text.first, TabletLayoutIdentity.isLetter(letter) {
                    keys = .center(letter)
                } else if let grid = TabletLayoutIdentity.Grid(token: text), grid.rows.joined().contains(.body),
                          !grid.letters.isEmpty {
                    keys = .beside(grid)
                } else {
                    return nil
                }
            }
            self = kind == "r" ? .ring(n, keys) : .dial(n, keys)
        case ("s", 2):
            guard let n = TabletLayoutIdentity.number(fields[1]) else { return nil }
            self = .strip(n)
        default:
            return nil
        }
    }
}

extension TabletLayoutIdentity.Grid {
    /// Reads rows split by `/`: a letter is a key, `.` is empty, `@` the ring or dial.
    init?(token: Substring) {
        var rows: [[TabletLayoutIdentity.Cell]] = []
        for row in token.split(separator: "/", omittingEmptySubsequences: false) {
            var cells: [TabletLayoutIdentity.Cell] = []
            for c in row {
                switch c {
                case ".": cells.append(.empty)
                case "@": cells.append(.body)
                case _ where TabletLayoutIdentity.isLetter(c): cells.append(.key(c))
                default: return nil
                }
            }
            guard !cells.isEmpty, cells.count == rows.first?.count ?? cells.count else { return nil }
            rows.append(cells)
        }
        self.init(rows: rows)
    }
}

extension TabletLayoutIdentity.ModeSwitch {
    /// Reads `I=r1`, or `A=r1.0` for a key that picks one mode.
    static func parse(_ field: Substring) -> (Character, Self)? {
        let halves = field.split(separator: "=")
        guard halves.count == 2, halves[0].count == 1, let letter = halves[0].first,
              TabletLayoutIdentity.isLetter(letter)
        else { return nil }
        var target = halves[1]
        let kind = target.popFirst()
        let parts = target.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let n = TabletLayoutIdentity.number(parts[0]) else { return nil }
        var mode: Int? = nil
        if parts.count == 2 {
            guard let m = Int(parts[1]), m >= 0 else { return nil }
            mode = m
        }
        let control: Control
        switch kind {
        case "r"?: control = .ring(n)
        case "d"?: control = .dial(n)
        case "s"?: control = .strip(n)
        default: return nil
        }
        return (letter, Self(control: control, mode: mode))
    }
}

extension TabletLayoutIdentity.Entry {
    /// The entry seen from the other end of its edge: a run's keys and a
    /// grid's rows in reverse.
    var reversedAlongEdge: Self {
        switch self {
        case let .run(letters): return .run(letters.reversed())
        case let .cluster(grid): return .cluster(.init(rows: grid.rows.reversed()))
        case let .ring(n, .beside(grid)): return .ring(n, .beside(.init(rows: grid.rows.reversed())))
        case let .dial(n, .beside(grid)): return .dial(n, .beside(.init(rows: grid.rows.reversed())))
        case .ring, .dial, .strip: return self
        }
    }
}

// MARK: - Targets

/// A control the Buttons pane has state or a row for.
enum ControlTarget: Hashable {
    /// `LiveButtonState.expressKeys` and `expressKeyBindings`, 0–15.
    case expressKey(Int)
    /// `bezelButtons`, 0–2.
    case bezel(Int)
    /// A ring's center button or a dial's toggle key, 0 or 1:
    /// `touchRingButtonDown` and `touchRing2ButtonDown`.
    case ringCenter(Int)
    /// The ring, dial, or strip itself, 0 or 1.
    case ring(Int)
    case dial(Int)
    case strip(Int)

    /// A fixed bit for each target, so a set of them fits a `UInt64`.
    var bit: Int {
        switch self {
        case let .expressKey(i): return i
        case let .bezel(i): return 16 + i
        case let .ringCenter(i): return 19 + i
        case let .ring(i): return 21 + i
        case let .dial(i): return 23 + i
        case let .strip(i): return 25 + i
        }
    }
}

// MARK: - Layouts libwacom lacks

/// Layouts libwacom doesn't carry, in the generated table's formats. Their
/// product IDs stay clear of Wacom's; the figure tests check it.
enum TabletLayoutExtras {
    /// Xencelabs Pen Display 24: three round buttons in a row toward the
    /// right end of the top bezel, placed from the product's photos.
    static let packed = "520D: k3oT0 800-898"
    static let identity = "520D: k ABC"

    /// Parts libwacom leaves out of a layout it has, drawn but not driven:
    /// the Cintiq 24HD's three display buttons on the top bezel, toward the
    /// right, placed from the product's photos.
    static let addedParts = "00F4 00F8: k3oT0 680-760"

    /// The models listed here.
    static let productIDs: Set<Int> = Set(packed.split(separator: "\n").flatMap { line in
        line.prefix(while: { $0 != ":" }).split(separator: " ").compactMap { Int($0, radix: 16) }
    })
}
