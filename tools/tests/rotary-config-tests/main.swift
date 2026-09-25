// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Standalone checks for per-control rotary mode storage.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real RotaryConfig.swift and ControlSlot.swift. Run via
// tools/tests/rotary-config-tests/run.sh. Exits non-zero on failure.

import Foundation

private var failures = 0
private var checks = 0

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    guard actual != expected else { return }
    failures += 1
    FileHandle.standardError.write(
        Data("FAIL (\(file):\(line)): \(message()) — got \(actual), expected \(expected)\n".utf8)
    )
}

private func slots(_ actions: [ControlSlot.Action]) -> [ControlSlot] {
    actions.map { ControlSlot(label: "", action: $0) }
}

// MARK: - Cycling

private func testCyclingSkipsSkippedSlots() {
    let d = RotaryConfig(slots: slots([.scroll, .skip, .zoom, .skip]), activeSlotIndex: 0)
    expectEqual(d.indexAfterCycling(), 2, "cycle jumps over a skipped slot")

    let wrapping = RotaryConfig(slots: slots([.scroll, .skip, .zoom, .skip]), activeSlotIndex: 2)
    expectEqual(wrapping.indexAfterCycling(), 0, "cycle wraps past trailing skips")
}

private func testCyclingStaysPutWhenAllSkipped() {
    let d = RotaryConfig(slots: slots([.skip, .skip, .skip, .skip]), activeSlotIndex: 2)
    expectEqual(d.indexAfterCycling(), 2, "all-skip cycle stays where it is")
}

private func testCyclingWithOneSlot() {
    let d = RotaryConfig(slots: slots([.scroll]), activeSlotIndex: 0)
    expectEqual(d.indexAfterCycling(), 0, "single slot cycles to itself")
}

private func testCyclingFromOutOfRangeIndex() {
    // A stored index can outlive a shorter slot array (profile import, older
    // build). Cycling must land somewhere valid rather than trap.
    let d = RotaryConfig(slots: slots([.scroll, .zoom]), activeSlotIndex: 9)
    let next = d.indexAfterCycling()
    expectEqual(d.slots.indices.contains(next), true, "cycle from a stale index lands in range")
}

// MARK: - Active slot

private func testActiveSlotOutOfRangeIsNil() {
    let d = RotaryConfig(slots: slots([.scroll]), activeSlotIndex: 3)
    expectEqual(d.activeSlot == nil, true, "out-of-range active index reports no slot")
}

private func testClampedTarget() {
    let d = RotaryConfig(slots: slots([.scroll, .zoom, .rotate]), activeSlotIndex: 0)
    expectEqual(d.clampedSlotTarget(7), 2, "jump target clamps to the last slot")
    expectEqual(d.clampedSlotTarget(-1), 0, "negative jump target clamps to the first slot")
    expectEqual(d.clampedSlotTarget(1), 1, "in-range jump target is untouched")
}

// MARK: - Gating

private func testMirroredHardwareResolvesToFirstControl() {
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll]), activeSlotIndex: 0),
                RotaryConfig(slots: slots([.zoom]), activeSlotIndex: 0)],
        controlsAreIndependent: false)
    expectEqual(set[.second].slots.first?.action, .scroll, "mirrored hardware reads control 1")

    // Writing through the gate must also land on control 1, or a mirrored device
    // would accumulate edits in storage nothing ever reads.
    set[.second] = RotaryConfig(slots: slots([.rotate]), activeSlotIndex: 0)
    expectEqual(set[.first].slots.first?.action, .rotate, "mirrored write lands on control 1")
}

private func testIndependentHardwareReadsItsOwnControl() {
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll]), activeSlotIndex: 0),
                RotaryConfig(slots: slots([.zoom]), activeSlotIndex: 0)],
        controlsAreIndependent: true)
    expectEqual(set[.second].slots.first?.action, .zoom, "independent hardware reads control 2")

    set[.second] = RotaryConfig(slots: slots([.rotate]), activeSlotIndex: 0)
    expectEqual(set[.first].slots.first?.action, .scroll, "editing control 2 leaves control 1 alone")
    expectEqual(set[.second].slots.first?.action, .rotate, "control 2 keeps its own edit")
}

private func testSecondControlOnSingleControlHardware() {
    // Independent, but only one control present — asking for the second
    // must not trap on a device that has none.
    let set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll]), activeSlotIndex: 0)],
        controlsAreIndependent: true)
    expectEqual(set[.second].slots.first?.action, .scroll, "absent second control falls back to control 1")
}

private func testEmptyControlsIsNeverStored() {
    let set = RotarySet(controls: [], controlsAreIndependent: true)
    expectEqual(set[.first].slots.isEmpty, false, "an empty control array is replaced by a default")
}

// MARK: - Resize

private func testResizeSeedsFromFirstControl() {
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.rotate]), activeSlotIndex: 0)],
        controlsAreIndependent: true)
    set.resize(to: 2)
    expectEqual(set[.second].slots.first?.action, .rotate, "a new control seeds from control 1")
}

private func testResizeDown() {
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll]), activeSlotIndex: 0),
                RotaryConfig(slots: slots([.zoom]), activeSlotIndex: 0)],
        controlsAreIndependent: true)
    set.resize(to: 1)
    expectEqual(set[.second].slots.first?.action, .scroll, "dropping a control falls back to control 1")
    set.resize(to: 0)
    expectEqual(set[.first].slots.isEmpty, false, "resizing to zero still leaves one control")
}

// MARK: - Reset

private func testResetKeepsShapeAndRestoresDefaults() {
    let set = RotarySet(
        controls: [RotaryConfig(slots: slots([.zoom]), activeSlotIndex: 0),
                RotaryConfig(slots: slots([.rotate, .scroll]), activeSlotIndex: 1)],
        controlsAreIndependent: true).resetToDefaults()
    expectEqual(set.controlsAreIndependent, true, "reset keeps the capability flag")
    expectEqual(set[.first], RotaryConfig(), "reset restores control 1's defaults")
    expectEqual(set[.second], RotaryConfig(), "reset restores control 2's defaults, not control 1's")
    expectEqual(set.controls.count, 2, "reset keeps the control count")
}

// MARK: - The storage seam
//
// `resolving` is what both TabletSettings.rotary and
// InjectionSnapshot.rotary call. Legacy hardware (Xencelabs, PTH-850,
// Cintiq) must keep reading the shared slots; PTK hardware must read its
// own records. Getting this backwards silently swaps which tablets work.

private let legacyShared = slots([.scroll, .off, .zoom, .skip])

private func resolve(
    _ set: RotarySet, _ index: RotaryIndex, active: Int = 0, active2: Int = 0
) -> RotaryConfig {
    set.resolving(
        index,
        legacySlots: legacyShared,
        legacyActiveIndex: active,
        legacyActiveIndex2: active2)
}

private func testLegacyHardwareReadsSharedSlots() {
    // Per-control records exist but must be ignored entirely: a device that
    // hasn't been moved over still stores its modes in touchRingSlots.
    let set = RotarySet(
        controls: [RotaryConfig(slots: slots([.rotate]), activeSlotIndex: 0),
                   RotaryConfig(slots: slots([.keyPress]), activeSlotIndex: 0)],
        controlsAreIndependent: false)
    expectEqual(resolve(set, .first).slots, legacyShared, "control 1 reads the shared slots")
    expectEqual(resolve(set, .second).slots, legacyShared, "control 2 reads the shared slots")
}

private func testLegacyHardwareKeepsPerControlActiveIndex() {
    // The one thing the old layout did get per-control: each dial's own
    // active index. That must survive.
    let set = RotarySet(controls: [RotaryConfig()], controlsAreIndependent: false)
    expectEqual(
        resolve(set, .first, active: 1, active2: 3).activeSlotIndex, 1,
        "control 1 reads the first legacy index")
    expectEqual(
        resolve(set, .second, active: 1, active2: 3).activeSlotIndex, 3,
        "control 2 reads the second legacy index")
}

private func testIndependentHardwareIgnoresLegacyStorage() {
    let set = RotarySet(
        controls: [RotaryConfig(slots: slots([.rotate]), activeSlotIndex: 0),
                   RotaryConfig(slots: slots([.keyPress]), activeSlotIndex: 0)],
        controlsAreIndependent: true)
    expectEqual(
        resolve(set, .first, active: 2, active2: 2).slots.first?.action, .rotate,
        "independent control 1 ignores the shared slots")
    expectEqual(
        resolve(set, .second, active: 2, active2: 2).slots.first?.action, .keyPress,
        "independent control 2 reads its own slots")
    expectEqual(
        resolve(set, .second, active: 2, active2: 2).activeSlotIndex, 0,
        "independent control ignores the legacy active index")
}

// MARK: - Cycle dispatch
//
// `.ringCycle2` shares one case body with `.ringCycle` now, parameterized by
// control. The risk in collapsing them is a press moving the wrong control.

private func testCyclingOneControlLeavesTheOtherPut() {
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll, .zoom, .rotate, .off]), activeSlotIndex: 0),
                   RotaryConfig(slots: slots([.scroll, .zoom, .rotate, .off]), activeSlotIndex: 2)],
        controlsAreIndependent: true)

    set[.second].activeSlotIndex = set[.second].indexAfterCycling()
    expectEqual(set[.second].activeSlotIndex, 3, "cycling control 2 advances control 2")
    expectEqual(set[.first].activeSlotIndex, 0, "cycling control 2 leaves control 1 put")

    set[.first].activeSlotIndex = set[.first].indexAfterCycling()
    expectEqual(set[.first].activeSlotIndex, 1, "cycling control 1 advances control 1")
    expectEqual(set[.second].activeSlotIndex, 3, "cycling control 1 leaves control 2 put")
}

private func testCyclingHonorsEachControlsOwnSkipLayout() {
    // Shared definitions made this impossible to get wrong; per-control ones
    // don't. Control 2 skipping a slot control 1 uses must not affect it.
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll, .zoom, .off, .off]), activeSlotIndex: 0),
                   RotaryConfig(slots: slots([.scroll, .skip, .skip, .off]), activeSlotIndex: 0)],
        controlsAreIndependent: true)

    expectEqual(set[.first].indexAfterCycling(), 1, "control 1 advances into its own slot 2")
    expectEqual(set[.second].indexAfterCycling(), 3, "control 2 skips past its own skipped slots")

    set[.second].activeSlotIndex = set[.second].indexAfterCycling()
    expectEqual(set[.first].slots[1].action, .zoom, "control 2's layout never touched control 1's")
}

private func testCyclingOnMirroredHardwareMovesTheSharedControl() {
    // Both sections of a mirrored device drive one record — cycling via the
    // second control must land on the first, not on storage nothing reads.
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll, .zoom, .off, .off]), activeSlotIndex: 0),
                   RotaryConfig(slots: slots([.scroll, .zoom, .off, .off]), activeSlotIndex: 0)],
        controlsAreIndependent: false)
    set[.second].activeSlotIndex = set[.second].indexAfterCycling()
    expectEqual(set[.first].activeSlotIndex, 1, "a mirrored second control cycles the first")
}

// MARK: - Coding

private func testRotarySetRoundTrips() {
    var set = RotarySet(
        controls: [RotaryConfig(slots: slots([.scroll, .keyPress, .zoom, .skip]), activeSlotIndex: 1),
                RotaryConfig(slots: slots([.rotate, .off, .off, .off]), activeSlotIndex: 0)],
        controlsAreIndependent: true)
    guard let data = try? JSONEncoder().encode(set),
          var decoded = try? JSONDecoder().decode(RotarySet.self, from: data)
    else {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: RotarySet did not round-trip through JSON\n".utf8))
        return
    }
    // The capability flag is hardware, not user data, so it doesn't survive
    // the round trip by design — the caller re-applies it from the spec.
    expectEqual(decoded.controlsAreIndependent, false, "the capability flag is not persisted")
    decoded.controlsAreIndependent = set.controlsAreIndependent
    expectEqual(decoded, set, "a rotary set survives an encode/decode round trip")

    set.resize(to: 1)
    expectEqual(set.controls.count, 1, "resize after decode still applies")
}

private func testCapabilityFlagIsAbsentFromEncodedForm() {
    let set = RotarySet(controls: [RotaryConfig()], controlsAreIndependent: true)
    guard let data = try? JSONEncoder().encode(set),
          let text = String(data: data, encoding: .utf8)
    else {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: RotarySet did not encode\n".utf8))
        return
    }
    checks += 1
    if text.contains("controlsAreIndependent") {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: encoded RotarySet leaked the capability flag into stored data\n".utf8))
    }
}




// MARK: - Run

testCyclingSkipsSkippedSlots()
testCyclingStaysPutWhenAllSkipped()
testCyclingWithOneSlot()
testCyclingFromOutOfRangeIndex()
testActiveSlotOutOfRangeIsNil()
testClampedTarget()
testMirroredHardwareResolvesToFirstControl()
testIndependentHardwareReadsItsOwnControl()
testSecondControlOnSingleControlHardware()
testEmptyControlsIsNeverStored()
testResizeSeedsFromFirstControl()
testResizeDown()
testResetKeepsShapeAndRestoresDefaults()
testLegacyHardwareReadsSharedSlots()
testLegacyHardwareKeepsPerControlActiveIndex()
testIndependentHardwareIgnoresLegacyStorage()
testCyclingOneControlLeavesTheOtherPut()
testCyclingHonorsEachControlsOwnSkipLayout()
testCyclingOnMirroredHardwareMovesTheSharedControl()
testRotarySetRoundTrips()
testCapabilityFlagIsAbsentFromEncodedForm()

if failures == 0 {
    print("rotary-config-tests: \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("rotary-config-tests: \(failures) of \(checks) checks failed\n".utf8))
    exit(1)
}
