// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// The two declarations ToolSettings takes from TabletSettings.swift.

import Foundation
import os

let settingsLogger = Logger(subsystem: "harness", category: "settings")

@MainActor protocol UndoRecording: AnyObject {
    var undoManager: UndoManager? { get }
}
