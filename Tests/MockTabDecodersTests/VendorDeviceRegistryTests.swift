// SPDX-License-Identifier: MPL-2.0
//
// Tests the `VendorDeviceRegistry` lookup surface and a handful of well-known
// imported entries (Huion H1060P, Xencelabs Pen Tablet Medium).  These act
// as canaries: if a future OTD-snapshot re-import accidentally drops one of
// these flagship products, a test breaks here before users notice.

import XCTest
@testable import TabletKit

final class VendorDeviceRegistryTests: XCTestCase {

    // MARK: - VendorDeviceProfile shape

    func testLPIDerivedWhenAllDimensionsPresent() {
        // Xencelabs Medium: 52324 / 261.62 mm × 25.4 ≈ 5079.6 LPI (matches the
        // published 5080 LPI sensor spec to within rounding).
        let profile = VendorDeviceProfile(
            vendor: "Xencelabs", vendorID: 0x28BD, productID: 0x5201,
            productName: "Pen Tablet Medium",
            activeWidthMM: 261.62, activeHeightMM: 148,
            maxX: 52324, maxY: 29600,
            maxPressure: 8191)
        guard let lpi = profile.lpi else {
            return XCTFail("LPI should derive when all four dimensions present")
        }
        XCTAssertEqual(lpi.x, 5080, accuracy: 1)
        XCTAssertEqual(lpi.y, 5080, accuracy: 1)
    }

    func testLPINilWhenAnyDimensionMissing() {
        let profile = VendorDeviceProfile(
            vendor: "Huion", vendorID: 0x256C, productID: 0x0001,
            productName: "Test",
            activeWidthMM: 100, activeHeightMM: nil,
            maxX: 50000, maxY: 30000)
        XCTAssertNil(profile.lpi)
    }

    // MARK: - Registry lookup

    func testEmptyLookupForUnknownPID() {
        XCTAssertTrue(VendorDeviceRegistry.profiles(forVendorID: 0xFFFF, productID: 0xFFFF).isEmpty)
    }

    func testHuionLookupReturnsAtLeastOneProfile() {
        // PID 0x0064 = Huion H1060P in the OTD snapshot.  May share PID with
        // other products in future snapshots — assert "at least one" rather
        // than "exactly one" so a future re-import doesn't break this test.
        let profiles = VendorDeviceRegistry.profiles(forVendorID: 0x256C, productID: 0x0064)
        XCTAssertGreaterThan(profiles.count, 0,
                             "Huion H1060P (0x256C/0x0064) should be present in the imported registry")
        XCTAssertTrue(profiles.allSatisfy { $0.vendor == "Huion" })
    }

    func testXencelabsMediumPresent() {
        // Xencelabs Pen Tablet Medium: VID 10429 (0x28BD), PID 20993 (0x5201).
        let profiles = VendorDeviceRegistry.profiles(forVendorID: 0x28BD, productID: 0x5201)
        XCTAssertFalse(profiles.isEmpty, "Xencelabs Pen Tablet Medium should be present")
        guard let medium = profiles.first else { return }
        XCTAssertEqual(medium.vendor, "Xencelabs")
        XCTAssertTrue(medium.productName.lowercased().contains("medium"),
                      "Expected 'medium' in product name, got '\(medium.productName)'")
        XCTAssertEqual(medium.maxPressure, 8191)
    }

    func testVendorFilterReturnsOnlyMatchingBrand() {
        let huion = VendorDeviceRegistry.profiles(forVendor: "Huion")
        XCTAssertGreaterThan(huion.count, 50, "OTD snapshot should yield many Huion entries")
        XCTAssertTrue(huion.allSatisfy { $0.vendor == "Huion" })
    }

    func testAllImportedEntriesHaveNonEmptyProductName() {
        for profile in VendorDeviceRegistry.knownDevices {
            XCTAssertFalse(profile.productName.isEmpty,
                           "Profile with vid=0x\(String(profile.vendorID, radix: 16)) "
                           + "pid=0x\(String(profile.productID, radix: 16)) has empty name")
        }
    }

    func testAllImportedEntriesHaveRecognizedVendor() {
        let expected: Set<String> = ["Huion", "Xencelabs", "XP-Pen"]
        let vendors = Set(VendorDeviceRegistry.knownDevices.map(\.vendor))
        XCTAssertEqual(vendors, expected,
                       "Unexpected vendor set: \(vendors). "
                       + "Re-import via tools/import_vendor_configs.py with --vendors Huion Xencelabs XP-Pen.")
    }

    // MARK: - Huion same-PID-many-products invariant

    /// The whole point of returning `[Profile]` instead of `Profile?` is to
    /// surface Huion's PID-collision case to the caller.  This test verifies
    /// the snapshot contains at least one such collision — if it ever drops
    /// to zero, the array-returning API is overkill and the test reminds us.
    func testAtLeastOneHuionPIDCollisionExists() {
        let huion = VendorDeviceRegistry.profiles(forVendor: "Huion")
        var counts: [Int: Int] = [:]
        for profile in huion {
            counts[profile.productID, default: 0] += 1
        }
        let collisions = counts.filter { $0.value > 1 }
        XCTAssertFalse(collisions.isEmpty,
                       "Expected at least one Huion PID shared by multiple products "
                       + "(the OTD snapshot reliably has these).  If this test breaks, "
                       + "consider whether `profiles(forVendorID:productID:)` should "
                       + "still return an array.")
    }
}
