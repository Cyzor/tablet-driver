// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Dates in the names of files MockTab writes and in the reports it builds.
/// Pinned to the Gregorian calendar and ASCII digits in local time, so a
/// user's region can't turn a stamp into another calendar's year.
enum DateStamp {
    /// "20261023-192600", for file names.
    static func compact(_ date: Date = Date()) -> String { format(date, "yyyyMMdd-HHmmss") }

    /// "2026-10-23".
    static func day(_ date: Date = Date()) -> String { format(date, "yyyy-MM-dd") }

    /// "2026-10-23 19:26:00", for report text.
    static func full(_ date: Date = Date()) -> String { format(date, "yyyy-MM-dd HH:mm:ss") }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
