// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import TabletKit

extension TabletSpec {
    /// Two rings on a Cintiq 24HD-style pad, whose keys split into a left
    /// and a right group of eight, each with its own ring.
    var hasSplitPadLayout: Bool { hasDualRings && format == .cintiqV1 }
}
