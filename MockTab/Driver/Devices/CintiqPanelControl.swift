// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Brightness and contrast of a Wacom pen display's panel, over standard
/// DDC/CI on its video cable (MCCS VCP 0x10/0x12, which public ddcutil logs
/// show the Cintiq 27QHD accepting).
///
/// Nothing is persisted: the panel keeps its own values, so the controls
/// start from a live read and only a read that answers enables them. Never
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
            let link = DDCLink.wacomPanel(modelName: model)
            let b = link?.readVCP(bCode)
            let c = link?.readVCP(cCode)
            DispatchQueue.main.async {
                guard let self else { return }
                self.link = link
                self.brightness = b.map { Value(current: $0.current, max: $0.max) }
                self.contrast = c.map { Value(current: $0.current, max: $0.max) }
                self.state = link == nil ? .noDisplay : (b == nil && c == nil ? .noReply : .ready)
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

    private func enqueue(_ code: UInt8, _ value: Int) {
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
