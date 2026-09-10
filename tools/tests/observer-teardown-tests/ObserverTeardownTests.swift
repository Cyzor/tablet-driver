// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// ObserverTeardownTests.swift — Standalone checks for the reconnect
// subscription-accumulation rule `DeviceContext.teardownDriverLifecycleObservers()`
// enforces.
//
// Does NOT compile `DeviceContext`: it transitively pulls in TabletSettings,
// InputInjector, TabletManager, and the device wrappers, so unlike
// DeviceInstanceClaims (instance-identity-tests) it can't be built standalone.
// These model the same Combine arrangement instead — a cancellable set observers
// `.store(in:)` into, a flag gating installation, a context outliving disconnect
// — so they pin the mechanic, not the app's wiring of it. Hardware verification
// is still owed.
//
// Run via run.sh. Exits non-zero on failure.

import Combine
import Foundation

// MARK: - Tiny assertion harness

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                    file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String,
                                       file: StaticString = #file, line: UInt = #line) {
    expect(a == b, "\(message()) — got \(a), expected \(b)", file: file, line: line)
}

// MARK: - Model of the DeviceContext lifecycle under test
//
// Two cancellable sets (real: `cancellables` and the private
// `snapshotCancellables`) and the flag gating their installation.

private final class FakeSettings {
    let ringSlot = PassthroughSubject<Int, Never>()
    let anyChange = PassthroughSubject<Void, Never>()
}

private final class FakeContext {
    let settings = FakeSettings()

    /// Counts hardware writes the sinks would perform. The bug's signature is
    /// this incrementing more than once per settings change.
    private(set) var hardwareWrites = 0

    var cancellables: Set<AnyCancellable> = []
    private var snapshotCancellables: Set<AnyCancellable> = []
    var hasWiredDriverLifecycle = false

    /// Stand-in for `observeRingLED()`.
    func observeRingLED() {
        settings.ringSlot
            .sink { [weak self] _ in self?.hardwareWrites += 1 }
            .store(in: &cancellables)
    }

    /// Stand-in for `observeInjectionSnapshot()`.
    func observeInjectionSnapshot() {
        settings.anyChange
            .sink { [weak self] _ in self?.hardwareWrites += 1 }
            .store(in: &snapshotCancellables)
    }

    /// Stand-in for `teardownDriverLifecycleObservers()`.
    func teardownDriverLifecycleObservers() {
        cancellables.removeAll()
        snapshotCancellables.removeAll()
    }

    /// Stand-in for the connect path's `hadNoDriverYet` branch.
    func connect(tearingDown: Bool) {
        if !hasWiredDriverLifecycle {
            observeRingLED()
            observeInjectionSnapshot()
            hasWiredDriverLifecycle = true
        }
    }

    /// Stand-in for the fully-disconnected path. `tearingDown: false` reproduces
    /// the pre-fix behavior (flag cleared, subscriptions left installed).
    func disconnect(tearingDown: Bool) {
        if tearingDown { teardownDriverLifecycleObservers() }
        hasWiredDriverLifecycle = false
    }

    func fireSettingsChange() {
        settings.ringSlot.send(0)
        settings.anyChange.send(())
    }
}

// MARK: - Checks

// 1. Baseline: one connect, one settings change → one write per observer.
do {
    let ctx = FakeContext()
    ctx.connect(tearingDown: true)
    ctx.fireSettingsChange()
    expectEqual(ctx.hardwareWrites, 2, "one connect should install exactly one sink per observer")
}

// 2. The pre-fix behavior, asserted so the harness records what the bug was.
do {
    let ctx = FakeContext()
    for _ in 0..<4 {
        ctx.connect(tearingDown: false)
        ctx.disconnect(tearingDown: false)
    }
    ctx.connect(tearingDown: false)
    ctx.fireSettingsChange()
    expectEqual(ctx.hardwareWrites, 10,
                "without teardown, 5 connects should stack 5 sinks per observer (the bug)")
}

// 3. The fix: tearing down on disconnect keeps it at one per observer no matter
//    how many reconnect cycles the context has seen.
do {
    let ctx = FakeContext()
    for _ in 0..<4 {
        ctx.connect(tearingDown: true)
        ctx.disconnect(tearingDown: true)
    }
    ctx.connect(tearingDown: true)
    ctx.fireSettingsChange()
    expectEqual(ctx.hardwareWrites, 2,
                "with teardown, repeated reconnects must not multiply hardware writes")
}

// 4. Both sets, not just the first — clearing only `cancellables` would leave
//    two of the eleven real subscriptions accumulating.
do {
    let ctx = FakeContext()
    ctx.connect(tearingDown: true)
    ctx.teardownDriverLifecycleObservers()
    ctx.fireSettingsChange()
    expectEqual(ctx.hardwareWrites, 0,
                "teardown must clear every cancellable set, not just the first")
}

// 5. Teardown leaves the context reusable — a later connect re-installs and
//    works normally. Guards against "fixing" the leak by never re-subscribing.
do {
    let ctx = FakeContext()
    ctx.connect(tearingDown: true)
    ctx.disconnect(tearingDown: true)
    ctx.connect(tearingDown: true)
    ctx.fireSettingsChange()
    expectEqual(ctx.hardwareWrites, 2, "reconnect after teardown must restore working sinks")
}

// MARK: - Summary

if failures == 0 {
    print("observer-teardown-tests: \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("observer-teardown-tests: \(failures)/\(checks) failed\n".utf8))
    exit(1)
}
