// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A minimal JSON value box, used only to round-trip fields a struct's
/// Codable conformance doesn't recognize — so an older build re-saving one
/// of the composite prefs structs doesn't silently drop a field a newer
/// build wrote. See UnknownFieldsCodec.
enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Captures and re-emits JSON fields a struct's known `CodingKeys` don't
/// cover, so a build that predates those fields preserves them unchanged
/// instead of dropping them on the next save. Adopters store the captured
/// bag in a private `unknownFields` property and call these from their
/// custom `init(from:)` / `encode(to:)`.
enum UnknownFieldsCodec {
    static func captureUnknown(from decoder: Decoder, knownKeys: Set<String>) throws
        -> [String: JSONValue]
    {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var bag: [String: JSONValue] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            bag[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return bag
    }

    static func encodeUnknown(_ bag: [String: JSONValue], to encoder: Encoder) throws {
        guard !bag.isEmpty else { return }
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in bag {
            guard let codingKey = DynamicKey(stringValue: key) else { continue }
            try container.encode(value, forKey: codingKey)
        }
    }
}
