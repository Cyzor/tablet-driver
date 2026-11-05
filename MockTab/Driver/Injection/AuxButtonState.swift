// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

/// Pad buttons belong to the device, not the pen's proximity session. Keep
/// each press's binding until its release, even if settings change meanwhile.
/// HIDThread-confined by InputInjector.
struct AuxButtonState {
    enum Control: Hashable {
        case button(Int), ring, ring2
    }

    struct Action: Equatable {
        var binding: ButtonBinding
        var down: Bool
    }

    private var held: [Control: ButtonBinding] = [:]

    var hasHeldControls: Bool { !held.isEmpty }

    func isHeld(_ control: Control) -> Bool { held[control] != nil }

    /// Commits state before returning actions so the injector's quiescence
    /// check sees the new button state when it posts them.
    mutating func update(_ control: Control, down: Bool, binding: ButtonBinding,
                         mechanicalPulse: Bool = false) -> [Action] {
        if down {
            if let previous = held[control] {
                // Some decoders flag every held frame as a press. Never turn
                // those frames into repeated Click Lock toggles.
                guard mechanicalPulse, previous.kind != .clickLock else { return [] }
                held[control] = binding
                return [Action(binding: previous, down: false), Action(binding: binding, down: true)]
            }
            held[control] = binding
            return [Action(binding: binding, down: true)]
        }
        guard let previous = held.removeValue(forKey: control) else { return [] }
        return [Action(binding: previous, down: false)]
    }

    /// Disconnect releases this device's contributions, leaving other
    /// injectors' shared modifier holds intact.
    mutating func releaseAll() -> [Action] {
        let controls = held.keys.sorted { order($0) < order($1) }
        let actions = controls.compactMap { held[$0].map { Action(binding: $0, down: false) } }
        held.removeAll()
        return actions
    }

    private func order(_ control: Control) -> Int {
        switch control {
        case .button(let index): return index
        case .ring: return Int.max - 1
        case .ring2: return Int.max
        }
    }
}
