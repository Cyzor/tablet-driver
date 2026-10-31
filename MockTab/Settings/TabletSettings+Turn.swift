// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Turning the tablet: when its orientation changes, its saved assignments move
// with it in every app override and profile, so each place keeps its action.
// Saved assignments still name physical controls; only which control holds
// each one changes.
extension TabletSettings {

    /// An app override and profile pair that saved settings read in.
    struct TurnContext {
        var override: AppOverride?
        var profile: Profile?
    }

    /// Turns the tablet to `orientation`, moving its saved assignments with
    /// it. `carry` says what a turn between two orientations moves; a context
    /// whose orientation changes turns from its own. One undo step reverts
    /// the orientation and the assignments together.
    func turn(to orientation: TabletOrientation, carry: (TabletOrientation, TabletOrientation) -> TurnCarry) {
        guard orientation != tabletOrientation else { return }
        let before = turnSnapshot()
        let oldContexts = turnContexts
        let oldOrientations = oldContexts.map { self.orientation(in: $0) }
        var unreadable: Set<String> = []
        let old = oldContexts.map { turnAssignments(in: $0, unreadable: &unreadable) }

        tabletOrientation = orientation

        // The orientation write can mark a key in an override or profile, so
        // read the contexts afresh. Their order is the same.
        let contexts = turnContexts
        var new = old
        for i in contexts.indices {
            new[i] = carry(oldOrientations[i], self.orientation(in: contexts[i])).carried(old[i])
        }
        writeTurned(old: old, new: new, contexts: contexts, skipping: unreadable)
        reloadAll()
        recordTurn(String(localized: "Orientation"), from: before, to: turnSnapshot())
    }

    /// Moves the assignments as `carry` would without turning the tablet:
    /// for a setup a turn didn't carry, or one whose keys should stay put.
    /// Edits the settings the pane shows, like any other edit there. Doing
    /// it twice puts everything back.
    func turnAssignmentsAround(_ carry: TurnCarry) {
        var unreadable: Set<String> = []
        let old = turnAssignments(in: TurnContext(override: effectiveOverride, profile: activeProfile),
                                  unreadable: &unreadable)
        let new = carry.carried(old)
        guard new != old else { return }
        let before = turnSnapshot()
        func changed<Value: Equatable>(_ field: KeyPath<TurnAssignments, Value>, _ key: String) -> Bool {
            new[keyPath: field] != old[keyPath: field] && !unreadable.contains(key)
        }
        if changed(\.expressKeys, "expressKeyBindings") { expressKeyBindings = new.expressKeys }
        if changed(\.bezelButtons, "bezelButtonBindings") { bezelButtonBindings = new.bezelButtons }
        if changed(\.center, "touchRingButtonBinding") { touchRingButtonBinding = new.center }
        if changed(\.center2, "touchRingButtonBinding2") { touchRingButtonBinding2 = new.center2 }
        if changed(\.sharedSlots, "touchRingSlotsJSON") { touchRingSlots = new.sharedSlots }
        if changed(\.rotaries, "rotariesJSON"), let controls = new.rotaries {
            rotaries = RotarySet(controls: controls, controlsAreIndependent: rotaries.controlsAreIndependent)
        }
        if changed(\.activeSlot, "touchRingActiveSlotIndex") { touchRingActiveSlotIndex = new.activeSlot }
        if changed(\.activeSlot2, "touchRingActiveSlotIndex2") { touchRingActiveSlotIndex2 = new.activeSlot2 }
        if changed(\.reverseDirection, "reverseRingDirection") { reverseRingDirection = new.reverseDirection }
        recordTurn(TurnCarry.turnAroundTitle, from: before, to: turnSnapshot())
    }

    // MARK: - Contexts

    /// Every context: no override and each override, under no profile and each profile.
    var turnContexts: [TurnContext] {
        let overrides: [AppOverride?] = [nil] + appOverrides.map { Optional($0) }
        let profiles: [Profile?] = [nil] + self.profiles.map { Optional($0) }
        return overrides.flatMap { override in profiles.map { TurnContext(override: override, profile: $0) } }
    }

    func orientation(in context: TurnContext) -> TabletOrientation {
        let key = "tabletOrientation"
        guard let prefix = resolveLayer(for: key, override: context.override, profile: context.profile) else { return .landscape }
        return TabletOrientation(rawValue: ud.integer(forKey: prefix + key)) ?? .landscape
    }

    /// The assignments `context` reads, as the loaders read them. Keys whose
    /// saved data this build can't read go in `unreadable` and stay as saved.
    func turnAssignments(in context: TurnContext, unreadable: inout Set<String>) -> TurnAssignments {
        let (override, profile) = (context.override, context.profile)
        func prefix(_ key: String) -> String? { resolveLayer(for: key, override: override, profile: profile) }
        func string(_ key: String) -> String? { prefix(key).flatMap { ud.string(forKey: $0 + key) } }
        func int(_ key: String) -> Int { prefix(key).map { ud.integer(forKey: $0 + key) } ?? 0 }
        func bindings(_ key: String, count: Int) -> [ButtonBinding] {
            guard let raw = string(key), !raw.isEmpty else { return Array(repeating: .none, count: count) }
            guard let list = raw.data(using: .utf8).flatMap({ try? JSONDecoder().decode([ButtonBinding].self, from: $0) }) else {
                unreadable.insert(key)
                return Array(repeating: .none, count: count)
            }
            return Array((list + Array(repeating: .none, count: count)).prefix(count))
        }

        var slots = ControlSlot.defaults
        if let data = ud.data(forKey: touchRingSlotsLayer(override: override, profile: profile) + "touchRingSlotsJSON") {
            if let decoded = try? JSONDecoder().decode([ControlSlot].self, from: data) { slots = decoded }
            else { unreadable.insert("touchRingSlotsJSON") }
        }
        let active = int("touchRingActiveSlotIndex")

        var controls: [RotaryConfig]?
        if controlsAreIndependent {
            let (prefix, seeds) = rotariesLayer(override: override, profile: profile)
            var set = RotarySet(controls: [RotaryConfig(slots: defaultRingSlots)])
            if let data = ud.data(forKey: prefix + "rotariesJSON") {
                if let stored = try? JSONDecoder().decode(RotarySet.self, from: data) { set = stored }
                else { unreadable.insert("rotariesJSON") }
            } else if seeds {
                set = RotarySet(controls: [RotaryConfig(slots: slots, activeSlotIndex: active)])
            }
            set.resize(to: rotaries.controls.count)
            controls = set.controls
        }

        return TurnAssignments(
            expressKeys: bindings("expressKeyBindings", count: 16),
            bezelButtons: bindings("bezelButtonBindings", count: ControlTarget.bezelSlotCount),
            center: string("touchRingButtonBinding").flatMap(ButtonBinding.decode) ?? ButtonBinding(kind: .ringCycle),
            center2: string("touchRingButtonBinding2").flatMap(ButtonBinding.decode) ?? ButtonBinding(kind: .ringCycle2),
            sharedSlots: slots,
            activeSlot: active,
            activeSlot2: int("touchRingActiveSlotIndex2"),
            rotaries: controls,
            reverseDirection: prefix("reverseRingDirection").map { ud.bool(forKey: $0 + "reverseRingDirection") } ?? false)
    }

    // MARK: - Writing

    /// Writes each assignment that changed, field by field, in the least
    /// specific layer that serves every context; see `LayeredSetting`.
    private func writeTurned(old: [TurnAssignments], new: [TurnAssignments], contexts: [TurnContext],
                             skipping unreadable: Set<String>) {
        func encodedBindings(_ list: [ButtonBinding]) -> Any? {
            (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) }
        }
        let generic: (String) -> (AppOverride?, Profile?) -> String? = { key in
            { self.resolveLayer(for: key, override: $0, profile: $1) }
        }
        let slotsLayer: (AppOverride?, Profile?) -> String? = { self.touchRingSlotsLayer(override: $0, profile: $1) }
        let rotariesLayer: (AppOverride?, Profile?) -> String? = { self.rotariesLayer(override: $0, profile: $1).prefix }

        carryField("expressKeyBindings", \.expressKeys, old, new, contexts, layer: generic("expressKeyBindings"),
                   unreadable, encode: encodedBindings)
        carryField("bezelButtonBindings", \.bezelButtons, old, new, contexts, layer: generic("bezelButtonBindings"),
                   unreadable, encode: encodedBindings)
        carryField("touchRingButtonBinding", \.center, old, new, contexts, layer: generic("touchRingButtonBinding"),
                   unreadable) { $0.encoded }
        carryField("touchRingButtonBinding2", \.center2, old, new, contexts, layer: generic("touchRingButtonBinding2"),
                   unreadable) { $0.encoded }
        carryField("touchRingSlotsJSON", \.sharedSlots, old, new, contexts, layer: slotsLayer, unreadable) {
            try? JSONEncoder().encode($0)
        }
        carryField("touchRingActiveSlotIndex", \.activeSlot, old, new, contexts,
                   layer: generic("touchRingActiveSlotIndex"), unreadable) { $0 }
        carryField("touchRingActiveSlotIndex2", \.activeSlot2, old, new, contexts,
                   layer: generic("touchRingActiveSlotIndex2"), unreadable) { $0 }
        if controlsAreIndependent {
            carryField("rotariesJSON", \.rotaries, old, new, contexts, layer: rotariesLayer, unreadable) { controls in
                controls.flatMap { try? JSONEncoder().encode(RotarySet(controls: $0, controlsAreIndependent: true)) }
            }
        }
        carryField("reverseRingDirection", \.reverseDirection, old, new, contexts,
                   layer: generic("reverseRingDirection"), unreadable) { $0 }
    }

    /// Rewrites one saved field. `layer` says where the field reads from in
    /// a context, as its loader decides.
    private func carryField<Value: Equatable>(
        _ key: String, _ field: KeyPath<TurnAssignments, Value>,
        _ old: [TurnAssignments], _ new: [TurnAssignments], _ contexts: [TurnContext],
        layer: (AppOverride?, Profile?) -> String?, _ unreadable: Set<String>,
        encode: (Value) -> Any?
    ) {
        guard !unreadable.contains(key) else { return }
        func index(_ override: String?, _ profile: UUID?) -> Int? {
            contexts.firstIndex { $0.override?.bundleID == override && $0.profile?.id == profile }
        }
        guard let base = index(nil, nil) else { return }

        // What each layer holds now, as the field reads it.
        var saved = LayeredSetting(device: old[base][keyPath: field])
        for profile in profiles where layer(nil, profile) == profileKeyPrefix(profile) {
            if let i = index(nil, profile.id) { saved.profiles[profile.id] = old[i][keyPath: field] }
        }
        for override in appOverrides where layer(override, nil) == appOverrideKeyPrefix(override) {
            if let i = index(override.bundleID, nil) { saved.overrides[override.bundleID] = old[i][keyPath: field] }
        }

        let turned = saved.rewritten(
            overrideIDs: appOverrides.map(\.bundleID), profileIDs: profiles.map(\.id),
            preferredProfile: activeProfile?.id
        ) { override, profile in
            index(override, profile).map { new[$0][keyPath: field] } ?? saved.value(override: override, profile: profile)
        }

        if turned.device != saved.device, let value = encode(turned.device) {
            ud.set(value, forKey: devicePrefix + key)
        }
        for profile in profiles {
            guard let value = turned.profiles[profile.id], value != saved.profiles[profile.id],
                  let encoded = encode(value) else { continue }
            ud.set(encoded, forKey: profileKeyPrefix(profile) + key)
            markOverridden(key, inProfile: profile.id)
        }
        for override in appOverrides {
            guard let value = turned.overrides[override.bundleID], value != saved.overrides[override.bundleID],
                  let encoded = encode(value) else { continue }
            ud.set(encoded, forKey: appOverrideKeyPrefix(override) + key)
            markOverridden(key, inOverride: override.bundleID)
        }
    }

    private func markOverridden(_ key: String, inProfile id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }), !profiles[i].overriddenKeys.contains(key) else { return }
        profiles[i].overriddenKeys.insert(key)
        if activeProfile?.id == id { activeProfile = profiles[i] }
        saveProfileList()
    }

    private func markOverridden(_ key: String, inOverride id: String) {
        guard let i = appOverrides.firstIndex(where: { $0.bundleID == id }),
              !appOverrides[i].overriddenKeys.contains(key) else { return }
        appOverrides[i].overriddenKeys.insert(key)
        if activeAppOverride?.bundleID == id { activeAppOverride = appOverrides[i] }
        if driverOverride?.bundleID == id { driverOverride = appOverrides[i] }
        saveAppOverrides()
    }

    // MARK: - Undo

    /// Every value a turn can write, in every layer, and which keys each
    /// profile and override marks as its own.
    struct TurnSnapshot {
        var values: [String: Any] = [:]
        var keys: [String] = []
        var profileKeys: [UUID: Set<String>] = [:]
        var overrideKeys: [String: Set<String>] = [:]
    }

    private static let turnKeys = [
        "tabletOrientation", "expressKeyBindings", "bezelButtonBindings", "touchRingButtonBinding",
        "touchRingButtonBinding2", "touchRingSlotsJSON", "touchRingActiveSlotIndex", "touchRingActiveSlotIndex2",
        "rotariesJSON", "reverseRingDirection",
    ]

    func turnSnapshot() -> TurnSnapshot {
        var snapshot = TurnSnapshot()
        let prefixes = [devicePrefix] + profiles.map(profileKeyPrefix) + appOverrides.map(appOverrideKeyPrefix)
        for prefix in prefixes {
            for key in Self.turnKeys {
                snapshot.keys.append(prefix + key)
                if let value = ud.object(forKey: prefix + key) { snapshot.values[prefix + key] = value }
            }
        }
        for profile in profiles { snapshot.profileKeys[profile.id] = profile.overriddenKeys }
        for override in appOverrides { snapshot.overrideKeys[override.bundleID] = override.overriddenKeys }
        return snapshot
    }

    func restore(_ snapshot: TurnSnapshot) {
        for key in snapshot.keys {
            if let value = snapshot.values[key] { ud.set(value, forKey: key) } else { ud.removeObject(forKey: key) }
        }
        for i in profiles.indices {
            guard let keys = snapshot.profileKeys[profiles[i].id] else { continue }
            profiles[i].overriddenKeys = keys
            if activeProfile?.id == profiles[i].id { activeProfile = profiles[i] }
        }
        saveProfileList()
        for i in appOverrides.indices {
            guard let keys = snapshot.overrideKeys[appOverrides[i].bundleID] else { continue }
            appOverrides[i].overriddenKeys = keys
            if activeAppOverride?.bundleID == appOverrides[i].bundleID { activeAppOverride = appOverrides[i] }
            if driverOverride?.bundleID == appOverrides[i].bundleID { driverOverride = appOverrides[i] }
        }
        saveAppOverrides()
        reloadAll()
    }

    /// Undo puts every layer back as it was before the turn; redo, after.
    private func recordTurn(_ name: String, from before: TurnSnapshot, to after: TurnSnapshot) {
        record(name) { [weak self] in
            self?.restore(before)
            self?.recordTurn(name, from: after, to: before)
        }
    }
}
