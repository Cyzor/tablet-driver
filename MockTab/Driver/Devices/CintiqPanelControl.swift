// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Brightness and contrast of a Wacom pen display's panel, over standard
/// DDC/CI on its video cable (MCCS VCP 0x10/0x12, which public ddcutil logs
/// show the Cintiq 27QHD accepting).
///
/// The panel keeps its own values, so the controls start from a live read.
/// A panel that takes writes but won't answer reads (MonitorControl drives
/// such a 27QHD) gets write-only controls on 0–100, starting from the last
/// value set here; HDMI is left out, since Macs rarely carry DDC on it. Never
/// used for Xencelabs panels, whose vendor-HID brightness is the same
/// register — two writers would race.
@MainActor
final class CintiqPanelControl: ObservableObject {
    enum State: Equatable {
        case probing
        /// No Wacom display found that could be matched to this tablet.
        case noDisplay
        /// Found, but the display didn't answer over DDC/CI.
        case noReply
        case ready
    }

    struct Value: Equatable {
        var current: Int
        let max: Int
    }

    nonisolated static let brightnessCode: UInt8 = 0x10
    nonisolated static let contrastCode: UInt8 = 0x12

    @Published private(set) var state: State = .probing
    @Published private(set) var brightness: Value?
    @Published private(set) var contrast: Value?
    /// True when the panel didn't answer and the sliders only send.
    @Published private(set) var writeOnly = false

    private let modelName: String
    /// DDC transactions sleep tens of milliseconds each; keep them serial
    /// and off the main thread.
    private let queue = DispatchQueue(label: "cintiq.panel.ddc")
    private var link: DDCLink?
    /// Latest value asked for per code; a drag only sends the newest.
    private var pending: [UInt8: Int] = [:]
    private var writing = false
    private var isPreview = false

    init(modelName: String) {
        self.modelName = modelName
    }

    #if DEBUG
    /// Canvas previews: a fixed state and no DDC traffic. Sliders still move,
    /// since writes need a link and a preview never has one.
    init(previewState: State, brightness: Value? = nil, contrast: Value? = nil) {
        modelName = "Preview"
        isPreview = true
        state = previewState
        self.brightness = brightness
        self.contrast = contrast
    }
    #endif

    func probe() {
        guard !isPreview else { return }
        state = .probing
        let model = modelName
        let (bCode, cCode) = (Self.brightnessCode, Self.contrastCode)
        queue.async { [weak self] in
            let display = DDCLink.wacomPanelDisplay(modelName: model)
            let link = display.flatMap { DDCLink(displayLocation: $0.location) }
            let b = link?.readVCP(bCode)
            let c = link?.readVCP(cCode)
            let hdmi = display.flatMap {
                HardwareSurveyProbe.coreDisplayInfo($0.id)?["IODisplayIsHDMISink"] as? Bool
            } ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.link = link
                self.writeOnly = link != nil && b == nil && c == nil && !hdmi
                if self.writeOnly {
                    self.brightness = Value(current: self.remembered(bCode), max: 100)
                    self.contrast = Value(current: self.remembered(cCode), max: 100)
                } else {
                    self.brightness = b.map { Value(current: $0.current, max: $0.max) }
                    self.contrast = c.map { Value(current: $0.current, max: $0.max) }
                }
                self.state = link == nil ? .noDisplay
                    : (self.brightness == nil && self.contrast == nil ? .noReply : .ready)
            }
        }
    }

    func setBrightness(_ value: Int) {
        guard brightness != nil else { return }
        brightness?.current = value
        enqueue(Self.brightnessCode, value)
    }

    func setContrast(_ value: Int) {
        guard contrast != nil else { return }
        contrast?.current = value
        enqueue(Self.contrastCode, value)
    }

    private func defaultsKey(_ code: UInt8) -> String {
        String(format: "CintiqPanel.%@.0x%02X", modelName, code)
    }

    private func remembered(_ code: UInt8) -> Int {
        UserDefaults.standard.object(forKey: defaultsKey(code)) as? Int ?? 50
    }

    private func enqueue(_ code: UInt8, _ value: Int) {
        if writeOnly { UserDefaults.standard.set(value, forKey: defaultsKey(code)) }
        pending[code] = value
        guard !writing, let link else { return }
        writing = true
        drain(link)
    }

    private func drain(_ link: DDCLink) {
        guard let (code, value) = pending.first else {
            writing = false
            return
        }
        pending[code] = nil
        queue.async { [weak self] in
            link.writeVCP(code, value)
            DispatchQueue.main.async { self?.drain(link) }
        }
    }
}
