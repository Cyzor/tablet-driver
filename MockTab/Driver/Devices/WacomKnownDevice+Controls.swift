// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import TabletKit

extension WacomKnownDevice: RingLEDControl, LabelControl, DisplayPanelControl, QuickKeysControl {

    /// The slots match the guards in the setters, so a device offers a
    /// control exactly when writing to it does something. Read on the pen
    /// thread: a dongle's spec changes there when it learns its tablet.
    var controls: TabletControls {
        let parser = deviceSpec.parser
        return TabletControls(
            // Per parser, as in `setRingLED`; not yet per model.
            ringLED: [.intuosV1, .intuosV2, .cintiqV1, .xencelabs].contains(parser) ? self : nil,
            labels: parser == .xencelabs || deviceSpec.hasKeyOLEDs ? self : nil,
            displayPanel: hasDisplayBrightnessControl ? self : nil,
            quickKeys: parser == .xencelabs ? self : nil)
    }

    func setRingLEDColors(_ colors: [LEDColor?]) {
        setRingLEDColors(colors.map { $0.map { (r: $0.r, g: $0.g, b: $0.b) } })
    }

    func setBezelLEDColor(_ color: LEDColor) {
        setBezelLEDColor(r: color.r, g: color.g, b: color.b)
    }
}
