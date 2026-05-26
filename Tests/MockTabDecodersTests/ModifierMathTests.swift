// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure-math tests for the synthetic-modifier bit logic extracted from
// InputInjector. These cover the algebra; the surrounding state machine
// (watchdogs, ref counts, thread ownership) is not testable from the
// SwiftPM package and is documented in
// Notes/InputInjector-Modifier-State-Invariants.md.
import XCTest
import CoreGraphics
@testable import TabletKit

final class ModifierMathTests: XCTestCase {

    // MARK: - managedMask

    func testManagedMaskCoversFourCanonicalModifiers() {
        XCTAssertNotEqual(ModifierMath.managedMask & CGEventFlags.maskCommand.rawValue, 0)
        XCTAssertNotEqual(ModifierMath.managedMask & CGEventFlags.maskShift.rawValue, 0)
        XCTAssertNotEqual(ModifierMath.managedMask & CGEventFlags.maskAlternate.rawValue, 0)
        XCTAssertNotEqual(ModifierMath.managedMask & CGEventFlags.maskControl.rawValue, 0)
    }

    func testManagedMaskExcludesNonManagedFlags() {
        // CapsLock, NumericPad, etc. must NOT be in the managed set — the driver
        // doesn't own those bits and must never clear them.
        XCTAssertEqual(ModifierMath.managedMask & CGEventFlags.maskAlphaShift.rawValue, 0)
        XCTAssertEqual(ModifierMath.managedMask & CGEventFlags.maskNumericPad.rawValue, 0)
        XCTAssertEqual(ModifierMath.managedMask & CGEventFlags.maskHelp.rawValue, 0)
        XCTAssertEqual(ModifierMath.managedMask & CGEventFlags.maskSecondaryFn.rawValue, 0)
    }

    // MARK: - releaseEventFlags

    func testReleaseEventFlagsPreservesNonManagedBits() {
        // CapsLock set in system; release event must retain it for downstream apps.
        let system = CGEventFlags.maskAlphaShift.rawValue
        let result = ModifierMath.releaseEventFlags(systemFlags: system, remainingSyntheticFlags: 0)
        XCTAssertEqual(result & CGEventFlags.maskAlphaShift.rawValue, CGEventFlags.maskAlphaShift.rawValue)
    }

    func testReleaseEventFlagsClearsManagedBitsByDefault() {
        // System has ⌘ set (from contaminated hidSystemState); release must clear it
        // because remainingSyntheticFlags is empty.
        let system = CGEventFlags.maskCommand.rawValue
        let result = ModifierMath.releaseEventFlags(systemFlags: system, remainingSyntheticFlags: 0)
        XCTAssertEqual(result & CGEventFlags.maskCommand.rawValue, 0)
    }

    func testReleaseEventFlagsKeepsRemainingSyntheticManagedBits() {
        // Releasing ⌘ while keeping ⌥: caller passes remainingSyntheticFlags = ⌥-only.
        let remaining = CGEventFlags.maskAlternate.rawValue
        let result = ModifierMath.releaseEventFlags(systemFlags: 0, remainingSyntheticFlags: remaining)
        XCTAssertEqual(result & CGEventFlags.maskAlternate.rawValue, CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(result & CGEventFlags.maskCommand.rawValue, 0)
    }

    func testReleaseEventFlagsIgnoresNonManagedBitsFromRemainingSynth() {
        // Defensive: if a caller accidentally passes non-managed bits in
        // remainingSyntheticFlags, releaseEventFlags must not surface them.
        let remaining = CGEventFlags.maskAlphaShift.rawValue
        let result = ModifierMath.releaseEventFlags(systemFlags: 0, remainingSyntheticFlags: remaining)
        XCTAssertEqual(result & CGEventFlags.maskAlphaShift.rawValue, 0)
    }

    // MARK: - excessSyntheticBits

    func testExcessIsEmptyWhenGroundTruthMatchesExpected() {
        let mask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        XCTAssertEqual(ModifierMath.excessSyntheticBits(groundTruth: mask, expected: mask), 0)
    }

    func testExcessIdentifiesOrphanedBits() {
        // Tool change: was holding ⌘+⌥; new tool only justifies ⌘. ⌥ is orphaned.
        let ground = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        let expected = CGEventFlags.maskCommand.rawValue
        let excess = ModifierMath.excessSyntheticBits(groundTruth: ground, expected: expected)
        XCTAssertEqual(excess, CGEventFlags.maskAlternate.rawValue)
    }

    func testExcessIgnoresNonManagedBitsInGroundTruth() {
        // Should never happen in practice (we never set non-managed bits in
        // groundTruth), but be defensive: if it does, don't flag them as excess.
        let ground = CGEventFlags.maskAlphaShift.rawValue
        let excess = ModifierMath.excessSyntheticBits(groundTruth: ground, expected: 0)
        XCTAssertEqual(excess, 0)
    }

    // MARK: - currentEventFlags

    func testCurrentEventFlagsUnionsPhysicalAndSyntheticForManagedBits() {
        // Physical ⌘ via the tap cache; synthetic ⌥ via groundTruth; should see both.
        let result = ModifierMath.currentEventFlags(
            systemFlags: 0,
            tapPhysicalManaged: CGEventFlags.maskCommand.rawValue,
            syntheticFlags: CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(result & CGEventFlags.maskCommand.rawValue, CGEventFlags.maskCommand.rawValue)
        XCTAssertEqual(result & CGEventFlags.maskAlternate.rawValue, CGEventFlags.maskAlternate.rawValue)
    }

    func testCurrentEventFlagsPreservesNonManagedBits() {
        // CapsLock set in system; result must keep it.
        let result = ModifierMath.currentEventFlags(
            systemFlags: CGEventFlags.maskAlphaShift.rawValue,
            tapPhysicalManaged: 0,
            syntheticFlags: 0)
        XCTAssertEqual(result & CGEventFlags.maskAlphaShift.rawValue, CGEventFlags.maskAlphaShift.rawValue)
    }

    func testCurrentEventFlagsIgnoresSystemManagedBits() {
        // System reports ⌘ set (e.g. lag in hidSystemState); since neither the tap
        // cache nor synthetic state shows ⌘, the result must NOT include it.
        // This is the entire point of the cache: stale system state cannot leak through.
        let result = ModifierMath.currentEventFlags(
            systemFlags: CGEventFlags.maskCommand.rawValue,
            tapPhysicalManaged: 0,
            syntheticFlags: 0)
        XCTAssertEqual(result & CGEventFlags.maskCommand.rawValue, 0)
    }

    // MARK: - shouldUpdatePhysicalCache

    func testShouldUpdateCacheTrueForHIDSystem() {
        XCTAssertTrue(
            ModifierMath.shouldUpdatePhysicalCache(
                sourceStateID: CGEventSourceStateID.hidSystemState.rawValue))
    }

    func testShouldUpdateCacheFalseForPrivateState() {
        // Our own posts use a private source state ID; cache must ignore them.
        XCTAssertFalse(
            ModifierMath.shouldUpdatePhysicalCache(
                sourceStateID: CGEventSourceStateID.privateState.rawValue))
    }

    func testShouldUpdateCacheFalseForUnknownIDs() {
        XCTAssertFalse(ModifierMath.shouldUpdatePhysicalCache(sourceStateID: -1))
        XCTAssertFalse(ModifierMath.shouldUpdatePhysicalCache(sourceStateID: 999))
    }
}
