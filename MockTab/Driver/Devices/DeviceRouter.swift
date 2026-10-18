// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TabletKit

/// The app's callbacks for one tablet's events.
@MainActor
enum DeviceRouter {

    /// Per-device closures, called on HIDThread.
    struct Callbacks {
        let onTablet: @Sendable (TabletPoint) -> Void
        let onAux: @Sendable (PadState) -> Void
        let onToolEnter: @Sendable (ToolIdentity) -> Void
        let onMouseButton: @Sendable (UInt8) -> Void
        let onBattery: @Sendable (Int?, Bool) -> Void
        /// Whether a wireless kit's tablet is linked or asleep, on a change.
        let onWirelessLink: @Sendable (Bool) -> Void
        let onWheel: @Sendable (Int, Int) -> Void
        /// Per-frame finger contacts; an empty array means every finger lifted.
        let onTouch: @Sendable ([TouchContact]) -> Void
    }
}
