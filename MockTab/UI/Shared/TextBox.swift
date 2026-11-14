// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

extension View {
    /// The bordered, text-colored box around copyable text in the Info pane.
    func textBox() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
    }
}
